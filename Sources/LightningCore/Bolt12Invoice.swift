import Foundation

/// A one-payment BOLT12 invoice, distinct from the async static invoice. Its
/// signature binds the payer's exact request, payment hash and amount.
public struct Bolt12Invoice: Sendable {
    public let bytes: Data
    public let offer: LightningOffer
    public let chain: Data, paymentHash: Data, signingKey: Data
    public let amountMsat: UInt64, createdAt: UInt64
    public let relativeExpiry: UInt32
    public let paymentPaths: [BlindedPath], payInfo: [StaticInvoice.PayInfo]
    let requestFields: Data
    static let types: Set<UInt64> = [160, 162, 164, 166, 168, 170, 172, 174, 176, 240]
    public var string: String { (try? Bolt12Encoding.encode(bytes, prefix: "lni")) ?? "" }

    public init(string: String) throws { try self.init(bytes: Bolt12Encoding.decode(string, prefix: "lni")) }
    public init(bytes: Data) throws {
        let records = try Bolt12Encoding.records(bytes)
        guard records.allSatisfy(Self.validField) else { throw LightningError.invalidMessage }
        let fields = Dictionary(uniqueKeysWithValues: records.map { ($0.type, $0.value) })
        offer = try LightningOffer(bytes: Bolt12Encoding.serialize(records.filter { LightningOffer.isField($0.type) }))
        guard let paths = fields[160], let info = fields[162], let created = fields[164],
              let hash = fields[168], hash.count == 32, let amount = fields[170],
              let key = fields[176], let payer = fields[88], fields[0] != nil else { throw LightningError.invalidMessage }
        _ = try ChannelKeys.point(payer)
        self.bytes = bytes; chain = fields[80] ?? offer.chains[0]
        paymentHash = hash; signingKey = key
        amountMsat = try Bolt12Encoding.integer(amount)
        createdAt = try Bolt12Encoding.integer(created)
        relativeExpiry = try fields[166].map { UInt32(try Bolt12Encoding.integer($0, maximumBytes: 4)) } ?? 7200
        let parsedPaths = try BlindedPath.decodeList(paths), parsedInfo = try Self.readInfo(info)
        guard parsedInfo.count == parsedPaths.count else { throw LightningError.invalidAmount }
        let usable = zip(parsedPaths, parsedInfo).compactMap { path, info in info.map { (path, $0) } }
        paymentPaths = usable.map(\.0); payInfo = usable.map(\.1)
        requestFields = try Bolt12Encoding.serialize(records.filter(Self.requestField))
        guard chain.count == 32, offer.chains.contains(chain), amountMsat > 0,
              amountMsat <= 2_100_000_000_000_000_000, !paymentPaths.isEmpty else { throw LightningError.invalidAmount }
        try LightningFeatures(bytes: fields[174] ?? Data()).validateRequired(supported: [])
        try Self.validateIssuer(offer: offer, key: key)
        try Bolt12Encoding.verify(bytes, message: "invoice", publicKey: key)
    }

    public init(request: InvoiceRequest, paths: [BlindedPath], payInfo: [StaticInvoice.PayInfo],
                paymentHash: Data, createdAt: UInt64, relativeExpiry: UInt32 = 7200, signingSecret: Data) throws {
        var records = try Bolt12Encoding.records(request.bytes).filter(Self.requestField)
        records += try [.init(type: 160, value: paths.map { try $0.encoded() }.reduce(Data(), +)),
                        .init(type: 162, value: payInfo.map { try $0.encoded() }.reduce(Data(), +)),
                        .init(type: 164, value: Bolt12Encoding.integer(createdAt)),
                        .init(type: 166, value: Bolt12Encoding.integer(UInt64(relativeExpiry))),
                        .init(type: 168, value: paymentHash), .init(type: 170, value: Bolt12Encoding.integer(request.amountMsat)),
                        .init(type: 176, value: ChannelKeys.publicKey(secret: signingSecret))]
        try self.init(bytes: Bolt12Encoding.sign(records.sorted { $0.type < $1.type }, message: "invoice", secret: signingSecret))
    }

    public func validate(for request: InvoiceRequest, expectedIssuer: Data, chain: Data, now: UInt64) throws {
        let expected = try Bolt12Encoding.serialize(Bolt12Encoding.records(request.bytes).filter(Self.requestField))
        guard requestFields == expected, signingKey == expectedIssuer, self.chain == chain,
              amountMsat == request.amountMsat, now >= createdAt, now - createdAt <= UInt64(relativeExpiry)
        else { throw LightningError.invalidMessage }
        try request.offer.validatePayment(chain: chain, now: now, amountMsat: amountMsat)
    }

    static func requestField(_ field: LightningWire.TLV) -> Bool {
        field.type < 160 || (1_000_000_000..<3_000_000_000).contains(field.type)
    }
    private static func validField(_ field: LightningWire.TLV) -> Bool {
        let permitted = field.type < 240 || field.type == 240 || (1_000_000_000..<4_000_000_000).contains(field.type)
        let known = types.union(InvoiceRequest.types).union(LightningOffer.types)
        return permitted && (field.type % 2 == 1 || known.contains(field.type))
    }
    private static func readInfo(_ bytes: Data) throws -> [StaticInvoice.PayInfo?] {
        var reader = LightningWire.Reader(bytes), result: [StaticInvoice.PayInfo?] = []
        while reader.remaining > 0 {
            guard result.count < 32 else { throw LightningError.invalidMessage }
            let base = try reader.u32(), proportional = try reader.u32(), delta = try reader.u16()
            let minimum = try reader.u64(), maximum = try reader.u64(), length = try reader.u16()
            let features = try LightningFeatures(bytes: reader.take(Int(length)))
            guard minimum <= maximum else { throw LightningError.invalidAmount }
            // BOLT12 rejects a path with unknown compulsory features, while
            // preserving other signed paths that the payer can use.
            result.append(try? .init(baseMsat: base, proportionalMillionths: proportional, expiryDelta: delta,
                minimumMsat: minimum, maximumMsat: maximum, features: features))
        }
        return result
    }
    private static func validateIssuer(offer: LightningOffer, key: Data) throws {
        if let issuer = offer.signingKey { guard issuer == key else { throw LightningError.invalidSignature }; return }
        guard offer.paths.contains(where: { $0.hops.last?.nodeID == key }) else { throw LightningError.invalidSignature }
    }
}
