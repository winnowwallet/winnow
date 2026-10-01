import CryptoKit
import Foundation
import LightningCore
import WalletCore

extension LightningAppController {
    struct FeeBumpReview: Codable {
        let quote: AnchorFeeBump
        let peer: Data
        let requestID: String
        let rate: Double
        let htlcTransactionID: Data?
    }
    private func feeBumpRequestID(channel: Data, htlc: Data?) -> String {
        "lightning-bump-" + Data(SHA256.hash(data: channel + (htlc ?? Data()))).hex
    }
    func reviewFeeBump(channel: LightningEngine.Channel, maximumFeeSat: UInt64, model: AppModel,
                       htlcTransactionID: Data? = nil) async throws -> FeeBumpReview {
        try requireNetwork(model)
        let epoch = generation
        guard let engine, let wallet = model.wallet, maximumFeeSat <= 100_000 else { throw LightningError.invalidAmount }
        let requestID = feeBumpRequestID(channel: channel.id, htlc: htlcTransactionID)
        let existing = await wallet.recoverySpendReservations.first { $0.requestID == requestID }
        let next = await wallet.nextChangeIndex, index = existing?.changeIndex ?? next
        let destination = try await wallet.scriptPubKey(chain: .change, index: index)
        let coins = try await wallet.recoverySpendCoins(requestID: requestID)
        let records = try await engine.anchorFeeBumps(channelID: channel.id, peer: channel.peer)
        let replacing = try records.last(where: { try matchesFeeBump($0, htlcTransactionID: htlcTransactionID) })?.transaction().txid
        let rate = await model.resolvedFeeRate(priority: .medium, override: nil)
        try requireNetwork(model, generation: epoch)
        let quote = try await engine.anchorFeeBumpQuote(id: Self.freshID(), channelID: channel.id, peer: channel.peer, coins: coins,
            destination: destination, feeRateSatPerVByte: rate, totalFeeLimitSat: maximumFeeSat,
            htlcTransactionID: htlcTransactionID, replacingTxid: replacing)
        return FeeBumpReview(quote: quote, peer: channel.peer, requestID: requestID, rate: rate, htlcTransactionID: htlcTransactionID)
    }
    private func matchesFeeBump(_ record: AnchorFeeBump, htlcTransactionID: Data?) throws -> Bool {
        guard let htlcTransactionID else { return record.kind == .commitment }
        guard record.kind == .htlc else { return false }
        var stage = try Transaction.decode(record.unsignedTransaction)
        stage.inputs = Array(stage.inputs.prefix(1)); stage.outputs.removeLast()
        return stage.txid == htlcTransactionID
    }
    func approveFeeBump(_ review: FeeBumpReview, model: AppModel) async throws {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            let epoch = generation
            guard let engine, let wallet = model.wallet else { throw AppModel.AppError.noWallet }
            try await model.authenticateSensitiveAction(reason: "Approve the \(review.quote.totalFeeLimitSat)-sat maximum Lightning recovery fee")
            defer { model.keychainAuthentication.revoke() }
            try Task.checkCancellation(); try requireNetwork(model, generation: epoch)
            try await recheckFeeBump(review, wallet: wallet, engine: engine)
            try storeFeeBumpAuthorization(review)
            let spent = try review.quote.spentOutputs()[0]
            let reserved = try await wallet.reserveRecoverySpend(requestID: review.requestID,
                transaction: Transaction.decode(review.quote.unsignedTransaction), coins: review.quote.selected,
                externalOutput: .init(value: spent.amount, scriptPubKey: spent.scriptPubKey),
                feeLimit: Int64(review.quote.totalFeeLimitSat - review.quote.parentFeeSat))
            try await wallet.markRecoverySpendSubmitted(requestID: review.requestID)
            try await commitApprovedFeeBump(review, reservation: reserved, model: model)
        }
    }
    private func recheckFeeBump(_ review: FeeBumpReview, wallet: Wallet, engine: LightningEngine) async throws {
        let coins = try await wallet.recoverySpendCoins(requestID: review.requestID)
        let tx = try Transaction.decode(review.quote.unsignedTransaction)
        let quote = try await engine.anchorFeeBumpQuote(id: review.quote.id, channelID: review.quote.channelID, peer: review.peer, coins: coins,
            destination: tx.outputs[tx.outputs.count - 1].scriptPubKey, feeRateSatPerVByte: review.rate,
            totalFeeLimitSat: review.quote.totalFeeLimitSat, htlcTransactionID: review.htlcTransactionID, replacingTxid: review.quote.replacesTxid)
        guard quote.unsignedTransaction == review.quote.unsignedTransaction else { throw AppModel.AppError.sendReviewChanged }
    }
    private func commitApprovedFeeBump(_ review: FeeBumpReview, reservation: RecoverySpendReservation, model: AppModel) async throws {
        try requireNetwork(model)
        guard let engine else { throw LightningError.invalidState }
        let events = try await engine.commitAnchorFeeBump(review.quote, peer: review.peer, walletSignedTransaction: reservation.transaction())
        try await handle(events, model: model)
        try removeFeeBumpAuthorization(review.requestID, quoteID: review.quote.id)
        try await refresh()
    }
    func resumeApprovedFeeBumps(model: AppModel) async throws {
        try requireNetwork(model)
        guard let wallet = model.wallet else { return }
        let reservations = await wallet.recoverySpendReservations
        for review in try loadFeeBumpAuthorizations() {
            try await resumeApprovedFeeBump(review, reservations: reservations, wallet: wallet, model: model)
        }
    }
    private func resumeApprovedFeeBump(_ review: FeeBumpReview, reservations: [RecoverySpendReservation], wallet: Wallet, model: AppModel) async throws {
        guard let reserved = reservations.first(where: { $0.requestID == review.requestID }) else { return }
        try validateApprovedReservation(reserved, review: review)
        if !reserved.submitted { try await wallet.markRecoverySpendSubmitted(requestID: reserved.requestID) }
        try await commitApprovedFeeBump(review, reservation: reserved, model: model)
    }
    func validateApprovedReservation(_ reservation: RecoverySpendReservation, review: FeeBumpReview) throws {
        let proposed = try Transaction.decode(review.quote.unsignedTransaction), signed = try reservation.transaction()
        let external = try review.quote.spentOutputs()[0]
        guard reservation.requestID == review.requestID, reservation.selected == review.quote.selected,
              reservation.externalValue == external.amount, reservation.externalScript == external.scriptPubKey,
              reservation.feeLimit == Int64(review.quote.totalFeeLimitSat - review.quote.parentFeeSat),
              signed.serialized(includeWitness: false) == proposed.serialized(includeWitness: false),
              signed.inputs[0].witness == proposed.inputs[0].witness else { throw LightningError.storageFailed }
    }
    func acknowledgeFeeBump(_ event: LightningEngine.Event, wallet: Wallet) async throws {
        guard case .broadcastRecovery(_, let raw) = event else { return }
        let tx = try Transaction.decode(raw)
        guard let saved = try await wallet.recoverySpendReservations.first(where: { try $0.transaction().txid == tx.txid }) else { return }
        try await wallet.commitRecoverySpendBroadcast(requestID: saved.requestID, transaction: tx)
    }
}
