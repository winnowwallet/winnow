import Foundation

/// A bounded cache of untrusted routing hints. All four announcement signatures
/// and each policy signature are checked. This client never relays gossip or
/// treats a routing channel as on-chain-verified wallet/channel state.
struct LightningRoutingGraph: Sendable {
    struct Channel: Sendable { let nodes: [Data]; var policies: [Int: Policy] = [:] }
    struct Policy: Sendable {
        let hop: Bolt11Invoice.Route, timestamp: UInt32, minimum: UInt64, maximum: UInt64, disabled: Bool
    }
    let chain: Data
    var channels: [UInt64: Channel] = [:]
    var blockedNodes = Set<Data>()
    var nodeTimestamps: [Data: UInt32] = [:]
    var synchronizedAt: UInt64 = 0
    static let limit = 150_000
    mutating func receive(_ message: LightningWire.Message, now: UInt64) throws {
        switch message.type {
        case 256: try announcement(message)
        case 258: try update(message, now: now)
        case 257: try node(message, now: now)
        default: break
        }
    }
    private mutating func announcement(_ message: LightningWire.Message) throws {
        var r = LightningWire.Reader(message.payload)
        let signatures = try (0..<4).map { _ in try r.take(64) }
        let featureLength = try r.u16(), features = LightningFeatures(bytes: try r.take(Int(featureLength)))
        guard features.bits.filter({ $0 % 2 == 0 }).isEmpty else { return }
        guard try r.take(32) == chain else { return }
        let scid = try r.u64(), keys = try (0..<4).map { _ in try r.take(33) }
        guard scid > 0, keys[0].lexicographicallyPrecedes(keys[1]), channels[scid] != nil || channels.count < Self.limit else { return }
        let digest = ChannelKeys.hash(ChannelKeys.hash(Data(message.payload.dropFirst(256))))
        for index in keys.indices {
            guard ChannelKeys.verify(signature: try ChannelKeys.derSignature(signatures[index]), digest: digest, publicKey: keys[index]) else { return }
        }
        if let old = channels[scid] { guard old.nodes == Array(keys.prefix(2)) else { return } }
        else { channels[scid] = Channel(nodes: Array(keys.prefix(2))) }
    }
    private mutating func update(_ message: LightningWire.Message, now: UInt64) throws {
        var r = LightningWire.Reader(message.payload)
        let signature = try r.take(64); guard try r.take(32) == chain else { return }
        let scid = try r.u64(), timestamp = try r.u32(), flags = try r.u8(), direction = try r.u8()
        let delta = try r.u16(), minimum = try r.u64(), base = try r.u32(), ppm = try r.u32()
        let maximum = flags & 1 == 1 ? try r.u64() : UInt64.max
        guard var channel = channels[scid], direction & ~3 == 0, delta > 0, minimum <= maximum,
              UInt64(timestamp) <= now + 300, UInt64(timestamp) + 14 * 86_400 >= now,
              (channel.policies[Int(direction & 1)]?.timestamp ?? 0) < timestamp else { return }
        let sender = channel.nodes[Int(direction & 1)], digest = ChannelKeys.hash(ChannelKeys.hash(Data(message.payload.dropFirst(64))))
        guard ChannelKeys.verify(signature: try ChannelKeys.derSignature(signature), digest: digest, publicKey: sender) else { return }
        channel.policies[Int(direction & 1)] = Policy(hop: .init(peer: sender, shortChannelID: scid, baseMsat: base,
            proportionalMillionths: ppm, expiryDelta: delta), timestamp: timestamp, minimum: minimum, maximum: maximum, disabled: direction & 2 != 0)
        channels[scid] = channel
    }
    private mutating func node(_ message: LightningWire.Message, now: UInt64) throws {
        var r = LightningWire.Reader(message.payload)
        let signature = try r.take(64), length = try r.u16(), features = LightningFeatures(bytes: try r.take(Int(length)))
        let timestamp = try r.u32(), key = try r.take(33)
        guard UInt64(timestamp) <= now + 300,
              nodeTimestamps[key].map({ timestamp > $0 }) ?? (nodeTimestamps.count < Self.limit * 2) else { return }
        let digest = ChannelKeys.hash(ChannelKeys.hash(Data(message.payload.dropFirst(64))))
        guard ChannelKeys.verify(signature: try ChannelKeys.derSignature(signature), digest: digest, publicKey: key) else { return }
        nodeTimestamps[key] = timestamp
        let known: Set<Int> = [0, 6, 8, 10, 12, 14, 16, 24, 26, 38, 44, 48]
        if features.bits.contains(where: { $0 % 2 == 0 && !known.contains($0) }) {
            if blockedNodes.count < Self.limit * 2 { blockedNodes.insert(key) }
        } else { blockedNodes.remove(key) }
    }
}
