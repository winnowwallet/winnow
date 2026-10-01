import Foundation

extension LightningEngine {
    func prepareRecoveryReestablishment(_ peer: Data) throws {
        var next = state
        for channel in next.channels where channel.peer == peer && channel.observedFundingSpend == nil {
            var writer = LightningWire.Writer(); writer.append(channel.id)
            // BOLT 2: a zero next commitment number asks the peer to fail the
            // channel using its latest state. We never publish backup state.
            writer.u64(0); writer.u64(0); writer.append(Data(repeating: 0, count: 32))
            writer.append(try channel.secrets.point(channel.localNumber))
            Self.acknowledge([17, 136], channel: channel, in: &next)
            try Self.enqueue(.init(type: 136, payload: writer.data), channel: channel, in: &next)
        }
        try persist(next)
    }
    func receiveRecoveryMessage(peer: Data, message: LightningWire.Message) throws -> [Event] {
        guard message.type == 136 else { throw LightningError.invalidState }
        var reader = LightningWire.Reader(message.payload)
        let id = try reader.take(32), nextCommitment = try reader.u64(), nextRevocation = try reader.u64()
        let lastSecret = try reader.take(32), point = try reader.take(33)
        _ = try reader.tlvs(known: [])
        _ = try ChannelKeys.point(point)
        let index = try channelIndex(id, peer: peer), channel = state.channels[index]
        guard nextCommitment <= ChannelKeys.maximumCommitmentNumber,
              nextRevocation <= ChannelKeys.maximumCommitmentNumber else { throw LightningError.invalidMessage }
        let expected = nextRevocation == 0 ? Data(repeating: 0, count: 32)
            : try ChannelKeys.commitmentSecret(seed: channel.secrets.seed, number: nextRevocation - 1)
        guard lastSecret == expected else { throw LightningError.invalidMessage }
        var next = state
        if next.recoveryRestore?.respondingPeers.contains(peer) == false { next.recoveryRestore?.respondingPeers.append(peer) }
        Self.acknowledge([136], channel: channel, in: &next)
        // Explicitly ask for peer closure after proof. This also covers peers
        // which respond to reestablish before processing our zero counter.
        let detail = Data("Recovery-only restored backup; please close using your latest commitment".utf8)
        var writer = LightningWire.Writer(); writer.append(channel.id); writer.u16(UInt16(detail.count)); writer.append(detail)
        try Self.enqueue(.init(type: 17, payload: writer.data), channel: channel, in: &next)
        try persist(next)
        return []
    }
}
