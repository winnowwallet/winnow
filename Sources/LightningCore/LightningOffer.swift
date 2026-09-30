import Foundation

public struct LightningOffer: Sendable, Equatable {
    public let bytes: Data
    public let chains: [Data]
    public let amount: UInt64?
    public let currency: String?
    public let description: String?
    public let issuer: String?
    public let expiry: UInt64?
    public let maximumQuantity: UInt64?
    public let signingKey: Data?
    public let paths: [BlindedPath]
    public var string: String { (try? Bolt12Encoding.encode(bytes, prefix: "lno")) ?? "" }
    static let types: Set<UInt64> = [2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22]
    static func isField(_ type: UInt64) -> Bool { (1..<80).contains(type) || (1_000_000_000..<2_000_000_000).contains(type) }
    public init(string: String) throws { try self.init(bytes: Bolt12Encoding.decode(string, prefix: "lno")) }
    public init(bytes: Data) throws {
        let records = try Bolt12Encoding.records(bytes)
        guard records.allSatisfy({ Self.isField($0.type) && ($0.type % 2 == 1 || Self.types.contains($0.type)) }) else { throw LightningError.invalidMessage }
        let fields = Dictionary(uniqueKeysWithValues: records.map { ($0.type, $0.value) })
        self.bytes = bytes
        chains = try Self.chains(fields[2])
        amount = try fields[8].map { try Bolt12Encoding.integer($0) }
        currency = try Self.text(fields[6])
        description = try Self.text(fields[10]); issuer = try Self.text(fields[18])
        expiry = try fields[14].map { try Bolt12Encoding.integer($0) }
        maximumQuantity = try fields[20].map { try Bolt12Encoding.integer($0) }
        signingKey = fields[22]
        if let signingKey { _ = try ChannelKeys.point(signingKey) }
        paths = try fields[16].map(BlindedPath.decodeList) ?? []
        try LightningFeatures(bytes: fields[12] ?? Data()).validateRequired(supported: [])
        try validate()
    }
    private func validate() throws {
        guard signingKey != nil || !paths.isEmpty else { throw LightningError.invalidMessage }
        if let amount {
            guard amount > 0, description != nil else { throw LightningError.invalidAmount }
            if currency == nil && amount > 2_100_000_000_000_000_000 { throw LightningError.invalidAmount }
        }
        if let currency {
            guard currency.utf8.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }), amount != nil else { throw LightningError.invalidMessage }
        }
    }
    /// Network payment policy is separate from syntax: other-chain, currency
    /// and quantity offers may be decoded but must not reach a payment review.
    public func validatePayment(chain: Data, now: UInt64, amountMsat: UInt64) throws {
        guard chains.contains(chain), expiry.map({ now < $0 }) ?? true, currency == nil, maximumQuantity == nil,
              amountMsat > 0, amount.map({ amountMsat >= $0 }) ?? true else { throw LightningError.invalidAmount }
    }
    static func text(_ bytes: Data?) throws -> String? {
        guard let bytes else { return nil }
        guard let value = String(data: bytes, encoding: .utf8) else { throw LightningError.invalidMessage }
        return value
    }
    private static func chains(_ bytes: Data?) throws -> [Data] {
        guard let bytes else {
            return [Data([0x6f, 0xe2, 0x8c, 0x0a, 0xb6, 0xf1, 0xb3, 0x72, 0xc1, 0xa6, 0xa2, 0x46, 0xae, 0x63, 0xf7, 0x4f,
                          0x93, 0x1e, 0x83, 0x65, 0xe1, 0x5a, 0x08, 0x9c, 0x68, 0xd6, 0x19, 0, 0, 0, 0, 0])]
        }
        guard !bytes.isEmpty, bytes.count % 32 == 0 else { throw LightningError.invalidMessage }
        let raw = Array(bytes)
        return stride(from: 0, to: raw.count, by: 32).map { Data(raw[$0..<($0 + 32)]) }
    }
}
