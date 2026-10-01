import Foundation

/// The limits a party requires of its peer. In particular, `delay` applies to
/// the OTHER party's commitment transaction, not the sender's own transaction.
public struct ChannelTerms: Sendable, Codable, Equatable {
    public let dustSat: UInt64
    public let maximumHTLCMsat: UInt64
    public let reserveSat: UInt64
    public let minimumHTLCMsat: UInt64
    public let delay: UInt16
    public let maximumHTLCCount: UInt16
    public let funding: Data, revocation: Data, payment: Data, delayed: Data, htlc: Data, firstPoint: Data
    public let shutdownScript: Data
    private let negotiatedFormat: ChannelFormat?
    private let negotiatedOptions: ChannelOptions?
    public var format: ChannelFormat { negotiatedFormat ?? .staticRemoteKey }
    public var options: ChannelOptions { negotiatedOptions ?? [] }

    public init(dustSat: UInt64 = 546, maximumHTLCMsat: UInt64, reserveSat: UInt64,
                minimumHTLCMsat: UInt64 = 1, delay: UInt16 = 144, maximumHTLCCount: UInt16 = 30,
                funding: Data, revocation: Data, payment: Data, delayed: Data, htlc: Data, firstPoint: Data,
                shutdownScript: Data = Data(), format: ChannelFormat = .staticRemoteKey, options: ChannelOptions = []) {
        self.dustSat = dustSat; self.maximumHTLCMsat = maximumHTLCMsat; self.reserveSat = reserveSat
        self.minimumHTLCMsat = minimumHTLCMsat; self.delay = delay; self.maximumHTLCCount = maximumHTLCCount
        self.funding = funding; self.revocation = revocation; self.payment = payment
        self.delayed = delayed; self.htlc = htlc; self.firstPoint = firstPoint; self.shutdownScript = shutdownScript
        negotiatedFormat = format == .staticRemoteKey ? nil : format
        negotiatedOptions = options.isEmpty ? nil : options
    }
    public func validate(capacity: UInt64) throws {
        // A zero reserve parses; ChannelState accepts it only from a provider
        // whose just-in-time channel Winnow bought.
        guard capacity >= 20_000, capacity < 1 << 24, dustSat > 0, reserveSat == 0 || dustSat <= reserveSat,
              reserveSat <= capacity / 5 else { throw LightningError.invalidAmount }
        guard maximumHTLCMsat > 0, minimumHTLCMsat <= maximumHTLCMsat,
              minimumHTLCMsat <= capacity * 1000, (1...483).contains(maximumHTLCCount),
              (1...2016).contains(delay) else { throw LightningError.invalidMessage }
        for point in [funding, revocation, payment, delayed, htlc, firstPoint] { _ = try ChannelKeys.point(point) }
        // Validate the encoding here; the engine also checks the negotiated
        // anysegwit feature before accepting an upfront shutdown script.
        guard shutdownScript.isEmpty || Self.validShutdown(shutdownScript, anySegwit: true) else { throw LightningError.invalidMessage }
    }
    static func validShutdown(_ script: Data, anySegwit: Bool = false) -> Bool {
        let bytes = Array(script)
        guard (4...42).contains(bytes.count), Int(bytes[1]) == bytes.count - 2 else { return false }
        if bytes[0] == 0 { return [22, 34].contains(bytes.count) }
        return anySegwit && (0x51...0x60).contains(bytes[0])
    }
}

