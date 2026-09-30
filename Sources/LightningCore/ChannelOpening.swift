import Foundation
import WalletCore

extension LightningEngine {
    func receiveOpen(peer: Data, message: LightningWire.Message) throws -> [Event] {
        let open = try ChannelNegotiation.Open(message: message)
        guard open.terms.shutdownScript.isEmpty || ChannelTerms.validShutdown(open.terms.shutdownScript, anySegwit: peers[peer]?.supports(LightningFeatures.shutdownAnySegwit) == true)
        else { throw LightningError.invalidMessage }
        guard open.chain == state.chain, state.channels.count < 64,
              !state.channels.contains(where: { $0.peer == peer && $0.temporaryID == open.temporaryID })
        else { throw LightningError.invalidMessage }
        guard !open.terms.format.hasAnchors || peers[peer]?.supports(22) == true else { throw LightningError.invalidMessage }
        let secrets = try ChannelSecrets(), terms = try secrets.terms(capacity: open.capacity, format: open.terms.format)
        let channel = ChannelState(peer: peer, temporaryID: open.temporaryID, capacity: open.capacity,
            pushMsat: open.pushMsat, feePerKW: open.feePerKW, isFunder: false, secrets: secrets,
            local: terms, remote: open.terms, phase: .accepted)
        try channel.validateNegotiation()
        let accept = ChannelNegotiation.Accept(temporaryID: open.temporaryID, minimumDepth: channel.minimumDepth, terms: terms)
        var next = state; next.channels.append(channel)
        try Self.enqueue(accept.message(), channel: channel, in: &next)
        try persist(next)
        return []
    }
    func receiveAccept(peer: Data, message: LightningWire.Message) throws -> [Event] {
        let accept = try ChannelNegotiation.Accept(message: message)
        guard accept.terms.shutdownScript.isEmpty || ChannelTerms.validShutdown(accept.terms.shutdownScript, anySegwit: peers[peer]?.supports(LightningFeatures.shutdownAnySegwit) == true)
        else { throw LightningError.invalidMessage }
        let index = try channelIndex(accept.temporaryID, peer: peer)
        var channel = state.channels[index]
        guard channel.isFunder, channel.phase == .opening else { throw LightningError.invalidState }
        channel.remote = accept.terms; channel.minimumDepth = accept.minimumDepth; channel.phase = .accepted
        try channel.validateNegotiation()
        let script = try channel.fundingScript()
        var next = state; next.channels[index] = channel
        Self.acknowledge([32], channel: channel, in: &next)
        try persist(next)
        return [.fundingRequired(temporaryID: channel.temporaryID, amountSat: channel.capacity, scriptPubKey: script)]
    }
    func receiveFundingCreated(peer: Data, message: LightningWire.Message) throws -> [Event] {
        var reader = LightningWire.Reader(message.payload)
        let temporary = try reader.take(32), txid = try reader.take(32), output = try reader.u16(), signature = try reader.take(64)
        try reader.requireEnd()
        let index = try channelIndex(temporary, peer: peer)
        var channel = state.channels[index]
        guard !channel.isFunder, channel.phase == .accepted else { throw LightningError.invalidState }
        channel.fundingTxid = txid; channel.fundingOutput = output
        try channel.acceptSignature(signature)
        channel.phase = .awaitingConfirmation
        var writer = LightningWire.Writer(); writer.append(channel.id); writer.append(try channel.remoteSignature())
        var next = state; next.channels[index] = channel
        rewindForNewFunding(in: &next)
        Self.acknowledge([33], channel: channel, in: &next)
        try Self.enqueue(.init(type: 35, payload: writer.data), channel: channel, in: &next)
        try persist(next)
        return []
    }
    func receiveFundingSigned(peer: Data, message: LightningWire.Message) throws -> [Event] {
        var reader = LightningWire.Reader(message.payload)
        let id = try reader.take(32), signature = try reader.take(64)
        try reader.requireEnd()
        let index = try channelIndex(id, peer: peer)
        var channel = state.channels[index]
        guard channel.isFunder, channel.phase == .awaitingFundingSignature,
              let funding = channel.fundingTransaction else { throw LightningError.invalidState }
        try channel.acceptSignature(signature)
        channel.phase = .awaitingConfirmation
        var next = state; next.channels[index] = channel
        Self.acknowledge([34], channel: channel, in: &next)
        try persist(next)
        return [.broadcastFunding(channelID: channel.id, transaction: funding)]
    }
    func receiveReady(peer: Data, message: LightningWire.Message) throws -> [Event] {
        var reader = LightningWire.Reader(message.payload)
        let id = try reader.take(32), point = try reader.take(33)
        _ = try reader.tlvs(known: [1]); _ = try ChannelKeys.point(point)
        let index = try channelIndex(id, peer: peer)
        var channel = state.channels[index]
        guard channel.phase == .awaitingConfirmation || channel.phase == .ready else { throw LightningError.invalidState }
        if channel.remoteReady {
            guard channel.remoteNextPoint == point else { throw LightningError.invalidMessage }
            return []
        }
        channel.remoteNextPoint = point; channel.remoteReady = true
        if channel.localReady { channel.phase = .ready }
        var next = state; next.channels[index] = channel
        Self.acknowledge([35], channel: channel, in: &next)
        try persist(next)
        return channel.phase == .ready ? [.channelReady(channel.id)] : []
    }
    /// Called by Winnow's validated chain observer. A remote channel_ready is
    /// never evidence of funding. Reorgs pause the engine via chainDisconnected.
    public func fundingConfirmed(channelID: Data, peer: Data, transaction: Transaction, confirmations: UInt32) throws -> [Event] {
        try healthy()
        let index = try channelIndex(channelID, peer: peer)
        var channel = state.channels[index]
        guard channel.phase == .awaitingConfirmation, let txid = channel.fundingTxid,
              let output = channel.fundingOutput, transaction.txid == txid,
              confirmations >= channel.minimumDepth else { throw LightningError.invalidState }
        try channel.checkFunding(transaction, output: output)
        guard channel.signedCommitment != nil else { throw LightningError.invalidState }
        if channel.localReady { return [] }
        channel.localReady = true
        channel.fundingIsConfirmed = true
        if channel.remoteReady { channel.phase = .ready }
        var writer = LightningWire.Writer(); writer.append(channel.id); writer.append(try channel.secrets.point(1))
        var next = state; next.channels[index] = channel
        try Self.enqueue(.init(type: 36, payload: writer.data), channel: channel, in: &next)
        try persist(next)
        return channel.phase == .ready ? [.channelReady(channel.id)] : []
    }
}
