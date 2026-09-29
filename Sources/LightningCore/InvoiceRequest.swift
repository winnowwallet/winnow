import Foundation

public struct InvoiceRequest: Sendable {
    public let bytes: Data
    public let offer: LightningOffer
    public let chain: Data, payerKey: Data, metadata: Data
    public let amountMsat: UInt64
    public let quantity: UInt64?
    public let note: String?
    public let humanReadableName: BIP353Name?
    static let types: Set<UInt64> = [0, 80, 82, 84, 86, 88, 89, 90, 91, 240]
    public init(bytes: Data) throws {
        let records = try Bolt12Encoding.records(bytes)
        guard records.allSatisfy(Self.validType) else { throw LightningError.invalidMessage }
        offer = try LightningOffer(bytes: Bolt12Encoding.serialize(records.filter { LightningOffer.isField($0.type) }))
        let fields = Dictionary(uniqueKeysWithValues: records.map { ($0.type, $0.value) })
        guard let key = fields[88], let metadata = fields[0] else { throw LightningError.invalidMessage }
        payerKey = key; self.metadata = metadata; self.bytes = bytes
        chain = fields[80] ?? offer.chains[0]
        quantity = try fields[86].map { try Bolt12Encoding.integer($0) }
        note = try LightningOffer.text(fields[89])
        humanReadableName = try fields[91].map(BIP353Name.init(invoiceRequestValue:))
        _ = try fields[90].map(BlindedPath.decodeList)
        let explicit = try fields[82].map { try Bolt12Encoding.integer($0) }
        amountMsat = try Self.amount(offer: offer, explicit: explicit, quantity: quantity)
        guard chain.count == 32, offer.chains.contains(chain) else { throw LightningError.invalidMessage }
        try LightningFeatures(bytes: fields[84] ?? Data()).validateRequired(supported: [])
        try Bolt12Encoding.verify(bytes, message: "invoice_request", publicKey: key)
    }
    public init(offer: LightningOffer, chain: Data, amountMsat: UInt64, now: UInt64, metadata: Data, payerSecret: Data,
                humanReadableName: BIP353Name? = nil) throws {
        try offer.validatePayment(chain: chain, now: now, amountMsat: amountMsat)
        var fields = try Bolt12Encoding.records(offer.bytes)
        fields += try [.init(type: 0, value: metadata), .init(type: 80, value: chain),
                       .init(type: 82, value: Bolt12Encoding.integer(amountMsat)),
                       .init(type: 88, value: ChannelKeys.publicKey(secret: payerSecret))]
        if let humanReadableName { fields.append(.init(type: 91, value: humanReadableName.invoiceRequestValue)) }
        try self.init(bytes: Bolt12Encoding.sign(fields.sorted { $0.type < $1.type }, message: "invoice_request", secret: payerSecret))
    }
    private static func amount(offer: LightningOffer, explicit: UInt64?, quantity: UInt64?) throws -> UInt64 {
        let units = quantity ?? 1
        if let maximum = offer.maximumQuantity {
            guard quantity != nil, units > 0, maximum == 0 || units <= maximum else { throw LightningError.invalidAmount }
        } else if quantity != nil { throw LightningError.invalidAmount }
        let minimum = (offer.amount ?? 0).multipliedReportingOverflow(by: units)
        guard !minimum.overflow else { throw LightningError.invalidAmount }
        if offer.currency != nil && explicit == nil { throw LightningError.invalidAmount }
        let amount = explicit ?? minimum.partialValue
        guard amount > 0, amount <= 2_100_000_000_000_000_000,
              offer.currency != nil || amount >= minimum.partialValue else { throw LightningError.invalidAmount }
        return amount
    }
    private static func validType(_ field: LightningWire.TLV) -> Bool {
        let allowed = field.type < 160 || (240...1000).contains(field.type) || (1_000_000_000..<3_000_000_000).contains(field.type)
        return allowed && (field.type % 2 == 1 || types.contains(field.type) || LightningOffer.types.contains(field.type))
    }
}