public enum ChannelNegotiation {
    public struct Open: Sendable {
        public let chain: Data, temporaryID: Data
        public let capacity: UInt64, pushMsat: UInt64
        public let feePerKW: UInt32
        public let terms: ChannelTerms
        public init(chain: Data, temporaryID: Data, capacity: UInt64, pushMsat: UInt64,
                    feePerKW: UInt32, terms: ChannelTerms) {
            self.chain = chain; self.temporaryID = temporaryID; self.capacity = capacity
            self.pushMsat = pushMsat; self.feePerKW = feePerKW; self.terms = terms
        }
        public func message() throws -> LightningWire.Message {
            try terms.validate(capacity: capacity)
            guard chain.count == 32, temporaryID.count == 32, pushMsat <= capacity * 1000,
                  (253...100_000).contains(feePerKW) else { throw LightningError.invalidMessage }
            var writer = LightningWire.Writer()
            writer.append(chain); writer.append(temporaryID); writer.u64(capacity); writer.u64(pushMsat)
            limits(terms, to: &writer); writer.u32(feePerKW); points(terms, to: &writer)
            writer.u8(0) // Private channels only.
            try tail(terms, to: &writer)
            return try .init(type: 32, payload: writer.data)
        }
        public init(message: LightningWire.Message) throws {
            guard message.type == 32 else { throw LightningError.invalidMessage }
            var reader = LightningWire.Reader(message.payload)
            chain = try reader.take(32); temporaryID = try reader.take(32)
            capacity = try reader.u64(); pushMsat = try reader.u64()
            let limits = try readLimits(&reader)
            feePerKW = try reader.u32()
            let points = try readPoints(&reader)
            guard try reader.u8() == 0 else { throw LightningError.invalidMessage }
            terms = try readTail(&reader, limits: limits, points: points)
            _ = try self.message()
        }
    }
    public struct Accept: Sendable {
        public let temporaryID: Data
        public let minimumDepth: UInt32
        public let terms: ChannelTerms
        public init(temporaryID: Data, minimumDepth: UInt32, terms: ChannelTerms) {
            self.temporaryID = temporaryID; self.minimumDepth = minimumDepth; self.terms = terms
        }
        public func message() throws -> LightningWire.Message {
            // Zero is a zero-conf acceptance (BOLT 2), sent only for a bought channel.
            guard temporaryID.count == 32, (0...144).contains(minimumDepth) else { throw LightningError.invalidMessage }
            var writer = LightningWire.Writer(); writer.append(temporaryID)
            limits(terms, to: &writer); writer.u32(minimumDepth); points(terms, to: &writer)
            try tail(terms, to: &writer)
            return try .init(type: 33, payload: writer.data)
        }
        public init(message: LightningWire.Message) throws {
            guard message.type == 33 else { throw LightningError.invalidMessage }
            var reader = LightningWire.Reader(message.payload)
            temporaryID = try reader.take(32)
            let limits = try readLimits(&reader)
            minimumDepth = try reader.u32()
            let points = try readPoints(&reader)
            terms = try readTail(&reader, limits: limits, points: points)
            _ = try self.message()
        }
    }

    public static func channelID(txid: Data, output: UInt16) throws -> Data {
        guard txid.count == 32 else { throw LightningError.invalidHash }
        var bytes = Array(txid); bytes[30] ^= UInt8(output >> 8); bytes[31] ^= UInt8(truncatingIfNeeded: output)
        return Data(bytes)
    }
    private static func limits(_ terms: ChannelTerms, to writer: inout LightningWire.Writer) {
        writer.u64(terms.dustSat); writer.u64(terms.maximumHTLCMsat)
        writer.u64(terms.reserveSat); writer.u64(terms.minimumHTLCMsat)
    }
    private static func points(_ terms: ChannelTerms, to writer: inout LightningWire.Writer) {
        writer.u16(terms.delay); writer.u16(terms.maximumHTLCCount)
        for point in [terms.funding, terms.revocation, terms.payment, terms.delayed, terms.htlc, terms.firstPoint] { writer.append(point) }
    }
    private static func tail(_ terms: ChannelTerms, to writer: inout LightningWire.Writer) throws {
        let channelType = try LightningFeatures(bits: terms.format.features.bits.union(terms.options.bits))
        try writer.tlvs([.init(type: 0, value: terms.shutdownScript), .init(type: 1, value: channelType.bytes)])
    }
    private static func readLimits(_ reader: inout LightningWire.Reader) throws -> [UInt64] {
        try (0..<4).map { _ in try reader.u64() }
    }
    private struct Points { let delay: UInt16, count: UInt16; let keys: [Data] }
    private static func readPoints(_ reader: inout LightningWire.Reader) throws -> Points {
        let delay = try reader.u16(), count = try reader.u16()
        return try Points(delay: delay, count: count, keys: (0..<6).map { _ in try reader.take(33) })
    }
    private static func readTail(_ reader: inout LightningWire.Reader, limits: [UInt64], points: Points) throws -> ChannelTerms {
        let tlvs = try reader.tlvs(known: [0, 1])
        guard let type = tlvs.first(where: { $0.type == 1 }) else { throw LightningError.invalidMessage }
        let channelType = try ChannelFormat.negotiated(LightningFeatures(bytes: type.value))
        return ChannelTerms(dustSat: limits[0], maximumHTLCMsat: limits[1], reserveSat: limits[2], minimumHTLCMsat: limits[3],
            delay: points.delay, maximumHTLCCount: points.count, funding: points.keys[0], revocation: points.keys[1],
            payment: points.keys[2], delayed: points.keys[3], htlc: points.keys[4], firstPoint: points.keys[5],
            shutdownScript: tlvs.first(where: { $0.type == 0 })?.value ?? Data(), format: channelType.format,
            options: channelType.options)
    }
}
