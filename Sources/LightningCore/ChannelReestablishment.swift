import Foundation

extension LightningEngine {
    func prepareReestablishment(_ peer: Data) throws {
        let indices = state.channels.indices.filter {
            state.channels[$0].peer == peer && state.channels[$0].signedCommitment != nil &&
                !state.channels[$0].dataLossDetected && state.channels[$0].closingTransaction == nil && state.channels[$0].observedFundingSpend == nil
        }
        guard !indices.isEmpty else { return }
        var next = state
        for index in indices {
            var channel = next.channels[index]
            guard channel.phase != .recovering else { throw LightningError.invalidState }
            discardUncommittedIncoming(&channel)
            var writer = LightningWire.Writer(); writer.append(channel.id)
            writer.u64(channel.localNumber + 1); writer.u64(channel.revocations.received)
            let last = channel.revocations.received == 0 ? Data(repeating: 0, count: 32)
                : try channel.revocations.secret(for: channel.revocations.received - 1)
            writer.append(last); writer.append(try channel.secrets.point(channel.localNumber))
            Self.acknowledge([136], channel: channel, in: &next)
            try Self.enqueue(.init(type: 136, payload: writer.data), channel: channel, in: &next)
            next.channels[index] = channel
        }
        try persist(next)
        reestablishing.formUnion(indices.map { state.channels[$0].id })
    }
    func receiveReestablish(peer: Data, message: LightningWire.Message) throws -> [Event] {
        var reader = LightningWire.Reader(message.payload)
        let id = try reader.take(32), nextCommitment = try reader.u64(), nextRevocation = try reader.u64()
        let lastSecret = try reader.take(32), point = try reader.take(33)
        let tlvs = try reader.tlvs(known: [1, 5]); _ = try ChannelKeys.point(point)
        let index = try channelIndex(id, peer: peer)
        var channel = state.channels[index]
        try validateFundingIdentity(tlvs, channel: channel)
        guard reestablishing.contains(id), channel.signedCommitment != nil else { throw LightningError.invalidState }
        if nextRevocation > channel.localNumber {
            guard nextRevocation <= ChannelKeys.maximumCommitmentNumber,
                  try lastSecret == ChannelKeys.commitmentSecret(seed: channel.secrets.seed, number: nextRevocation - 1)
            else { throw LightningError.invalidMessage }
            // The peer proves it has a secret which this snapshot never
            // disclosed: this is a stale backup. Never publish its commitment.
            channel.phase = .recovering
            channel.dataLossDetected = true
            var next = state; next.channels[index] = channel
            next.outbox.removeAll { $0.peer == peer && $0.channelID == id }
            try persist(next)
            throw LightningError.invalidState
        }
        try validateReestablishment(channel, nextCommitment: nextCommitment, nextRevocation: nextRevocation, lastSecret: lastSecret)
        var next = state
        Self.acknowledge([136], channel: channel, in: &next)
        if nextRevocation == channel.localNumber { Self.acknowledge([133], channel: channel, in: &next) }
        if channel.awaitingRevocation, nextCommitment == channel.remoteNumber + 2, let through = channel.remoteCommitmentSequence {
            next.outbox.removeAll { $0.peer == peer && $0.channelID == id && $0.sequence <= through && [128, 130, 131, 132, 134, 135].contains($0.message.type) }
        }
        if channel.localReady, channel.localNumber == 0, nextCommitment == 1 {
            var writer = LightningWire.Writer(); writer.append(id); writer.append(try channel.secrets.point(1))
            Self.acknowledge([36], channel: channel, in: &next)
            try Self.enqueue(.init(type: 36, payload: writer.data), channel: channel, in: &next)
        }
        try persist(next)
        reestablishing.remove(id)
        return []
    }
    private func validateFundingIdentity(_ tlvs: [LightningWire.TLV], channel: ChannelState) throws {
        // A static-remotekey channel can carry its original funding identity.
        // This private-channel profile cannot resume interactive funding.
        guard !tlvs.contains(where: { $0.type == 1 }) else { throw LightningError.invalidMessage }
        if let locked = tlvs.first(where: { $0.type == 5 }) {
            var funding = LightningWire.Reader(locked.value)
            guard try funding.take(32) == channel.fundingTxid, try funding.u8() == 0 else { throw LightningError.invalidMessage }
            try funding.requireEnd()
        }
    }
    private func validateReestablishment(_ channel: ChannelState, nextCommitment: UInt64,
                                        nextRevocation: UInt64, lastSecret: Data) throws {
        guard nextCommitment == channel.remoteNumber + 1 || (channel.awaitingRevocation && nextCommitment == channel.remoteNumber + 2),
              nextRevocation == channel.localNumber || (channel.localNumber > 0 && nextRevocation == channel.localNumber - 1)
        else { throw LightningError.invalidMessage }
        let expected = nextRevocation == 0 ? Data(repeating: 0, count: 32)
            : try ChannelKeys.commitmentSecret(seed: channel.secrets.seed, number: nextRevocation - 1)
        guard lastSecret == expected else { throw LightningError.invalidMessage }
    }
    private func discardUncommittedIncoming(_ channel: inout ChannelState) {
        for update in channel.updates where !update.fromLocal && update.localNumber == nil {
            if case .add(let htlc, _) = update.change { channel.nextRemoteHTLC = min(channel.nextRemoteHTLC, htlc.id); channel.incomingBlinding.removeValue(forKey: htlc.id) }
        }
        channel.updates.removeAll { !$0.fromLocal && $0.localNumber == nil }
    }
    /// A process can stop after funding_signed is persisted but before the
    /// callback reaches the Bitcoin broadcaster. Derive that work from the
    /// journal on every restart; a one-shot in-memory event is insufficient.
    public func pendingFundingBroadcasts() throws -> [Event] {
        try healthy()
        guard chainIsCurrent else { throw LightningError.invalidState }
        return state.channels.compactMap { channel in
            guard channel.isFunder, channel.phase == .awaitingConfirmation,
                  !channel.localReady, channel.signedCommitment != nil,
                  let transaction = channel.fundingTransaction else { return nil }
            return .broadcastFunding(channelID: channel.id, transaction: transaction)
        }
    }
}
