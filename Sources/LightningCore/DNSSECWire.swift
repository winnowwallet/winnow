import Foundation

/// Bounds checked DNS wire decoding. Names in signed RDATA are expanded and
/// lowercased before signature verification; TXT character strings stay exact.
enum DNSSECWire {
    struct Record: Sendable, Equatable {
        let name: String, type: UInt16, dnsClass: UInt16, ttl: UInt32, data: Data
    }
    struct Reader {
        let bytes: [UInt8]
        var offset = 0
        init(_ data: Data) { bytes = Array(data) }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= bytes.count - offset else { throw DNSSECError.malformed }
            defer { offset += count }; return Data(bytes[offset..<(offset + count)])
        }
        mutating func u8() throws -> UInt8 { try take(1).first! }
        mutating func u16() throws -> UInt16 { try take(2).reduce(0) { ($0 << 8) | UInt16($1) } }
        mutating func u32() throws -> UInt32 { try take(4).reduce(0) { ($0 << 8) | UInt32($1) } }
        private enum NamePart { case label(String), pointer(Int), end }
        mutating func name() throws -> String {
            var cursor = offset, labels: [String] = [], visited = Set<Int>(), resume: Int?
            while true {
                guard labels.count <= 127 else { throw DNSSECError.malformed }
                switch try namePart(cursor: &cursor, visited: &visited) {
                case .pointer(let next):
                    if resume == nil { resume = cursor }; cursor = next
                case .label(let label): labels.append(label)
                case .end:
                    offset = resume ?? cursor
                    let name = labels.joined(separator: ".") + "."
                    guard name.utf8.count <= 255 else { throw DNSSECError.malformed }; return name
                }
            }
        }
        private func namePart(cursor: inout Int, visited: inout Set<Int>) throws -> NamePart {
            guard visited.insert(cursor).inserted, cursor < bytes.count else { throw DNSSECError.malformed }
            let count = Int(bytes[cursor]); cursor += 1
            if count & 0xc0 == 0xc0 {
                guard cursor < bytes.count else { throw DNSSECError.malformed }
                let next = ((count & 0x3f) << 8) | Int(bytes[cursor]); cursor += 1
                guard next < cursor - 2 else { throw DNSSECError.malformed }; return .pointer(next)
            }
            guard count <= 63, count <= bytes.count - cursor else { throw DNSSECError.malformed }
            if count == 0 { return .end }
            let raw = bytes[cursor..<(cursor + count)]
            guard raw.allSatisfy({ (33...126).contains($0) && $0 != 46 && $0 != 92 }) else { throw DNSSECError.malformed }
            cursor += count; return .label(String(decoding: raw, as: UTF8.self).lowercased())
        }
        mutating func record() throws -> Record {
            let owner = try name(), type = try u16(), dnsClass = try u16(), ttl = try u32(), length = try u16()
            let start = offset, end = offset + Int(length)
            guard end <= bytes.count else { throw DNSSECError.malformed }
            let data = try canonicalData(type: type, length: Int(length))
            guard offset == end, offset >= start else { throw DNSSECError.malformed }
            return Record(name: owner, type: type, dnsClass: dnsClass, ttl: ttl, data: data)
        }
        private mutating func canonicalData(type: UInt16, length: Int) throws -> Data {
            switch type {
            case 5, 39: return try DNSSECWire.nameData(name())
            case 47:
                let end = offset + length, next = try name()
                return try DNSSECWire.nameData(next) + take(end - offset)
            case 46:
                let end = offset + length, header = try take(18), signer = try name()
                return try header + DNSSECWire.nameData(signer) + take(end - offset)
            default: return try take(length)
            }
        }
    }
    static func nameData(_ name: String) throws -> Data {
        guard name.hasSuffix("."), name.utf8.count <= 255 else { throw DNSSECError.malformed }
        var data = Data()
        for label in name.dropLast().split(separator: ".", omittingEmptySubsequences: false) where !label.isEmpty {
            guard label.utf8.count <= 63 else { throw DNSSECError.malformed }
            data.append(UInt8(label.utf8.count)); data.append(Data(label.lowercased().utf8))
        }
        data.append(0); return data
    }
    static func proof(_ data: Data) throws -> [Record] {
        guard data.count <= 2_097_152 else { throw DNSSECError.malformed }
        var reader = Reader(data), records: [Record] = []
        while reader.offset < reader.bytes.count {
            guard records.count < 4096 else { throw DNSSECError.malformed }; records.append(try reader.record())
        }
        return records
    }
    static func query(name: String, type: UInt16, id: UInt16) throws -> Data {
        var writer = LightningWire.Writer(); writer.u16(id); writer.u16(0x0110) // RD + CD: local validation, never remote AD.
        writer.u16(1); writer.u16(0); writer.u16(0); writer.u16(1)
        writer.append(try nameData(name)); writer.u16(type); writer.u16(1)
        writer.u8(0); writer.u16(41); writer.u16(4096); writer.u32(0x8000); writer.u16(0) // EDNS DNSSEC OK.
        return writer.data
    }
    static func response(_ data: Data, name: String, type: UInt16, id: UInt16) throws -> [Record] {
        guard data.count <= 65_535 else { throw DNSSECError.malformed }
        var reader = Reader(data)
        guard try reader.u16() == id else { throw DNSSECError.malformed }
        let flags = try reader.u16(), questions = try reader.u16()
        let counts = try [reader.u16(), reader.u16(), reader.u16()]
        guard flags & 0x8000 != 0, flags & 0x7a0f == 0, questions == 1, counts.reduce(UInt32(0), { $0 + UInt32($1) }) <= 4096 else { throw DNSSECError.unavailable }
        guard try reader.name() == name.lowercased(), try reader.u16() == type, try reader.u16() == 1 else { throw DNSSECError.malformed }
        let total = counts.reduce(0) { $0 + Int($1) }
        let records = try (0..<total).map { _ in try reader.record() }.filter { $0.type != 41 }
        guard reader.offset == reader.bytes.count else { throw DNSSECError.malformed }; return records
    }
    static func subdomain(_ name: String, of zone: String) -> Bool { zone == "." || name == zone || name.hasSuffix("." + zone) }
}

public enum DNSSECError: Error, Sendable, LocalizedError {
    case malformed, unauthenticated, expired, unsupported, ambiguous, unavailable
    public var errorDescription: String? {
        switch self {
        case .malformed: return "The payment name returned malformed DNS records."
        case .unauthenticated: return "The payment name could not be authenticated to the DNS root."
        case .expired: return "The payment name's authenticated DNS records have expired."
        case .unsupported: return "The payment name does not contain a supported Lightning offer."
        case .ambiguous: return "The payment name contains more than one payment destination."
        case .unavailable: return "The payment name's DNS proof could not be retrieved."
        }
    }
}
