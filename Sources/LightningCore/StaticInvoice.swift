import Foundation

/// The pinned upstream async-payment static invoice. Its signature commits to
/// the exact reusable offer and blinded payment/notification paths. Unlike an
/// ordinary invoice it must not contain a payment hash or a payment amount.
public struct StaticInvoice: Sendable {
    public struct PayInfo: Sendable, Equatable {
        public let baseMsat: UInt32, proportionalMillionths: UInt32
        public let expiryDelta: UInt16
        public let minimumMsat: UInt64, maximumMsat: UInt64
        public let features: LightningFeatures
        public init(baseMsat: UInt32, proportionalMillionths: UInt32, expiryDelta: UInt16,
                    minimumMsat: UInt64, maximumMsat: UInt64, features: LightningFeatures) throws {
            guard minimumMsat <= maximumMsat else { throw LightningError.invalidAmount }
            try features.validateRequired(supported: [])
            self.baseMsat = baseMsat; self.proportionalMillionths = proportionalMillionths; self.expiryDelta = expiryDelta
            self.minimumMsat = minimumMsat; self.maximumMsat = maximumMsat; self.features = features
        }
        init(reader: inout LightningWire.Reader) throws {
            let base = try reader.u32(), proportional = try reader.u32(), delta = try reader.u16()
            let minimum = try reader.u64(), maximum = try reader.u64(), length = try reader.u16()
            try self.init(baseMsat: base, proportionalMillionths: proportional, expiryDelta: delta,
                minimumMsat: minimum, maximumMsat: maximum, features: LightningFeatures(bytes: reader.take(Int(length))))
        }
        func encoded() throws -> Data {
            guard features.bytes.count <= UInt16.max else { throw LightningError.invalidMessage }
            var writer = LightningWire.Writer(); writer.u32(baseMsat); writer.u32(proportionalMillionths); writer.u16(expiryDelta)
            writer.u64(minimumMsat); writer.u64(maximumMsat); writer.u16(UInt16(features.bytes.count)); writer.append(features.bytes)
            return writer.data
        }
    }
    public let bytes: Data
    public let offer: LightningOffer
    public let paymentPaths: [BlindedPath], notificationPaths: [BlindedPath]
    public let payInfo: [PayInfo]
    public let createdAt: UInt64, relativeExpiry: UInt32
    public let signingKey: Data
    static let types: Set<UInt64> = [160, 162, 164, 166, 174, 176, 236, 240]

    public init(bytes: Data) throws {
        let records = try Bolt12Encoding.records(bytes)
        guard records.allSatisfy(Self.validType) else { throw LightningError.invalidMessage }
        offer = try LightningOffer(bytes: Bolt12Encoding.serialize(records.filter { LightningOffer.isField($0.type) }))
        guard offer.chains.count == 1, !offer.paths.isEmpty else { throw LightningError.invalidMessage }
        let fields = Dictionary(uniqueKeysWithValues: records.map { ($0.type, $0.value) })
        guard let paths = fields[160], let pay = fields[162], let created = fields[164], let key = fields[176], let notifications = fields[236]
        else { throw LightningError.invalidMessage }
        paymentPaths = try BlindedPath.decodeList(paths); notificationPaths = try BlindedPath.decodeList(notifications)
        createdAt = try Bolt12Encoding.integer(created)
        relativeExpiry = try fields[166].map { UInt32(try Bolt12Encoding.integer($0, maximumBytes: 4)) } ?? 7200
        signingKey = key; self.bytes = bytes
        payInfo = try Self.readPayInfo(pay)
        guard payInfo.count == paymentPaths.count else { throw LightningError.invalidMessage }
        try LightningFeatures(bytes: fields[174] ?? Data()).validateRequired(supported: [])
        try validateKey()
        try Bolt12Encoding.verify(bytes, message: "static_invoice", publicKey: key)
    }
    public init(offer: LightningOffer, paymentPaths: [BlindedPath], payInfo: [PayInfo], notificationPaths: [BlindedPath],
                createdAt: UInt64, relativeExpiry: UInt32, signingSecret: Data) throws {
        var records = try Bolt12Encoding.records(offer.bytes)
        records += try [
            .init(type: 160, value: paymentPaths.map { try $0.encoded() }.reduce(Data(), +)),
            .init(type: 162, value: payInfo.map { try $0.encoded() }.reduce(Data(), +)),
            .init(type: 164, value: Bolt12Encoding.integer(createdAt)),
            .init(type: 166, value: Bolt12Encoding.integer(UInt64(relativeExpiry))),
            .init(type: 176, value: ChannelKeys.publicKey(secret: signingSecret)),
            .init(type: 236, value: notificationPaths.map { try $0.encoded() }.reduce(Data(), +))]
        try self.init(bytes: Bolt12Encoding.sign(records.sorted { $0.type < $1.type }, message: "static_invoice", secret: signingSecret))
    }
    public func validatePayment(for expected: LightningOffer, chain: Data, now: UInt64, amountMsat: UInt64) throws {
        guard offer.bytes == expected.bytes, now >= createdAt, now - createdAt <= UInt64(relativeExpiry) else { throw LightningError.invalidMessage }
        try offer.validatePayment(chain: chain, now: now, amountMsat: amountMsat)
    }
    private func validateKey() throws {
        if let key = offer.signingKey {
            guard key == signingKey else { throw LightningError.invalidSignature }
        } else {
            guard offer.paths.contains(where: { $0.hops.last?.nodeID == signingKey }) else { throw LightningError.invalidSignature }
        }
    }
    private static func readPayInfo(_ bytes: Data) throws -> [PayInfo] {
        var reader = LightningWire.Reader(bytes), result: [PayInfo] = []
        while reader.remaining > 0 {
            guard result.count < 32 else { throw LightningError.invalidMessage }
            result.append(try PayInfo(reader: &reader))
        }
        return result
    }
    private static func validType(_ field: LightningWire.TLV) -> Bool {
        let allowed = LightningOffer.isField(field.type) || (160...1000).contains(field.type) || (3_000_000_000..<4_000_000_000).contains(field.type)
        return allowed && (field.type % 2 == 1 || types.contains(field.type) || LightningOffer.types.contains(field.type))
    }
}
