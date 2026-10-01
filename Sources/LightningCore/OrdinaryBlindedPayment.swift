import Foundation

enum OrdinaryBlindedPayment {
    static func path(provider: Data, recipient: Data, route: Bolt11Invoice.Route,
                     token: Data, maximumExpiry: UInt32, minimumMsat: UInt64) throws -> BlindedPath {
        guard token.count == 32, route.shortChannelID > 0 else { throw LightningError.invalidMessage }
        var constraints = LightningWire.Writer(); constraints.u32(maximumExpiry); constraints.append(Bolt12Encoding.integer(minimumMsat))
        var relay = LightningWire.Writer(); relay.u16(route.expiryDelta); relay.u32(route.proportionalMillionths)
        relay.append(Bolt12Encoding.integer(UInt64(route.baseMsat)))
        var scid = LightningWire.Writer(); scid.u64(route.shortChannelID)
        let forward = try Bolt12Encoding.serialize([.init(type: 2, value: scid.data),
            .init(type: 10, value: relay.data), .init(type: 12, value: constraints.data)])
        let final = try Bolt12Encoding.serialize([.init(type: 6, value: token), .init(type: 12, value: constraints.data)])
        return try OnionMessage.blind(nodes: [provider, recipient], payloads: [forward, final])
    }
    static func receive(peeled: OnionPacket.Peeled, blinding: Data, nodeSecret: Data,
                        request: LightningEngine.ReceiveRequest, htlc: ChannelTransactions.HTLC, height: UInt32) throws {
        guard peeled.next == nil else { throw LightningError.invalidMessage }
        var reader = LightningWire.Reader(peeled.payload)
        let values = Dictionary(uniqueKeysWithValues: try reader.tlvs(known: [2, 4, 10, 18]).map { ($0.type, $0.value) })
        guard let amount = values[2], let expiry = values[4], let total = values[18], let encrypted = values[10] else { throw LightningError.invalidMessage }
        let shared = try NoiseCrypto.ecdh(secret: nodeSecret, point: blinding)
        let controls = try NoiseCrypto.decrypt(encrypted, key: OnionPacket.derive("rho", secret: shared), nonce: 0)
        try validateControls(controls, request: request, htlc: htlc)
        guard try Bolt12Encoding.integer(amount) == request.amountMsat,
              try Bolt12Encoding.integer(total) == request.amountMsat, htlc.amountMsat >= request.amountMsat,
              try Bolt12Encoding.integer(expiry, maximumBytes: 4) <= htlc.expiry,
              UInt64(htlc.expiry) >= UInt64(height) + 18 else { throw LightningError.invalidAmount }
    }
    private static func validateControls(_ bytes: Data, request: LightningEngine.ReceiveRequest, htlc: ChannelTransactions.HTLC) throws {
        var reader = LightningWire.Reader(bytes)
        let values = Dictionary(uniqueKeysWithValues: try reader.tlvs(known: [6, 12]).map { ($0.type, $0.value) })
        guard values[6] == request.secret, let constraints = values[12] else { throw LightningError.authenticationFailed }
        var limits = LightningWire.Reader(constraints)
        let maximum = try limits.u32(), minimum = try Bolt12Encoding.integer(limits.take(limits.remaining))
        guard maximum == request.expiry, htlc.expiry <= maximum, htlc.amountMsat >= minimum else { throw LightningError.invalidAmount }
    }
}
