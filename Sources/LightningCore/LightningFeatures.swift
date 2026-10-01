import Foundation

public struct LightningFeatures: Sendable, Equatable, Codable {
    /// BOLT 9: independent of onion messages (38/39).
    public static let shutdownAnySegwit = 26
    public let bits: Set<Int>
    public init(bits: Set<Int>) throws {
        guard bits.allSatisfy({ (0..<65_528).contains($0) }) else { throw LightningError.invalidMessage }
        self.bits = bits
    }
    public init(bytes: Data) {
        var bits = Set<Int>()
        for (index, byte) in bytes.reversed().enumerated() {
            for bit in 0..<8 where byte & (1 << bit) != 0 { bits.insert(index * 8 + bit) }
        }
        self.bits = bits
    }
    public var bytes: Data {
        guard let high = bits.max() else { return Data() }
        var bytes = [UInt8](repeating: 0, count: high / 8 + 1)
        for bit in bits { bytes[bytes.count - 1 - bit / 8] |= 1 << (bit % 8) }
        return Data(bytes)
    }
    public func supports(_ evenBit: Int) -> Bool { bits.contains(evenBit) || bits.contains(evenBit + 1) }
    public func validateRequired(supported: Set<Int>) throws {
        guard bits.filter({ $0 % 2 == 0 }).allSatisfy({ supported.contains($0) }),
              bits.allSatisfy({ !bits.contains($0 ^ 1) }) else { throw LightningError.invalidMessage }
    }
    /// Baseline data-loss protection, TLV payloads/payment secrets, static remote
    /// keys, anchor outputs, anysegwit shutdowns and explicit channel types. No MPP
    /// or async extensions.
    public static var channelOpening: LightningFeatures { LightningFeatures(bytes: Data([0x20, 0, 0x08, 0x80, 0xa2, 2])) }

    /// Client support for blinded receives and onion messages. The client does
    /// not advertise the holding-provider feature.
    public static var asyncClient: LightningFeatures {
        var bytes = channelOpening.bytes
        bytes[bytes.endIndex - 4] |= 2; bytes[bytes.endIndex - 5] |= 128
        return LightningFeatures(bytes: bytes)
    }

    public func initialization() throws -> LightningWire.Message {
        var writer = LightningWire.Writer()
        writer.u16(0); writer.u16(UInt16(bytes.count)); writer.append(bytes)
        return try .init(type: 16, payload: writer.data)
    }
    public static func readInitialization(_ message: LightningWire.Message) throws -> LightningFeatures {
        guard message.type == 16 else { throw LightningError.invalidMessage }
        var reader = LightningWire.Reader(message.payload)
        let globalLength = try reader.u16(), global = try reader.take(Int(globalLength))
        let length = try reader.u16(), local = try reader.take(Int(length))
        _ = try reader.tlvs(known: [1, 3])
        return try LightningFeatures(bits: LightningFeatures(bytes: global).bits.union(LightningFeatures(bytes: local).bits))
    }
}
