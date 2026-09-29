import Foundation

/// Shared BOLT4 wire representation for message and payment paths. Public
/// keys and encrypted payload boundaries are checked before path selection.
public struct BlindedPath: Sendable, Equatable, Codable {
    public enum Introduction: Sendable, Equatable, Codable {
        case node(Data)
        case channel(direction: UInt8, shortChannelID: UInt64)
    }
    public struct Hop: Sendable, Equatable, Codable {
        public let nodeID: Data, encryptedData: Data
        public init(nodeID: Data, encryptedData: Data) { self.nodeID = nodeID; self.encryptedData = encryptedData }
    }
    public let introduction: Introduction
    public let blinding: Data
    public let hops: [Hop]
    public init(introduction: Introduction, blinding: Data, hops: [Hop]) throws {
        self.introduction = introduction; self.blinding = blinding; self.hops = hops
        _ = try encoded()
    }
    init(reader: inout LightningWire.Reader) throws {
        let first = try reader.u8()
        switch first {
        case 0, 1: introduction = .channel(direction: first, shortChannelID: try reader.u64())
        case 2, 3: introduction = .node(Data([first]) + (try reader.take(32)))
        default: throw LightningError.invalidMessage
        }
        blinding = try reader.take(33)
        let count = try reader.u8()
        guard count > 0 else { throw LightningError.invalidMessage }
        hops = try (0..<count).map { _ in
            let key = try reader.take(33), length = try reader.u16()
            return Hop(nodeID: key, encryptedData: try reader.take(Int(length)))
        }
        _ = try encoded()
    }
    public func encoded() throws -> Data {
        guard !hops.isEmpty, hops.count <= 255 else { throw LightningError.invalidMessage }
        var writer = LightningWire.Writer()
        switch introduction {
        case .node(let key): _ = try ChannelKeys.point(key); writer.append(key)
        case .channel(let direction, let id):
            guard direction < 2 else { throw LightningError.invalidMessage }; writer.u8(direction); writer.u64(id)
        }
        _ = try ChannelKeys.point(blinding); writer.append(blinding); writer.u8(UInt8(hops.count))
        for hop in hops {
            _ = try ChannelKeys.point(hop.nodeID)
            guard hop.encryptedData.count <= UInt16.max else { throw LightningError.invalidMessage }
            writer.append(hop.nodeID); writer.u16(UInt16(hop.encryptedData.count)); writer.append(hop.encryptedData)
        }
        return writer.data
    }
    public static func decodeList(_ bytes: Data) throws -> [BlindedPath] {
        var reader = LightningWire.Reader(bytes), paths: [BlindedPath] = []
        while reader.remaining > 0 {
            guard paths.count < 32 else { throw LightningError.invalidMessage }
            paths.append(try BlindedPath(reader: &reader))
        }
        guard !paths.isEmpty else { throw LightningError.invalidMessage }
        return paths
    }
}
