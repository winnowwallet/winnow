import Foundation

/// The invoice's private hints and peer-signed public policies describe
/// forwarding. They never replace Winnow's validation of our own channel.
public struct Bolt11PaymentRoute: Codable, Sendable, Equatable {
    public let hops: [Bolt11Invoice.Route]
    public init(hops: [Bolt11Invoice.Route]) throws {
        guard hops.count < 20, Set(hops.map(\.peer)).count == hops.count else { throw LightningError.invalidMessage }
        for hop in hops { _ = try ChannelKeys.point(hop.peer); guard hop.shortChannelID > 0 else { throw LightningError.invalidMessage } }
        self.hops = hops
    }
    public struct Quote: Sendable, Equatable {
        public let amountMsat: UInt64, feeMsat: UInt64, firstExpiry: UInt32
        public let delta: UInt32
        let payloads: [Data]
    }
    public func quote(invoice: Bolt11Invoice.Decoded, amountMsat: UInt64, feeLimitMsat: UInt64,
                      height: UInt32, maximumDelta: UInt32) throws -> Quote {
        guard let secret = invoice.paymentSecret, !hops.contains(where: { $0.peer == invoice.payee }) else { throw LightningInvoiceError.unsupported }
        let finalDelta = max(18, invoice.minimumFinalDelta)
        guard UInt64(height) + UInt64(finalDelta) < 500_000_000 else { throw LightningError.invalidAmount }
        var amount = amountMsat, expiry = height + finalDelta
        var final = LightningWire.Writer()
        var fields = [LightningWire.TLV(type: 2, value: PaymentPayload.truncated(amount)),
                      .init(type: 4, value: PaymentPayload.truncated(UInt64(expiry))),
                      .init(type: 8, value: secret + PaymentPayload.truncated(amount))]
        if let metadata = invoice.metadata { fields.append(.init(type: 16, value: metadata)) }
        try final.tlvs(fields)
        var payloads = [final.data]
        for hop in hops.reversed() {
            var scid = LightningWire.Writer(); scid.u64(hop.shortChannelID)
            var payload = LightningWire.Writer()
            try payload.tlvs([.init(type: 2, value: PaymentPayload.truncated(amount)),
                              .init(type: 4, value: PaymentPayload.truncated(UInt64(expiry))), .init(type: 6, value: scid.data)])
            payloads.insert(payload.data, at: 0)
            amount = try AsyncPaymentRoute.add(amount, AsyncPaymentRoute.fee(amount, base: hop.baseMsat, proportional: hop.proportionalMillionths))
            guard UInt64(expiry) + UInt64(hop.expiryDelta) < 500_000_000 else { throw LightningError.invalidAmount }
            expiry += UInt32(hop.expiryDelta)
        }
        guard amount - amountMsat <= feeLimitMsat, expiry - height <= maximumDelta else { throw LightningInvoiceError.noRoute }
        // Include the BigSize length and HMAC of each hop before authorization.
        guard payloads.reduce(0, { $0 + $1.count + 35 }) <= 1300 else { throw LightningInvoiceError.unsupported }
        return Quote(amountMsat: amount, feeMsat: amount - amountMsat, firstExpiry: expiry, delta: expiry - height, payloads: payloads)
    }
    func onion(invoice: Bolt11Invoice.Decoded, quote: Quote) throws -> Data {
        let nodes = hops.map(\.peer) + [invoice.payee]
        return try OnionPacket.create(hops: zip(nodes, quote.payloads).map { .init(publicKey: $0.0, payload: $0.1) }, associatedData: invoice.paymentHash)
    }
}
