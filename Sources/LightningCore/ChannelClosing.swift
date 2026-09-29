import Foundation
import WalletCore

extension LightningEngine {
    public func closeChannel(channelID: Data, peer: Data, destination: Data, feeSat: UInt64, maximumFeeSat: UInt64) throws {
        try operational(peer)
        let index = try channelIndex(channelID, peer: peer)
        var channel = state.channels[index]
        guard [.ready, .closing].contains(channel.phase), channel.fundingIsConfirmed, !reestablishing.contains(channelID),
              ChannelTerms.validShutdown(destination, anySegwit: peers[peer]?.supports(LightningFeatures.shutdownAnySegwit) == true), feeSat <= maximumFeeSat, maximumFeeSat < channel.capacity
        else { throw LightningError.invalidState }
        try channel.requireQuiescent()
        guard channel.local.shutdownScript.isEmpty || channel.local.shutdownScript == destination else { throw LightningError.invalidMessage }
        guard channel.localShutdown == nil else { throw LightningError.invalidState }
        channel.localShutdown = destination; channel.closingFee = feeSat; channel.closingFeeLimit = maximumFeeSat
        channel.phase = .closing
        var next = state
        var writer = LightningWire.Writer(); writer.append(channelID); writer.u16(UInt16(destination.count)); writer.append(destination)
        try Self.enqueue(.init(type: 38, payload: writer.data), channel: channel, in: &next)
        if channel.isFunder && channel.remoteShutdown != nil { try proposeClose(channel: channel, in: &next) }
        next.channels[index] = channel
        try persist(next)
    }
    func receiveClose(peer: Data, message: LightningWire.Message) throws -> [Event] {
        var reader = LightningWire.Reader(message.payload)
        let id = try reader.take(32), index = try channelIndex(id, peer: peer)
        var channel = state.channels[index]
        guard [.ready, .closing].contains(channel.phase), channel.fundingIsConfirmed,
              channel.observedFundingSpend == nil, !reestablishing.contains(id) else { throw LightningError.invalidState }
        var next = state
        if message.type == 38 {
            let length = try reader.u16(), script = try reader.take(Int(length)); _ = try reader.tlvs(known: [])
            guard ChannelTerms.validShutdown(script, anySegwit: peers[peer]?.supports(LightningFeatures.shutdownAnySegwit) == true), channel.remoteShutdown == nil || channel.remoteShutdown == script,
                  channel.remote?.shutdownScript.isEmpty == true || channel.remote?.shutdownScript == script
            else { throw LightningError.invalidMessage }
            channel.remoteShutdown = script; channel.phase = .closing
            if channel.localShutdown != nil && channel.isFunder { try proposeClose(channel: channel, in: &next) }
        } else { try acceptClose(reader: &reader, channel: &channel, in: &next) }
        next.channels[index] = channel
        try persist(next)
        if let transaction = channel.closingTransaction { return [.broadcastClose(channelID: id, transaction: transaction)] }
        return []
    }
    private func proposeClose(channel: ChannelState, in next: inout State) throws {
        guard let fee = channel.closingFee, let maximum = channel.closingFeeLimit else { throw LightningError.invalidState }
        try channel.requireQuiescent()
        let transaction = try channel.closeTransaction(fee: fee)
        let signature = try ChannelKeys.sign(digest: channel.closeDigest(transaction), secret: channel.secrets.funding)
        var writer = LightningWire.Writer(); writer.append(channel.id); writer.u64(fee); writer.append(try ChannelKeys.compactSignature(signature))
        var range = LightningWire.Writer(); range.u64(0); range.u64(maximum)
        try writer.tlvs([.init(type: 1, value: range.data)])
        try Self.enqueue(.init(type: 39, payload: writer.data), channel: channel, in: &next)
    }
    private func acceptClose(reader: inout LightningWire.Reader, channel: inout ChannelState, in next: inout State) throws {
        try channel.requireQuiescent()
        let fee = try reader.u64(), signature = try ChannelKeys.derSignature(reader.take(64))
        let tlvs = try reader.tlvs(known: [1])
        guard let maximum = channel.closingFeeLimit, fee <= maximum, let remote = channel.remote else { throw LightningError.invalidAmount }
        if let range = tlvs.first(where: { $0.type == 1 }) {
            var values = LightningWire.Reader(range.value)
            let minimum = try values.u64(), upper = try values.u64(); try values.requireEnd()
            guard minimum <= upper, fee >= minimum, fee <= upper else { throw LightningError.invalidMessage }
        }
        var transaction = try channel.closeTransaction(fee: fee)
        let digest = try channel.closeDigest(transaction)
        guard ChannelKeys.verify(signature: signature, digest: digest, publicKey: remote.funding) else { throw LightningError.invalidSignature }
        if channel.closingTransaction != nil {
            guard channel.closingFee == fee else { throw LightningError.invalidState }
            return // Duplicate agreement cannot enqueue another signature.
        }
        let needsReply = !channel.isFunder || channel.closingFee != fee
        let ours = try ChannelKeys.sign(digest: digest, secret: channel.secrets.funding)
        let ordered = channel.local.funding.lexicographicallyPrecedes(remote.funding) ? [ours, signature] : [signature, ours]
        transaction.inputs[0].witness = [Data()] + ordered.map { $0 + Data([1]) } + [try ChannelScripts.funding(channel.local.funding, remote.funding).bytes]
        channel.closingFee = fee; channel.closingTransaction = transaction.serialized(includeWitness: true)
        Self.acknowledge([38, 39], channel: channel, in: &next)
        // The fundee's signature at our proposed fee completes negotiation.
        // An extra reply can reach a peer that has already removed the channel.
        if needsReply { try proposeClose(channel: channel, in: &next) }
    }
    public func pendingCloseBroadcasts() throws -> [Event] {
        try healthy()
        guard chainIsCurrent else { throw LightningError.invalidState }
        return state.channels.compactMap { channel in
            guard channel.phase == .closing, channel.observedFundingSpend == nil,
                  !channel.dataLossDetected, let transaction = channel.closingTransaction else { return nil }
            return .broadcastClose(channelID: channel.id, transaction: transaction)
        }
    }
}

