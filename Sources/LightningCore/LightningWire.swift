import Foundation

/// BOLT encodings are big endian. Bitcoin's CompactSize and little-endian
/// transaction encodings must never be used for peer messages.
public enum LightningWire {
    public struct Message: Sendable, Equatable, Codable {
        public let type: UInt16
        public let payload: Data
        public init(type: UInt16, payload: Data) throws {
            guard payload.count <= 65_533 else { throw LightningError.invalidMessage }
            self.type = type; self.payload = payload
        }
        public init(bytes: Data) throws {
            guard bytes.count <= 65_535 else { throw LightningError.invalidMessage }
            var reader = Reader(bytes)
            type = try reader.u16(); payload = try reader.take(reader.remaining)
        }
        public var bytes: Data { var writer = Writer(); writer.u16(type); writer.append(payload); return writer.data }
    }

    public struct TLV: Sendable, Equatable {
        public let type: UInt64
        public let value: Data
        public init(type: UInt64, value: Data) { self.type = type; self.value = value }
    }

    public struct Reader {
        private let bytes: [UInt8]
        private var offset = 0
        public init(_ bytes: Data) { self.bytes = Array(bytes) }
        public var remaining: Int { bytes.count - offset }
        public mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= remaining else { throw LightningError.invalidMessage }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }
        public mutating func u8() throws -> UInt8 { try integer(1) }
        public mutating func u16() throws -> UInt16 { try integer(2) }
        public mutating func u32() throws -> UInt32 { try integer(4) }
        public mutating func u64() throws -> UInt64 { try integer(8) }
        private mutating func integer<T: FixedWidthInteger>(_ count: Int) throws -> T {
            try take(count).reduce(T(0)) { ($0 << 8) | T($1) }
        }
        public mutating func bigSize() throws -> UInt64 {
            let prefix = try u8()
            switch prefix {
            case 0...252: return UInt64(prefix)
            case 253: let value = try u16(); guard value >= 253 else { throw LightningError.invalidMessage }; return UInt64(value)
            case 254: let value = try u32(); guard value > UInt16.max else { throw LightningError.invalidMessage }; return UInt64(value)
            default: let value = try u64(); guard value > UInt32.max else { throw LightningError.invalidMessage }; return value
            }
        }
        public mutating func tlvs(known: Set<UInt64>) throws -> [TLV] {
            var result: [TLV] = [], previous: UInt64?
            while remaining > 0 {
                let type = try bigSize(), length = try bigSize()
                guard previous.map({ type > $0 }) ?? true, length <= UInt64(remaining),
                      type % 2 == 1 || known.contains(type) else { throw LightningError.invalidMessage }
                result.append(TLV(type: type, value: try take(Int(length))))
                previous = type
            }
            return result
        }
        public func requireEnd() throws {
            guard remaining == 0 else { throw LightningError.invalidMessage }
        }
    }

    public struct Writer {
        public private(set) var data = Data()
        public init() {}
        public mutating func append(_ value: Data) { data.append(value) }
        public mutating func u8(_ value: UInt8) { data.append(value) }
        public mutating func u16(_ value: UInt16) { integer(value) }
        public mutating func u32(_ value: UInt32) { integer(value) }
        public mutating func u64(_ value: UInt64) { integer(value) }
        private mutating func integer<T: FixedWidthInteger>(_ value: T) {
            for shift in stride(from: T.bitWidth - 8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        public mutating func bigSize(_ value: UInt64) {
            switch value {
            case 0...252: u8(UInt8(value))
            case 253...UInt64(UInt16.max): u8(253); u16(UInt16(value))
            case 65_536...UInt64(UInt32.max): u8(254); u32(UInt32(value))
            default: u8(255); u64(value)
            }
        }
        public mutating func tlvs(_ values: [TLV]) throws {
            var previous: UInt64?
            for value in values {
                guard previous.map({ value.type > $0 }) ?? true else { throw LightningError.invalidMessage }
                bigSize(value.type); bigSize(UInt64(value.value.count)); append(value.value); previous = value.type
            }
        }
    }
}
