import Foundation

/// Receiver-owned encrypted data for the final hop. The MAC binds the offer
/// identity and every acceptance constraint, independently of route encryption.
/// Forwarding nodes use the standard BOLT4 payment_relay/constraints encoding.
enum BlindedPayment {
    struct Received {
        let offerID: Data, request: InvoiceRequest, preimage: Data
    }
    static func path(provider: Data, recipient: Data, shortChannelID: UInt64, offerID: Data,
                     maximumExpiry: UInt32, minimumMsat: UInt64, baseMsat: UInt32,
                     proportionalMillionths: UInt32, delta: UInt16, authenticationKey: Data) throws -> BlindedPath {
        guard offerID.count == 32, shortChannelID > 0, minimumMsat > 0, delta >= 18 else { throw LightningError.invalidMessage }
        var constraints = LightningWire.Writer(); constraints.u32(maximumExpiry); constraints.append(Bolt12Encoding.integer(minimumMsat))
        var relay = LightningWire.Writer(); relay.u16(delta); relay.u32(proportionalMillionths); relay.append(Bolt12Encoding.integer(UInt64(baseMsat)))
        var scid = LightningWire.Writer(); scid.u64(shortChannelID)
        let forward = try Bolt12Encoding.serialize([.init(type: 2, value: scid.data), .init(type: 10, value: relay.data),
                                                  .init(type: 12, value: constraints.data)])
        let bound = offerID + constraints.data
        let final = try Bolt12Encoding.serialize([.init(type: 12, value: constraints.data),
            .init(type: 65537, value: offerID + OnionPacket.authenticate(bound, key: authenticationKey))])
        return try OnionMessage.blind(nodes: [provider, recipient], payloads: [forward, final])
    }
    static func peel(onion: Data, blinding: Data, nodeSecret: Data, hash: Data) throws -> OnionPacket.Peeled {
        let shared = try NoiseCrypto.ecdh(secret: nodeSecret, point: blinding)
        let secret = try ChannelKeys.privateKey(nodeSecret).multiply(Array(OnionPacket.derive("blinded_node_id", secret: shared))).dataRepresentation
        return try OnionPacket.peel(onion, secret: secret, associatedData: hash)
    }
    static func receive(_ peeled: OnionPacket.Peeled, blinding: Data, nodeSecret: Data, authenticationKey: Data,
                        htlc: ChannelTransactions.HTLC, height: UInt32) throws -> Received {
        guard peeled.next == nil else { throw LightningError.invalidMessage }
        var reader = LightningWire.Reader(peeled.payload)
        let fields = Dictionary(uniqueKeysWithValues: try reader.tlvs(known: [2, 4, 10, 18, 77777, 5482373484]).map { ($0.type, $0.value) })
        guard let amount = fields[2], let expiry = fields[4], let encrypted = fields[10], let total = fields[18],
              let rawRequest = fields[77777], let preimage = fields[5482373484], preimage.count == 32,
              ChannelKeys.hash(preimage) == htlc.paymentHash else { throw LightningError.invalidMessage }
        let shared = try NoiseCrypto.ecdh(secret: nodeSecret, point: blinding)
        let controls = try NoiseCrypto.decrypt(encrypted, key: OnionPacket.derive("rho", secret: shared), nonce: 0)
        let offerID = try authenticate(controls, key: authenticationKey, amountMsat: htlc.amountMsat, expiry: htlc.expiry)
        let request = try InvoiceRequest(bytes: rawRequest)
        guard try Bolt12Encoding.integer(amount) == request.amountMsat,
              try Bolt12Encoding.integer(total) == request.amountMsat, htlc.amountMsat >= request.amountMsat,
              try Bolt12Encoding.integer(expiry, maximumBytes: 4) <= htlc.expiry,
              UInt64(htlc.expiry) >= UInt64(height) + 18 else { throw LightningError.invalidAmount }
        return Received(offerID: offerID, request: request, preimage: preimage)
    }
    private static func authenticate(_ bytes: Data, key: Data, amountMsat: UInt64, expiry: UInt32) throws -> Data {
        var reader = LightningWire.Reader(bytes)
        let fields = Dictionary(uniqueKeysWithValues: try reader.tlvs(known: [12, 65537]).map { ($0.type, $0.value) })
        guard let constraints = fields[12], let context = fields[65537], context.count == 64 else { throw LightningError.invalidMessage }
        let id = Data(context.prefix(32)), mac = Data(context.suffix(32))
        guard OnionPacket.authenticate(id + constraints, key: key) == mac else { throw LightningError.invalidSignature }
        var limits = LightningWire.Reader(constraints)
        let maximum = try limits.u32(), minimum = try Bolt12Encoding.integer(limits.take(limits.remaining))
        guard expiry <= maximum, amountMsat >= minimum else { throw LightningError.invalidAmount }
        return id
    }
}
