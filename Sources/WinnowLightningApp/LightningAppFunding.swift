import Foundation
import LightningCore
import WalletCore

extension LightningAppController {
    struct FundingReview {
        let request: LightningEngine.FundingRequest
        let preview: AppModel.SendPreview
    }
    static func commitmentFeeRate(satPerVByte rate: Double) throws -> UInt32 {
        guard rate.isFinite, rate > 0, rate <= 400 else { throw LightningError.invalidAmount }
        return max(253, UInt32((rate * 250).rounded(.up)))
    }
    func openChannel(capacitySat: UInt64, model: AppModel) async throws {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            let epoch = generation
            guard let engine, let profile, await engine.channels().allSatisfy({ $0.phase == .closed }) else { throw LightningError.invalidState }
            let rate = try Self.commitmentFeeRate(satPerVByte: await model.resolvedFeeRate(priority: .medium, override: nil))
            try requireNetwork(model, generation: epoch)
            _ = try await engine.openChannel(peer: profile.peerKey, capacitySat: capacitySat, feePerKW: rate)
            try await refresh()
        }
    }
    func reviewFunding(_ request: LightningEngine.FundingRequest, model: AppModel) async throws -> FundingReview {
        try requireNetwork(model)
        guard let wallet = model.wallet,
              let destination = AddressDecoder.address(for: request.scriptPubKey, network: network) else { throw LightningError.invalidMessage }
        let preview: AppModel.SendPreview
        if let reserved = await wallet.fundingReservations.first(where: { $0.requestID == request.temporaryID.hex }) {
            guard reserved.phase == .reserved, reserved.amount == Int64(request.amountSat), reserved.scriptPubKey == request.scriptPubKey else {
                throw LightningError.invalidState
            }
            let tx = try reserved.transaction(), change = try reserved.changeOutput()
            preview = AppModel.SendPreview(destination: destination, payments: [.init(amount: reserved.amount, scriptPubKey: reserved.scriptPubKey)],
                feeRateSatPerVByte: reserved.feeRateSatPerVByte, fee: reserved.fee, changeAmount: change?.value, inputCount: tx.inputs.count,
                selectedOutpoints: tx.inputs.map { .init(txid: $0.previousOutput.txid, vout: $0.previousOutput.vout) },
                change: change.map { .init(amount: $0.value, scriptPubKey: $0.scriptPubKey) })
        } else {
            preview = try await model.previewSend(destination: destination, amount: Int64(request.amountSat), priority: .medium, override: nil)
        }
        return FundingReview(request: request, preview: preview)
    }
    func fund(_ review: FundingReview, model: AppModel) async throws {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            let epoch = generation
            _ = try await fundingContext(review, model: model)
            try await model.authenticateSensitiveAction(reason: "Fund this \(network.rawValue) Lightning channel")
            defer { model.keychainAuthentication.revoke() }
            let (engine, wallet) = try await currentFundingContext(review, model: model, generation: epoch)
            let request = review.request, preview = review.preview
            let reservation = try await wallet.reserveChannelFunding(requestID: request.temporaryID.hex, amount: Int64(request.amountSat),
                scriptPubKey: request.scriptPubKey, feeRateSatPerVByte: preview.feeRateSatPerVByte, chainTip: model.chainTipHeight)
            guard try preview.authorizes(transaction: reservation.transaction(), fee: reservation.fee, changeAmount: reservation.changeOutput()?.value) else {
                try await wallet.cancelUnsubmittedFunding(requestID: reservation.requestID)
                throw AppModel.AppError.sendReviewChanged
            }
            let submitted = try await wallet.markFundingSubmitted(requestID: reservation.requestID)
            try await supply(submitted, request: request, engine: engine)
            try await refresh()
        }
    }
    private func fundingContext(_ review: FundingReview, model: AppModel) async throws -> (LightningEngine, Wallet) {
        guard let engine, let wallet = model.wallet else { throw channelReadinessRejected("missingContext", model: model) }
        guard try await engine.fundingRequests().contains(review.request) else {
            throw channelReadinessRejected("requestChanged", model: model)
        }
        return (engine, wallet)
    }
    private func currentFundingContext(_ review: FundingReview, model: AppModel,
                                       generation epoch: UInt64) async throws -> (LightningEngine, Wallet) {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            try await awaitChannelScan(model: model, generation: epoch, deadline: deadline)
            let context = try await fundingContext(review, model: model)
            if try await channelReady(context.0, peer: review.request.peer, model: model, generation: epoch) {
                return context
            }
            // An actor read yielded to a newly started scan. Repeat only the
            // readiness reads within this same deadline, never funding itself.
        }
    }
    func channelReady(_ engine: LightningEngine, peer: Data, model: AppModel,
                      generation epoch: UInt64, operation: String = "funding") async throws -> Bool {
        try Task.checkCancellation()
        try requireNetwork(model, generation: epoch)
        guard !model.status.syncing else { return false }
        guard model.status.lastSyncError == nil else { throw channelReadinessRejected("scanFailed", model: model, operation: operation) }
        let current = await engine.isChainCurrent()
        try Task.checkCancellation()
        try requireNetwork(model, generation: epoch)
        guard !model.status.syncing else { return false }
        guard current else { throw channelReadinessRejected("chainNotCurrent", model: model, operation: operation) }
        // This read-only gate requires the peer to be initialized as well.
        do { _ = try await engine.pendingMessages(peer: peer) }
        catch LightningError.invalidState {
            try Task.checkCancellation()
            try requireNetwork(model, generation: epoch)
            guard !model.status.syncing else { return false }
            throw channelReadinessRejected("peerNotReady", model: model, operation: operation)
        }
        try Task.checkCancellation()
        try requireNetwork(model, generation: epoch)
        return !model.status.syncing
    }
    /// Wait for only a scan already in progress. It still has to finish with
    /// verified current state; approval never starts or retries a financial act.
    func awaitChannelScan(model: AppModel, generation epoch: UInt64,
                          deadline: ContinuousClock.Instant, operation: String = "funding") async throws {
        try Task.checkCancellation()
        try requireNetwork(model, generation: epoch)
        guard model.status.syncing else { return }
        model.e2e?.journal("lightning.\(operation)ScanWait", fields: ["network": network.rawValue])
        while model.status.syncing {
            try Task.checkCancellation()
            try requireNetwork(model, generation: epoch)
            guard ContinuousClock.now < deadline else { throw channelReadinessRejected("scanWaitExpired", model: model, operation: operation) }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard ContinuousClock.now < deadline else { throw channelReadinessRejected("scanWaitExpired", model: model, operation: operation) }
        try Task.checkCancellation()
        try requireNetwork(model, generation: epoch)
    }
    private func channelReadinessRejected(_ stage: String, model: AppModel, operation: String = "funding") -> LightningError {
        model.e2e?.journal("lightning.\(operation)ReadinessRejected", fields: ["stage": stage, "network": network.rawValue])
        return .invalidState
    }
    func resumeSubmittedFunding(model: AppModel) async throws {
        try requireNetwork(model)
        let epoch = generation
        guard let engine, let wallet = model.wallet else { return }
        let requests = try await engine.fundingRequests()
        for reservation in await wallet.fundingReservations where reservation.phase == .submitted {
            try requireNetwork(model, generation: epoch)
            if let request = requests.first(where: { $0.temporaryID.hex == reservation.requestID }) {
                try await supply(reservation, request: request, engine: engine)
            }
        }
        try await handle(engine.pendingFundingBroadcasts(), model: model)
    }
    private func supply(_ reservation: FundingReservation, request: LightningEngine.FundingRequest, engine: LightningEngine) async throws {
        let tx = try reservation.transaction()
        guard reservation.phase == .submitted, reservation.amount == Int64(request.amountSat), reservation.scriptPubKey == request.scriptPubKey,
              let index = tx.outputs.firstIndex(where: { $0.scriptPubKey == request.scriptPubKey && $0.value == Int64(request.amountSat) }),
              let output = UInt16(exactly: index) else { throw LightningError.invalidMessage }
        try await engine.provideFunding(temporaryID: request.temporaryID, peer: request.peer, transaction: tx, output: output)
    }
}
