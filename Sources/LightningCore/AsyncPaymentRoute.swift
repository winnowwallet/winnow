import Foundation

/// A deliberately bounded route: our private holding peer, one known public
/// channel to the introduction node, then the signed invoice's blinded path.
/// The caller approves a fee/CLTV ceiling; receiving an invoice cannot raise it.
public struct AsyncPaymentRoute: Codable, Sendable, Equatable {
    public let holdingPeer: Data, introduction: Data
    public let shortChannelID: UInt64
    public let baseMsat: UInt32, proportionalMillionths: UInt32, expiryDelta: UInt16
    public init(holdingPeer: Data, introduction: Data, shortChannelID: UInt64,
                baseMsat: UInt32, proportionalMillionths: UInt32, expiryDelta: UInt16) throws {
        _ = try ChannelKeys.point(holdingPeer); _ = try ChannelKeys.point(introduction)
        guard holdingPeer != introduction, shortChannelID > 0, expiryDelta >= 18 else { throw LightningError.invalidMessage }
        self.holdingPeer = holdingPeer; self.introduction = introduction; self.shortChannelID = shortChannelID
        self.baseMsat = baseMsat; self.proportionalMillionths = proportionalMillionths; self.expiryDelta = expiryDelta
    }
    /// Resolve only the explicitly configured, authenticated public channel.
    /// Direction zero selects the lexicographically smaller endpoint (BOLT7).
    func resolve(_ path: BlindedPath) throws -> BlindedPath {
        guard case .channel(let direction, let scid) = path.introduction else { return path }
        guard scid == shortChannelID else { throw LightningError.invalidMessage }
        let ordered = [holdingPeer, introduction].sorted { $0.lexicographicallyPrecedes($1) }
        return try BlindedPath(introduction: .node(ordered[Int(direction)]), blinding: path.blinding, hops: path.hops)
    }
    public struct Quote: Sendable, Equatable {
        public let amountMsat: UInt64, feeMsat: UInt64
        public let firstExpiry: UInt32, finalExpiry: UInt32
        let finalPayloadExpiry: UInt32
        let introductionAmount: UInt64, introductionExpiry: UInt32
    }
    public func quote(invoice: StaticInvoice, amountMsat: UInt64, feeLimitMsat: UInt64, height: UInt32,
                      maximumDelta: UInt32) throws -> Quote {
        guard invoice.paymentPaths.count == 1, let info = invoice.payInfo.first,
              case .node(let node) = try resolve(invoice.paymentPaths[0]).introduction, node == introduction,
              (info.minimumMsat...info.maximumMsat).contains(amountMsat), info.expiryDelta >= 18
        else { throw LightningError.invalidMessage }
        let blindedFee = try Self.fee(amountMsat, base: info.baseMsat, proportional: info.proportionalMillionths)
        let introAmount = try Self.add(amountMsat, blindedFee)
        let firstAmount = try Self.add(introAmount, Self.fee(introAmount, base: baseMsat, proportional: proportionalMillionths))
        let delta = UInt32(info.expiryDelta) + UInt32(expiryDelta)
        guard firstAmount - amountMsat <= feeLimitMsat, delta <= maximumDelta,
              UInt64(height) + UInt64(delta) < 500_000_000 else { throw LightningError.invalidAmount }
        return Quote(amountMsat: firstAmount, feeMsat: firstAmount - amountMsat, firstExpiry: height + delta,
                     finalExpiry: height + 18, finalPayloadExpiry: height,
                     introductionAmount: introAmount, introductionExpiry: height + UInt32(info.expiryDelta))
    }
    func onion(invoice: StaticInvoice, request: InvoiceRequest, preimage: Data, quote: Quote) throws -> Data {
        guard preimage.count == 32, let originalPath = invoice.paymentPaths.first else { throw LightningError.invalidMessage }
        let path = try resolve(originalPath)
        var scid = LightningWire.Writer(); scid.u64(shortChannelID)
        let forward: [LightningWire.TLV] = [
            .init(type: 2, value: Bolt12Encoding.integer(quote.introductionAmount)),
            .init(type: 4, value: Bolt12Encoding.integer(UInt64(quote.introductionExpiry))), .init(type: 6, value: scid.data)]
        var hops = [try OnionPacket.Hop(publicKey: holdingPeer, payload: Bolt12Encoding.serialize(forward))]
        for index in path.hops.indices {
            var fields: [LightningWire.TLV] = [.init(type: 10, value: path.hops[index].encryptedData)]
            if index == 0 { fields.append(.init(type: 12, value: path.blinding)) }
            if index == path.hops.count - 1 {
                fields += [.init(type: 2, value: Bolt12Encoding.integer(request.amountMsat)),
                           .init(type: 4, value: Bolt12Encoding.integer(UInt64(quote.finalPayloadExpiry))),
                           .init(type: 18, value: Bolt12Encoding.integer(request.amountMsat)),
                           .init(type: 77777, value: request.bytes), .init(type: 5482373484, value: preimage)]
            }
            // Introduction nodes peel with their real key. Subsequent blinded
            // hops derive a private tweak using update_add_htlc's path key.
            let key = index == 0 ? introduction : path.hops[index].nodeID
            hops.append(try .init(publicKey: key, payload: Bolt12Encoding.serialize(fields.sorted { $0.type < $1.type })))
        }
        return try OnionPacket.create(hops: hops, associatedData: ChannelKeys.hash(preimage))
    }
    static func fee(_ amount: UInt64, base: UInt32, proportional: UInt32) throws -> UInt64 {
        // Rounded up, without overflowing amount * ppm at the upper limit.
        let whole = (amount / 1_000_000).multipliedReportingOverflow(by: UInt64(proportional))
        guard !whole.overflow else { throw LightningError.invalidAmount }
        let fraction = ((amount % 1_000_000) * UInt64(proportional) + 999_999) / 1_000_000
        return try add(add(whole.partialValue, fraction), UInt64(base))
    }
    static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw LightningError.invalidAmount }; return result.partialValue
    }
}
