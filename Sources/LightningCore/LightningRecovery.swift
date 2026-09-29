import Foundation
import WalletCore

extension LightningEngine {
    /// Winnow supplies a wallet-owned destination and an explicitly bounded
    /// per-transaction recovery fee before a channel accepts payments.
    public func configureRecovery(channelID: Data, peer: Data, destination: Data, feeSat: UInt64) throws {
        try healthy()
        let index = try channelIndex(channelID, peer: peer)
        let policy = ChannelResolution.Policy(destination: destination, feeSat: feeSat)
        // Our unilateral recovery output is independent of peer shutdown
        // negotiation and can use Winnow's native Taproot receive address.
        guard ChannelTerms.validShutdown(destination, anySegwit: true), feeSat > 0, feeSat < state.channels[index].capacity else {
            throw LightningError.invalidAmount
        }
        if state.channels[index].recovery == policy { return }
        guard state.channels[index].resolutions.isEmpty, state.channels[index].observedFundingSpend == nil else {
            throw LightningError.invalidState
        }
        var next = state; next.channels[index].recovery = policy
        try persist(next)
    }

    /// Saves the broadcast intent before returning the latest enforceable
    /// commitment. A stale backup proven by the peer can never take this path.
    public func forceClose(channelID: Data, peer: Data) throws -> Event {
        try healthy()
        guard chainIsCurrent else { throw LightningError.invalidState }
        let index = try channelIndex(channelID, peer: peer)
        var next = state
        try forceClose(index: index, in: &next)
        let raw = next.channels[index].closingTransaction!
        try persist(next)
        return .broadcastClose(channelID: channelID, transaction: raw)
    }
    private func forceClose(index: Int, in next: inout State) throws {
        var channel = next.channels[index]
        guard !channel.dataLossDetected, channel.recovery != nil, channel.observedFundingSpend == nil,
              let raw = channel.signedCommitment else { throw LightningError.invalidState }
        channel.phase = .closing
        _ = markPaymentsRecovering(channelID: channel.id, in: &next)
        if channel.closingTransaction == nil { channel.closingTransaction = raw }
        next.outbox.removeAll { $0.channelID == channel.id && $0.peer == channel.peer }
        next.channels[index] = channel
    }
    public func pendingRecoveryBroadcasts() throws -> [Event] {
        try healthy()
        guard chainIsCurrent else { throw LightningError.invalidState }
        return try recoveryEvents(in: state, height: chainHeight)
    }
    func updateRecovery(height: UInt32, in next: inout State) throws -> [Event] {
        let confirmed = try next.scan.transactions.map { ChannelResolution.Confirmed(height: $0.height, tx: try Transaction.decode($0.raw)) }
        var preimages = next.incoming.map(\.preimage)
        for channel in next.channels { preimages += channel.learnedPreimages }
        for index in next.channels.indices {
            let channel = next.channels[index]
            guard let policy = channel.recovery else { continue }
            if let raw = channel.observedFundingSpend {
                try resolve(index: index, raw: raw, policy: policy, confirmed: confirmed, preimages: preimages, in: &next)
            } else if try requiresForceClose(channel, height: height, preimages: preimages) {
                try forceClose(index: index, in: &next)
            }
        }
        return try recoveryEvents(in: next, height: height)
    }
    private func resolve(index: Int, raw: Data, policy: ChannelResolution.Policy, confirmed: [ChannelResolution.Confirmed],
                         preimages: [Data], in next: inout State) throws {
        let channel = next.channels[index], parent = try Transaction.decode(raw)
        let found = onChainPreimages(channel: channel, confirmed: confirmed)
        for preimage in found where !next.channels[index].learnedPreimages.contains(preimage) {
            next.channels[index].learnedPreimages.append(preimage)
        }
        let context = ChannelResolution.Context(channel: channel, policy: policy, confirmed: confirmed, preimages: preimages + found)
        for candidate in try context.candidates(parent: parent) {
            let txid = try Transaction.decode(candidate.transaction).txid
            if !next.channels[index].resolutions.contains(where: { (try? Transaction.decode($0.transaction).txid) == txid }) {
                next.channels[index].resolutions.append(candidate)
            }
        }
    }
    private func onChainPreimages(channel: ChannelState, confirmed: [ChannelResolution.Confirmed]) -> [Data] {
        let hashes = Set(channel.updates.compactMap { update -> Data? in
            if case .add(let htlc, _) = update.change { return htlc.paymentHash }; return nil
        })
        return confirmed.flatMap { $0.tx.inputs.flatMap(\.witness) }.filter { $0.count == 32 && hashes.contains(ChannelKeys.hash($0)) }
    }
    private func requiresForceClose(_ channel: ChannelState, height: UInt32, preimages: [Data]) throws -> Bool {
        guard channel.phase == .ready, !channel.dataLossDetected else { return false }
        let local = try channel.view(localOwner: true, number: channel.localNumber).htlcs
        return local.contains { htlc in
            if htlc.offered { return height >= htlc.expiry }
            return UInt64(height) + 6 >= UInt64(htlc.expiry) && preimages.contains { ChannelKeys.hash($0) == htlc.paymentHash }
        }
    }
    private func recoveryEvents(in next: State, height: UInt32) throws -> [Event] {
        let confirmed = try next.scan.transactions.map { ChannelResolution.Confirmed(height: $0.height, tx: try Transaction.decode($0.raw)) }
        return try next.channels.flatMap { channel in
            var events: [Event] = []
            if channel.observedFundingSpend == nil, let raw = channel.closingTransaction, channel.phase == .closing {
                events.append(.broadcastClose(channelID: channel.id, transaction: raw))
            }
            for resolution in channel.resolutions where try ChannelResolution.available(resolution, confirmed: confirmed, height: height) {
                if try channel.local.format.hasAnchors && isAnchorHTLC(Transaction.decode(resolution.transaction)) { continue }
                events.append(.broadcastRecovery(channelID: channel.id, transaction: resolution.transaction))
            }
            events += try pendingFeeBumpEvents(channel: channel, confirmed: confirmed)
            return events
        }
    }
}
