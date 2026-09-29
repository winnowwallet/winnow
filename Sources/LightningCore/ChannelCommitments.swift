import Foundation

extension LightningEngine {
    func signPending(_ channel: inout ChannelState, in next: inout State) throws {
        guard !channel.awaitingRevocation, channel.updates.contains(where: { $0.pending(localOwner: false) }) else { return }
        guard channel.remoteNumber < ChannelKeys.maximumCommitmentNumber, let point = channel.remoteNextPoint else { throw LightningError.invalidState }
        let number = channel.remoteNumber + 1
        try channel.includeUpdates(localOwner: false, number: number)
        let commitment = try channel.commitment(localOwner: false, number: number)
        let signature = try ChannelKeys.sign(digest: ChannelTransactions.fundingDigest(commitment), secret: channel.secrets.funding)
        let htlcKey = try ChannelKeys.derivedPrivateKey(baseSecret: channel.secrets.htlc, commitmentPoint: point)
        var writer = LightningWire.Writer(); writer.append(channel.id); writer.append(try ChannelKeys.compactSignature(signature))
        writer.u16(UInt16(commitment.htlcOutputs.count))
        for output in commitment.htlcOutputs {
            let digest = try ChannelRecovery.htlcDigest(commitment: commitment, output: output)
            writer.append(try ChannelKeys.compactSignature(ChannelKeys.sign(digest: digest, secret: htlcKey)))
        }
        if let txid = channel.fundingTxid { try writer.tlvs([.init(type: 1, value: txid)]) }
        channel.awaitingRevocation = true
        try Self.enqueue(.init(type: 132, payload: writer.data), channel: channel, in: &next)
        channel.remoteCommitmentSequence = next.nextSequence - 1
    }
    func receiveCommitment(peer: Data, message: LightningWire.Message) throws -> [Event] {
        var reader = LightningWire.Reader(message.payload)
        let id = try reader.take(32), signature = try reader.take(64), count = try reader.u16()
        guard count <= 966 else { throw LightningError.invalidMessage }
        let signatures = try (0..<count).map { _ in try ChannelKeys.derSignature(reader.take(64)) }
        let tlvs = try reader.tlvs(known: [1])
        let index = try activeChannelIndex(id, peer: peer)
        var channel = state.channels[index]
        if let funding = tlvs.first(where: { $0.type == 1 }) {
            guard funding.value == channel.fundingTxid else { throw LightningError.invalidMessage }
        }
        guard channel.localNumber < ChannelKeys.maximumCommitmentNumber - 1 else { throw LightningError.invalidState }
        let oldNumber = channel.localNumber, number = oldNumber + 1
        try channel.includeUpdates(localOwner: true, number: number)
        let commitment = try channel.commitment(localOwner: true, number: number)
        guard signatures.count == commitment.htlcOutputs.count else { throw LightningError.invalidSignature }
        for (output, signature) in zip(commitment.htlcOutputs, signatures) {
            guard try ChannelKeys.verify(signature: signature, digest: ChannelRecovery.htlcDigest(commitment: commitment, output: output),
                publicKey: commitment.parameters.keys.htlcRemote) else { throw LightningError.invalidSignature }
        }
        channel.localNumber = number
        try channel.acceptSignature(signature)
        channel.localHTLCSignatures = signatures
        var writer = LightningWire.Writer(); writer.append(id)
        writer.append(try ChannelKeys.commitmentSecret(seed: channel.secrets.seed, number: oldNumber))
        writer.append(try channel.secrets.point(number + 1))
        var next = state
        Self.acknowledge([133], channel: channel, in: &next)
        try Self.enqueue(.init(type: 133, payload: writer.data), channel: channel, in: &next)
        try signPending(&channel, in: &next)
        next.channels[index] = channel
        let events = try reconcilePayments(in: &next)
        try persist(next)
        return events
    }
    func receiveRevocation(peer: Data, message: LightningWire.Message) throws -> [Event] {
        var reader = LightningWire.Reader(message.payload)
        let id = try reader.take(32), secret = try reader.take(32), point = try reader.take(33)
        let fields = try reader.tlvs(known: [75537]); _ = try ChannelKeys.point(point)
        let releasePaths = try fields.first(where: { $0.type == 75537 }).map { try HTLCReleasePath.decode($0.value) } ?? []
        let index = try activeChannelIndex(id, peer: peer)
        var channel = state.channels[index]
        guard channel.awaitingRevocation,
              try ChannelKeys.publicKey(secret: secret) == channel.commitmentPoint(localOwner: false, number: channel.remoteNumber)
        else { throw LightningError.invalidCommitment }
        let previous = try channel.commitment(localOwner: false).transaction.serialized(includeWitness: false)
        try channel.revocations.insert(secret: secret, commitmentNumber: channel.remoteNumber)
        channel.previousRemoteCommitments.append(previous)
        channel.remoteNumber += 1
        channel.remoteCurrentPoint = channel.remoteNextPoint
        channel.remoteNextPoint = point; channel.awaitingRevocation = false
        for index in channel.updates.indices where channel.updates[index].remoteNumber == channel.remoteNumber {
            channel.updates[index].remoteAcknowledged = true
        }
        var next = state
        if let through = channel.remoteCommitmentSequence {
            next.outbox.removeAll { $0.peer == peer && $0.channelID == id && $0.sequence <= through && [128, 130, 131, 132, 134, 135].contains($0.message.type) }
        }
        try recordReleasePaths(releasePaths, channel: channel, in: &next)
        channel.remoteCommitmentSequence = nil
        try signPending(&channel, in: &next)
        next.channels[index] = channel
        let events = try reconcilePayments(in: &next)
        try persist(next)
        return events
    }
    func activeChannelIndex(_ id: Data, peer: Data) throws -> Int {
        let index = try channelIndex(id, peer: peer)
        guard [.ready, .closing].contains(state.channels[index].phase), state.channels[index].fundingIsConfirmed,
              state.channels[index].observedFundingSpend == nil,
              state.channels[index].closingTransaction == nil, state.channels[index].recovery != nil,
              !reestablishing.contains(id) else { throw LightningError.invalidState }
        return index
    }
}