extension ChannelState {
    func requireQuiescent() throws {
        guard !awaitingRevocation, updates.allSatisfy(\.irrevocable),
              try view(localOwner: true, number: localNumber).htlcs.isEmpty,
              try view(localOwner: false, number: remoteNumber).htlcs.isEmpty else { throw LightningError.invalidState }
    }
    func closeTransaction(fee: UInt64) throws -> Transaction {
        guard let localShutdown, let remoteShutdown, let txid = fundingTxid, let output = fundingOutput else { throw LightningError.invalidState }
        let view = try view(localOwner: true, number: localNumber)
        var ours = view.localMsat / 1000, theirs = view.remoteMsat / 1000
        // A close can be larger than a commitment (e.g. two Taproot outputs).
        // BOLT 2 bounds it by the negotiated range, not the commitment fee.
        guard fee <= (isFunder ? ours : theirs), fee <= (closingFeeLimit ?? 0) else { throw LightningError.invalidAmount }
        if isFunder { ours -= fee } else { theirs -= fee }
        var outputs: [Transaction.Output] = []
        if ours > 0 { outputs.append(.init(value: Int64(ours), scriptPubKey: localShutdown)) }
        if theirs > 0 { outputs.append(.init(value: Int64(theirs), scriptPubKey: remoteShutdown)) }
        guard !outputs.isEmpty, outputs.allSatisfy({ $0.value >= CoinSelection.dustThreshold(scriptPubKey: $0.scriptPubKey) }) else { throw LightningError.invalidAmount }
        outputs.sort { $0.value == $1.value ? $0.scriptPubKey.lexicographicallyPrecedes($1.scriptPubKey) : $0.value < $1.value }
        return Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: txid, vout: UInt32(output)), scriptSig: Data(), sequence: .max)],
                           outputs: outputs, locktime: 0)
    }
    func closeDigest(_ transaction: Transaction) throws -> Data {
        guard let remote else { throw LightningError.invalidState }
        return try SighashBIP143.sighash(tx: transaction, inputIndex: 0,
            scriptCode: ChannelScripts.funding(local.funding, remote.funding).bytes, value: Int64(capacity))
    }
}
