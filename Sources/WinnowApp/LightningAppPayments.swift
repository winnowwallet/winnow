import CryptoKit
import Foundation
import LightningCore
import WalletCore

extension LightningAppController {
    struct PaymentReview {
        let request: LightningEngine.OfferPayment
        let profile: LightningProfile
        let offerText: String
    }
    static func freshID() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    static func validateOffer(_ text: String, network: BitcoinNetwork, amountSat: UInt64, maximumFeeSat: UInt64, now: UInt64) throws -> LightningOffer {
        guard amountSat > 0, amountSat <= 16_777_215, maximumFeeSat <= 100_000 else { throw LightningError.invalidAmount }
        let offer = try LightningOffer(string: text)
        try offer.validatePayment(chain: NetworkParams.params(for: network).genesisHash, now: now, amountMsat: amountSat * 1000)
        guard !offer.paths.isEmpty else { throw LightningError.invalidMessage }
        return offer
    }
    func reviewPayment(offer text: String, amountSat: UInt64, maximumFeeSat: UInt64) throws -> PaymentReview {
        let offer = try Self.validateOffer(text, network: network, amountSat: amountSat, maximumFeeSat: maximumFeeSat, now: Self.now)
        guard let profile, let route = try profile.paymentRoute(),
              let channel = channels.first(where: { $0.peer == profile.peerKey && $0.phase == .ready }) else { throw LightningError.invalidState }
        let request = LightningEngine.OfferPayment(id: Self.freshID(), channelID: channel.id, offer: offer,
            amountMsat: amountSat * 1000, feeLimitMsat: maximumFeeSat * 1000, maximumDelta: 2016, route: route)
        return PaymentReview(request: request, profile: profile, offerText: offer.string)
    }
    func pay(_ review: PaymentReview, model: AppModel) async throws {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            let epoch = generation
            guard let engine, profile == review.profile else { throw AppModel.AppError.sendReviewChanged }
            try await model.authenticateSensitiveAction(reason: "Approve this \(network.rawValue) Lightning payment and maximum fee")
            defer { model.keychainAuthentication.revoke() }
            try Task.checkCancellation()
            try requireNetwork(model, generation: epoch)
            guard profile == review.profile else { throw AppModel.AppError.sendReviewChanged }
            do { _ = try await engine.payOffer(review.request, now: Self.now) }
            catch {
                model.e2e?.journal("lightning.paymentRejected", fields: ["error": String(describing: error),
                    "chainCurrent": String(await engine.isChainCurrent()),
                    "recoveryConfigured": String(try await engine.channelBalances().first(where: { $0.id == review.request.channelID })?.recoveryConfigured == true)])
                throw error
            }
            try await refresh()
        }
    }
    func registerOffer(model: AppModel) async throws {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            let epoch = generation
            guard let engine, let profile, let receive = profile.receive else { throw LightningError.invalidState }
            try await model.authenticateSensitiveAction(reason: "Create a reusable \(network.rawValue) receive offer")
            defer { model.keychainAuthentication.revoke() }
            try Task.checkCancellation()
            try requireNetwork(model, generation: epoch)
            // A stable configuration-derived id survives duplicate taps and
            // relaunches before the server's persistence acknowledgement.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let id = Data(CryptoKit.SHA256.hash(data: try encoder.encode(receive)))
            try await engine.registerReceiveOffer(profile.receiveConfiguration(id: id, receive: receive), now: Self.now)
            try await refresh()
        }
    }
    struct CloseReview: Sendable {
        let channel: LightningEngine.Channel
        let force: Bool
        let address: String
        let destination: Data
        let feeSat: UInt64
    }
    func reviewClose(_ channel: LightningEngine.Channel, force: Bool, model: AppModel) async throws -> CloseReview {
        let epoch = generation
        var stage = "context"
        do {
            try Task.checkCancellation()
            try requireNetwork(model, generation: epoch)
            guard let engine, let wallet = model.wallet else { throw LightningError.invalidState }
            if force { return CloseReview(channel: channel, force: true, address: "", destination: Data(), feeSat: 0) }
            model.e2e?.journal("lightning.closeReviewStarted")
            stage = "receiveAddress"
            let address = try await wallet.freshReceiveAddress()
            try Task.checkCancellation()
            try requireNetwork(model, generation: epoch)
            model.e2e?.journal("lightning.closeDestinationPersisted")
            let destination = try AddressDecoder.scriptPubKey(for: address, network: network)
            stage = "feeRate"
            let rate = await model.resolvedFeeRate(priority: .medium, override: nil)
            try Task.checkCancellation()
            try requireNetwork(model, generation: epoch)
            stage = "closingFee"
            let fee = try await currentClosingFee(channel, engine: engine, destination: destination,
                rate: rate, model: model, generation: epoch)
            try Task.checkCancellation()
            try requireNetwork(model, generation: epoch)
            model.e2e?.journal("lightning.closeReviewReady", fields: ["feeSat": String(fee)])
            return CloseReview(channel: channel, force: false, address: address, destination: destination, feeSat: fee)
        } catch {
            model.e2e?.journal("lightning.closeReviewRejected", fields: ["stage": stage,
                "errorType": String(reflecting: type(of: error)), "error": String(describing: error),
                "syncing": String(model.status.syncing), "scanFailed": String(model.status.lastSyncError != nil)])
            throw error
        }
    }
    private func currentClosingFee(_ channel: LightningEngine.Channel, engine: LightningEngine,
                                   destination: Data, rate: Double, model: AppModel,
                                   generation epoch: UInt64) async throws -> UInt64 {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            try await awaitChannelScan(model: model, generation: epoch, deadline: deadline, operation: "closeReview")
            guard ContinuousClock.now < deadline else { throw LightningError.invalidState }
            guard try await channelReady(engine, peer: channel.peer, model: model,
                                         generation: epoch, operation: "closeReview") else { continue }
            do {
                let fee = try await engine.estimatedClosingFee(channelID: channel.id, peer: channel.peer,
                    destination: destination, feeRateSatPerVByte: rate)
                try Task.checkCancellation()
                try requireNetwork(model, generation: epoch)
                guard !model.status.syncing else { continue }
                return fee
            } catch LightningError.invalidState {
                try Task.checkCancellation()
                try requireNetwork(model, generation: epoch)
                // Only repeat this read-only quote if an actual new scan began
                // during its actor await, within the same readiness deadline.
                guard model.status.syncing else { throw LightningError.invalidState }
            }
        }
    }
    func close(_ review: CloseReview, model: AppModel) async throws {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            let epoch = generation
            guard let engine else { throw LightningError.invalidState }
            try await model.authenticateSensitiveAction(reason: review.force ? "Force close this \(network.rawValue) channel" : "Close this \(network.rawValue) channel")
            defer { model.keychainAuthentication.revoke() }
            try Task.checkCancellation()
            try requireNetwork(model, generation: epoch)
            let channel = review.channel
            if review.force { try await handle([engine.forceClose(channelID: channel.id, peer: channel.peer)], model: model) }
            else {
                try await engine.closeChannel(channelID: channel.id, peer: channel.peer,
                    destination: review.destination, feeSat: review.feeSat, maximumFeeSat: review.feeSat)
            }
            try await refresh()
        }
    }
}
