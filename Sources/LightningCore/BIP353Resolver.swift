import Foundation

public struct BIP353PaymentInstructions: Sendable {
    public let name: BIP353Name, uri: String, offer: LightningOffer
    public let validUntil: UInt64
}

/// DNS-over-HTTPS only transports records. The server's AD bit is ignored:
/// signatures and delegation keys are validated on the device to the DNS root.
public struct BIP353Resolver: Sendable {
    public let endpoint: URL
    public init(endpoint: URL = URL(string: "https://cloudflare-dns.com/dns-query")!) { self.endpoint = endpoint }
    public func resolve(_ name: BIP353Name, chain: Data, now: UInt64) async throws -> BIP353PaymentInstructions {
        guard endpoint.scheme == "https" else { throw DNSSECError.unavailable }
        let endpoint = endpoint
        let validator = DNSSECValidator(now: now) { name, type in
            let id = UInt16.random(in: 0...UInt16.max)
            var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 20
            request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
            request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
            request.httpBody = try DNSSECWire.query(name: name, type: type, id: id)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 65_535 else { throw DNSSECError.unavailable }
            return try DNSSECWire.response(data, name: name, type: type, id: id)
        }
        let (records, ttl) = try await validator.txt(name: name.queryName)
        return try Self.instructions(records, name: name, chain: chain, now: now, ttl: ttl)
    }
    /// RFC9102 AuthenticationChain proof records, for offline validation and
    /// independent published vectors. No remote validation claim is trusted.
    public static func resolveProof(_ proof: Data, name: BIP353Name, chain: Data, now: UInt64) async throws -> BIP353PaymentInstructions {
        let validator = DNSSECValidator(records: try DNSSECWire.proof(proof), now: now)
        let (records, ttl) = try await validator.txt(name: name.queryName)
        return try instructions(records, name: name, chain: chain, now: now, ttl: ttl)
    }
    static func instructions(_ records: [Data], name: BIP353Name, chain: Data, now: UInt64, ttl: UInt64) throws -> BIP353PaymentInstructions {
        let uris = records.compactMap { String(data: $0, encoding: .utf8) }.filter { $0.lowercased().hasPrefix("bitcoin:") }
        guard uris.count == 1 else { throw uris.isEmpty ? DNSSECError.unsupported : DNSSECError.ambiguous }
        guard let components = URLComponents(string: uris[0]), components.scheme?.lowercased() == "bitcoin",
              components.host == nil, components.fragment == nil, components.user == nil else { throw DNSSECError.malformed }
        let items = components.queryItems ?? []
        guard !items.contains(where: { $0.name.hasPrefix("req-") }), items.filter({ $0.name == "lno" }).count == 1,
              let value = items.first(where: { $0.name == "lno" })?.value else { throw DNSSECError.unsupported }
        let offer = try LightningOffer(string: value)
        guard offer.chains.contains(chain), offer.currency == nil, offer.maximumQuantity == nil,
              offer.expiry.map({ $0 > now }) ?? true else { throw DNSSECError.unsupported }
        let lifetime = min(ttl, offer.expiry.map({ $0 - now }) ?? .max)
        return BIP353PaymentInstructions(name: name, uri: uris[0], offer: offer, validUntil: try AsyncPaymentRoute.add(now, lifetime))
    }
}
