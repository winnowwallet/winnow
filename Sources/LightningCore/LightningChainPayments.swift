import Foundation
import WalletCore

extension LightningEngine {
    struct PaymentChainResolution: Codable {
        let transactionID: Data
        let height: UInt32
        let preimage: Data?
    }
    func markPaymentsRecovering(channelID: Data, in next: inout State) -> [Event] {
        var events: [Event] = []
        for index in next.payments.indices where next.payments[index].channelID == channelID {
            let payment = next.payments[index].payment
            guard [.preparing, .inFlight, .awaitingRecipient].contains(payment.phase) else { continue }
            next.payments[index].payment.phase = payment.phase == .preparing ? .failed : .recovering
            next.async.outbox.removeAll { $0.key == Data([1]) + payment.id || $0.key == Data([5]) + payment.id }
            events.append(.paymentChanged(next.payments[index].payment))
        }
        return events
    }
    func reconcileChainPayments(height: UInt32, in next: inout State) throws -> [Event] {
        let confirmed = try next.scan.transactions.map { ChannelResolution.Confirmed(height: $0.height, tx: try Transaction.decode($0.raw)) }
        var events: [Event] = []
        for index in next.payments.indices {
            let record = next.payments[index]
            guard record.payment.phase == .recovering,
                  let channel = next.channels.first(where: { $0.id == record.channelID }),
                  let resolution = try chainResolution(record, channel: channel, confirmed: confirmed),
                  UInt64(height) + 1 >= UInt64(resolution.height) + 6 else { continue }
            next.payments[index].chainResolution = resolution
            next.payments[index].payment.phase = resolution.preimage == nil ? .failed : .settled
            next.payments[index].payment.preimage = resolution.preimage
            events.append(.paymentChanged(next.payments[index].payment))
        }
        return events
    }
    private func chainResolution(_ record: PaymentRecord, channel: ChannelState,
                                 confirmed: [ChannelResolution.Confirmed]) throws -> PaymentChainResolution? {
        guard !channel.dataLossDetected, let raw = channel.observedFundingSpend, let policy = channel.recovery,
              let parentHeight = channel.fundingSpendHeight else { return nil }
        let parent = try Transaction.decode(raw)
        let context = ChannelResolution.Context(channel: channel, policy: policy, confirmed: confirmed, preimages: [])
        guard let commitment = try context.recognized(parent),
              commitment.local || commitment.value.parameters.number >= channel.revocations.received else { return nil }
        if let output = commitment.value.htlcOutputs.first(where: { $0.htlc.paymentHash == record.payment.hash }) {
            let outpoint = Transaction.Outpoint(txid: parent.txid, vout: output.index)
            guard let spend = confirmed.first(where: { $0.tx.inputs.contains { $0.previousOutput == outpoint } }),
                  let input = spend.tx.inputs.first(where: { $0.previousOutput == outpoint }) else { return nil }
            let preimage = input.witness.first { $0.count == 32 && ChannelKeys.hash($0) == record.payment.hash }
            return .init(transactionID: spend.tx.txid, height: spend.height, preimage: preimage)
        }
        // This commitment either already incorporated the removal or trimmed
        // the HTLC. Only an included, authenticated fulfill establishes success.
        let preimage = includedFulfill(record, channel: channel, local: commitment.local, number: commitment.value.parameters.number)
        return .init(transactionID: parent.txid, height: parentHeight, preimage: preimage)
    }
    private func includedFulfill(_ record: PaymentRecord, channel: ChannelState, local: Bool, number: UInt64) -> Data? {
        for update in channel.updates {
            guard let included = local ? update.localNumber : update.remoteNumber, included <= number,
                  case .fulfill(let id, let offered, let preimage) = update.change,
                  id == record.htlcID, offered != record.payment.incoming,
                  ChannelKeys.hash(preimage) == record.payment.hash else { continue }
            return preimage
        }
        return nil
    }
    func rollBackChainPayments(to height: UInt32, in next: inout State) {
        for index in next.payments.indices {
            guard let resolution = next.payments[index].chainResolution,
                  UInt64(height) + 1 < UInt64(resolution.height) + 6 else { continue }
            next.payments[index].payment.phase = .recovering
            next.payments[index].chainResolution = nil
            // Learned preimages remain known even when their revealing block
            // disconnects. Only settlement status depends on chain ancestry.
        }
    }
}
