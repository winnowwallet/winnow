import Foundation

extension LightningEngine {
    /// Low-level channel operation. A payment orchestrator must persist its
    /// stable payment ID and fee authorization in the SAME state transaction.
    /// Kept internal until that payment API is complete.
    func offerHTLC(channelID: Data, peer: Data, amountMsat: UInt64, paymentHash: Data, expiry: UInt32, onion: Data) throws -> UInt64 {
        try operational(peer)
        let index = try activeChannelIndex(channelID, peer: peer)
        var channel = state.channels[index]
        var next = state
        let id = try enqueueHTLC(channel: &channel, in: &next, amountMsat: amountMsat, paymentHash: paymentHash, expiry: expiry, onion: onion)
        next.channels[index] = channel
        try persist(next)
        return id
    }
    func enqueueHTLC(channel: inout ChannelState, in next: inout State, amountMsat: UInt64,
                     paymentHash: Data, expiry: UInt32, onion: Data, hold: Bool = false, blinding: Data? = nil) throws -> UInt64 {
        guard channel.phase == .ready else { throw LightningError.invalidState }
        guard paymentHash.count == 32, onion.count == 1366, amountMsat > 0, amountMsat <= channel.capacity * 1000,
              channel.nextLocalHTLC < UInt64.max, channel.updates.count < 4096 else { throw LightningError.invalidMessage }
        let id = channel.nextLocalHTLC
        let htlc = ChannelTransactions.HTLC(id: id, offered: true, amountMsat: amountMsat, paymentHash: paymentHash, expiry: expiry)
        channel.updates.append(ChannelUpdate(change: .add(htlc, onion: onion), fromLocal: true))
        channel.nextLocalHTLC += 1
        var writer = LightningWire.Writer(); writer.append(channel.id); writer.u64(id); writer.u64(amountMsat)
        writer.append(paymentHash); writer.u32(expiry); writer.append(onion)
        var fields: [LightningWire.TLV] = []
        if let blinding { _ = try ChannelKeys.point(blinding); fields.append(.init(type: 0, value: blinding)) }
        if hold { fields.append(.init(type: 75537, value: Data())) }
        if !fields.isEmpty { try writer.tlvs(fields) }
        try Self.enqueue(.init(type: 128, payload: writer.data), channel: channel, in: &next)
        try signPending(&channel, in: &next)
        return id
    }
    func fulfillHTLC(channelID: Data, peer: Data, id: UInt64, preimage: Data) throws {
        try operational(peer)
        let index = try activeChannelIndex(channelID, peer: peer)
        var channel = state.channels[index]
        let htlc = try channel.activeHTLC(id: id, offered: false)
        guard preimage.count == 32, ChannelKeys.hash(preimage) == htlc.paymentHash,
              !channel.hasRemoval(id: id, offered: false) else { throw LightningError.invalidHash }
        channel.updates.append(ChannelUpdate(change: .fulfill(id: id, offered: false, preimage: preimage), fromLocal: true))
        var writer = LightningWire.Writer(); writer.append(channelID); writer.u64(id); writer.append(preimage)
        var next = state
        try Self.enqueue(.init(type: 130, payload: writer.data), channel: channel, in: &next)
        try signPending(&channel, in: &next)
        next.channels[index] = channel
        try persist(next)
    }
    func receiveUpdate(peer: Data, message: LightningWire.Message) throws -> [Event] {
        var reader = LightningWire.Reader(message.payload)
        let id = try reader.take(32), index = try activeChannelIndex(id, peer: peer)
        var channel = state.channels[index]
        guard channel.updates.count < 4096 else { throw LightningError.invalidState }
        let change = try readChange(message.type, reader: &reader, channel: &channel)
        channel.updates.append(ChannelUpdate(change: change, fromLocal: false))
        // Validate the prospective local state before acknowledging or exposing
        // an untrusted update. The accepted update remains uncommitted until its
        // complete signature set is independently checked.
        var candidate = channel
        try candidate.includeUpdates(localOwner: true, number: channel.localNumber + 1)
        var next = state; next.channels[index] = channel
        try persist(next)
        return []
    }
    private func readChange(_ type: UInt16, reader: inout LightningWire.Reader, channel: inout ChannelState) throws -> ChannelUpdate.Change {
        switch type {
        case 128: return try readAdd(&reader, channel: &channel)
        case 130: return try readFulfill(&reader, channel: &channel)
        case 131: return try readFailure(&reader, channel: channel)
        case 134: return try readFee(&reader, channel: channel)
        case 135: return try readMalformed(&reader, channel: channel)
        default: throw LightningError.invalidMessage
        }
    }
    private func readFulfill(_ reader: inout LightningWire.Reader, channel: inout ChannelState) throws -> ChannelUpdate.Change {
        let id = try reader.u64(), preimage = try reader.take(32); _ = try reader.tlvs(known: [])
        let htlc = try channel.activeHTLC(id: id, offered: true)
        guard ChannelKeys.hash(preimage) == htlc.paymentHash, !channel.hasRemoval(id: id, offered: true) else { throw LightningError.invalidHash }
        if !channel.learnedPreimages.contains(preimage) { channel.learnedPreimages.append(preimage) }
        return .fulfill(id: id, offered: true, preimage: preimage)
    }
    private func readFailure(_ reader: inout LightningWire.Reader, channel: ChannelState) throws -> ChannelUpdate.Change {
        let id = try reader.u64(), length = try reader.u16(), reason = try reader.take(Int(length)); _ = try reader.tlvs(known: [])
        _ = try channel.activeHTLC(id: id, offered: true)
        guard !channel.hasRemoval(id: id, offered: true) else { throw LightningError.invalidState }
        return .fail(id: id, offered: true, reason: reason)
    }
    private func readFee(_ reader: inout LightningWire.Reader, channel: ChannelState) throws -> ChannelUpdate.Change {
        let fee = try reader.u32(); try reader.requireEnd()
        guard !channel.isFunder, (253...100_000).contains(fee) else { throw LightningError.invalidMessage }
        return .fee(fee)
    }
    private func readAdd(_ reader: inout LightningWire.Reader, channel: inout ChannelState) throws -> ChannelUpdate.Change {
        guard channel.remoteShutdown == nil else { throw LightningError.invalidState }
        let id = try reader.u64(), amount = try reader.u64(), hash = try reader.take(32), expiry = try reader.u32()
        let onion = try reader.take(1366)
        let fields = try reader.tlvs(known: [0])
        if let point = fields.first(where: { $0.type == 0 })?.value {
            _ = try ChannelKeys.point(point); channel.incomingBlinding[id] = point
        }
        // This wallet receives payments; it is not an async holding provider.
        guard !fields.contains(where: { $0.type == 75537 }) else { throw LightningError.invalidMessage }
        guard id == channel.nextRemoteHTLC, id < UInt64.max, amount > 0, amount <= channel.capacity * 1000,
              expiry < 500_000_000 else { throw LightningError.invalidMessage }
        channel.nextRemoteHTLC += 1
        return .add(.init(id: id, offered: false, amountMsat: amount, paymentHash: hash, expiry: expiry), onion: onion)
    }
    private func readMalformed(_ reader: inout LightningWire.Reader, channel: ChannelState) throws -> ChannelUpdate.Change {
        let id = try reader.u64(), hash = try reader.take(32), code = try reader.u16(); try reader.requireEnd()
        _ = try channel.activeHTLC(id: id, offered: true)
        guard code & 0x8000 != 0, !channel.hasRemoval(id: id, offered: true),
              let offered = channel.updates.first(where: {
                  if case .add(let htlc, _) = $0.change { return htlc.offered && htlc.id == id }; return false
              }), case .add(_, let onion) = offered.change, ChannelKeys.hash(onion) == hash
        else { throw LightningError.invalidMessage }
        var reason = LightningWire.Writer(); reason.u16(code); reason.append(hash)
        return .fail(id: id, offered: true, reason: reason.data)
    }
}

extension ChannelState {
    func hasRemoval(id: UInt64, offered: Bool) -> Bool {
        updates.contains {
            switch $0.change {
            case .fulfill(let other, let direction, _), .fail(let other, let direction, _): return id == other && offered == direction
            default: return false
            }
        }
    }
}
