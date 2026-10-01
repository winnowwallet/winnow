import Foundation

/// Public, peer-signed forwarding policies followed by the invoice's blinded
/// path. The payment review commits to this route and its fee/CLTV ceilings.
public struct Bolt12PaymentRoute: Codable, Sendable, Equatable {
    public let hops: [Bolt11Invoice.Route]
    public let pathIndex: Int
    public let introduction: Data
    public init(hops: [Bolt11Invoice.Route], pathIndex: Int, introduction: Data) throws {
        _ = try Bolt11PaymentRoute(hops: hops); _ = try ChannelKeys.point(introduction)
        guard pathIndex >= 0, !hops.contains(where: { $0.peer == introduction }) else { throw LightningError.invalidMessage }
        self.hops = hops; self.pathIndex = pathIndex; self.introduction = introduction
    }
    public var peer: Data { hops.first?.peer ?? introduction }
    public struct Quote: Sendable, Equatable {
        public let amountMsat: UInt64, feeMsat: UInt64, firstExpiry: UInt32, delta: UInt32
        let payloads: [Data]
        let nodes: [Data]
        let blinding: Data?
    }
    public func quote(invoice: Bolt12Invoice, feeLimitMsat: UInt64, height: UInt32, maximumDelta: UInt32) throws -> Quote {
        guard invoice.paymentPaths.indices.contains(pathIndex), maximumDelta <= 2016 else { throw LightningError.invalidMessage }
        let path = invoice.paymentPaths[pathIndex], info = invoice.payInfo[pathIndex]
        if case .node(let node) = path.introduction { guard node == introduction else { throw LightningError.invalidMessage } }
        guard (info.minimumMsat...info.maximumMsat).contains(invoice.amountMsat),
              hops.count + path.hops.count <= 20 else { throw LightningError.invalidAmount }
        var amount = try AsyncPaymentRoute.add(invoice.amountMsat, AsyncPaymentRoute.fee(invoice.amountMsat, base: info.baseMsat, proportional: info.proportionalMillionths))
        // Test chains and independent peers can advertise a smaller final
        // delta. Add conservative padding rather than rejecting that invoice.
        var expiry = try Self.expiry(height, delta: max(18, UInt32(info.expiryDelta)))
        var payloads = try blindedPayloads(path: path, amount: invoice.amountMsat, finalExpiry: height)
        for hop in hops.reversed() {
            var scid = LightningWire.Writer(); scid.u64(hop.shortChannelID)
            payloads.insert(try Bolt12Encoding.serialize([.init(type: 2, value: Bolt12Encoding.integer(amount)),
                .init(type: 4, value: Bolt12Encoding.integer(UInt64(expiry))), .init(type: 6, value: scid.data)]), at: 0)
            amount = try AsyncPaymentRoute.add(amount, AsyncPaymentRoute.fee(amount, base: hop.baseMsat, proportional: hop.proportionalMillionths))
            expiry = try Self.expiry(expiry, delta: UInt32(hop.expiryDelta))
        }
        guard amount - invoice.amountMsat <= feeLimitMsat, expiry - height <= maximumDelta,
              payloads.reduce(0, { $0 + $1.count + 35 }) <= 1300 else { throw LightningInvoiceError.noRoute }
        let first = hops.isEmpty ? path.hops[0].nodeID : introduction
        let nodes = hops.map(\.peer) + [first] + path.hops.dropFirst().map(\.nodeID)
        return Quote(amountMsat: amount, feeMsat: amount - invoice.amountMsat, firstExpiry: expiry,
                     delta: expiry - height, payloads: payloads, nodes: nodes, blinding: hops.isEmpty ? path.blinding : nil)
    }
    func onion(invoice: Bolt12Invoice, quote: Quote) throws -> Data {
        try OnionPacket.create(hops: zip(quote.nodes, quote.payloads).map { .init(publicKey: $0.0, payload: $0.1) }, associatedData: invoice.paymentHash)
    }
    private func blindedPayloads(path: BlindedPath, amount: UInt64, finalExpiry: UInt32) throws -> [Data] {
        try path.hops.indices.map { index in
            var fields: [LightningWire.TLV] = [.init(type: 10, value: path.hops[index].encryptedData)]
            if index == 0 && !hops.isEmpty { fields.append(.init(type: 12, value: path.blinding)) }
            if index == path.hops.count - 1 {
                fields += [.init(type: 2, value: Bolt12Encoding.integer(amount)),
                           .init(type: 4, value: Bolt12Encoding.integer(UInt64(finalExpiry))),
                           .init(type: 18, value: Bolt12Encoding.integer(amount))]
            }
            return try Bolt12Encoding.serialize(fields.sorted { $0.type < $1.type })
        }
    }
    private static func expiry(_ height: UInt32, delta: UInt32) throws -> UInt32 {
        guard UInt64(height) + UInt64(delta) < 500_000_000 else { throw LightningError.invalidAmount }
        return height + delta
    }
}
