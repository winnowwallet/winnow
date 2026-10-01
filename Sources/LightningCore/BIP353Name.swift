import Foundation

/// ASCII BIP353 names. Unicode input is deliberately refused rather than
/// silently mapping a visually confusable name to a payment destination.
public struct BIP353Name: Codable, Sendable, Equatable {
    public let user: String, domain: String
    private enum CodingKeys: String, CodingKey { case user, domain }
    public var display: String { "₿" + user + "@" + domain }
    public var queryName: String { user + ".user._bitcoin-payment." + domain + "." }
    public init(_ value: String) throws {
        let raw = value.hasPrefix("₿") ? String(value.dropFirst()) : value
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw LightningError.invalidMessage }
        let user = String(parts[0]).lowercased(), domain = String(parts[1]).lowercased()
        guard user.utf8.count <= 255, user.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ Self.label(String($0)) }), domain.utf8.count <= 253,
              domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ Self.label(String($0)) }),
              domain.contains("."), user.utf8.count + domain.utf8.count + 25 <= 255 else { throw LightningError.invalidMessage }
        self.user = user; self.domain = domain
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(values.decode(String.self, forKey: .user) + "@" + values.decode(String.self, forKey: .domain))
    }
    var invoiceRequestValue: Data {
        Data([UInt8(user.utf8.count)]) + Data(user.utf8) + Data([UInt8(domain.utf8.count)]) + Data(domain.utf8)
    }
    init(invoiceRequestValue: Data) throws {
        var reader = LightningWire.Reader(invoiceRequestValue)
        let nameLength = try reader.u8(), name = try reader.take(Int(nameLength))
        let domainLength = try reader.u8(), domain = try reader.take(Int(domainLength)); try reader.requireEnd()
        guard let user = String(data: name, encoding: .utf8), let host = String(data: domain, encoding: .utf8) else { throw LightningError.invalidMessage }
        try self.init(user + "@" + host)
    }
    private static func label(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 63, value.first != "-", value.last != "-" else { return false }
        return value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
}
