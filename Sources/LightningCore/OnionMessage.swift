import CryptoKit
import Foundation
import P256K

/// BOLT4 route blinding and onion-message envelopes. The final encrypted
/// context is receiver-owned and authenticated with a separate wallet key;
/// possession of a shared offer never authorizes fabricating a reply context.
public enum OnionMessage {
    public enum Destination: Sendable { case node(Data), channel(UInt64) }
    public enum Peeled: Sendable {
        case forward(Destination, LightningWire.Message)
        case receive(content: LightningWire.TLV, context: Data, reply: BlindedPath?)
        /// Only a signed ordinary invoice request can arrive without a private
        /// reply context. Async replies continue to require the receiver MAC.
        case invoiceRequest(content: LightningWire.TLV, reply: BlindedPath?)
    }
    public static func path(nodes: [Data], context: Data, authenticationKey: Data) throws -> BlindedPath {
        guard !nodes.isEmpty, nodes.count <= 20, context.count <= 4096, authenticationKey.count == 32 else { throw LightningError.invalidMessage }
        let authenticated = context + OnionPacket.authenticate(context, key: authenticationKey)
        let payloads = try nodes.indices.map { index in
            try Bolt12Encoding.serialize(index == nodes.count - 1 ? [.init(type: 65537, value: authenticated)] : [.init(type: 4, value: nodes[index + 1])])
        }
        return try blind(nodes: nodes, payloads: payloads)
    }
    public static func directPath(node: Data) throws -> BlindedPath { try blind(nodes: [node], payloads: [Data()]) }
    static func blind(nodes: [Data], payloads: [Data]) throws -> BlindedPath {
        guard !nodes.isEmpty, nodes.count == payloads.count, nodes.count <= 20 else { throw LightningError.invalidMessage }
        var secret = try P256K.Signing.PrivateKey().dataRepresentation
        let initial = try ChannelKeys.publicKey(secret: secret)
        let hops = try zip(nodes, payloads).map { node, payload in
            let point = try ChannelKeys.publicKey(secret: secret), shared = try NoiseCrypto.ecdh(secret: secret, point: node)
            let factor = OnionPacket.derive("blinded_node_id", secret: shared)
            let blinded = try ChannelKeys.point(node).multiply(Array(factor)).dataRepresentation
            let encrypted = try NoiseCrypto.encrypt(payload, key: OnionPacket.derive("rho", secret: shared), nonce: 0)
            secret = try ChannelKeys.privateKey(secret).multiply(Array(ChannelKeys.hash(point + shared))).dataRepresentation
            return BlindedPath.Hop(nodeID: blinded, encryptedData: encrypted)
        }
        return try BlindedPath(introduction: .node(nodes[0]), blinding: initial, hops: hops)
    }
    public static func create(to path: BlindedPath, via nodes: [Data] = [], content: LightningWire.TLV, reply: BlindedPath? = nil) throws -> LightningWire.Message {
        _ = try path.encoded()
        guard content.type >= 64, nodes.count + path.hops.count <= 20 else { throw LightningError.invalidMessage }
        let route = try prefixed(path, nodes: nodes)
        var hops = try route.hops.map { hop in
            OnionPacket.Hop(publicKey: hop.nodeID, payload: try Bolt12Encoding.serialize([.init(type: 4, value: hop.encryptedData)]))
        }
        var final: [LightningWire.TLV] = [.init(type: 4, value: route.hops.last!.encryptedData), content]
        if let reply { final.insert(try .init(type: 2, value: reply.encoded()), at: 0) }
        hops[hops.count - 1] = try .init(publicKey: route.hops.last!.nodeID, payload: Bolt12Encoding.serialize(final))
        let size = hops.reduce(0) { total, hop in
            var length = LightningWire.Writer(); length.bigSize(UInt64(hop.payload.count))
            return total + length.data.count + hop.payload.count + 32
        }
        let packet = try OnionPacket.create(hops: hops, associatedData: Data(), size: size <= 1300 ? 1300 : 32768)
        return try envelope(blinding: route.blinding, packet: packet)
    }
    private static func prefixed(_ path: BlindedPath, nodes: [Data]) throws -> BlindedPath {
        guard !nodes.isEmpty else { return path }
        guard case .node(let introduction) = path.introduction else { throw LightningError.invalidMessage }
        let payloads = try nodes.indices.map { index -> Data in
            let last = index == nodes.count - 1
            var fields: [LightningWire.TLV] = [.init(type: 4, value: last ? introduction : nodes[index + 1])]
            if last { fields.append(.init(type: 8, value: path.blinding)) }
            return try Bolt12Encoding.serialize(fields)
        }
        let prefix = try blind(nodes: nodes, payloads: payloads)
        return try .init(introduction: prefix.introduction, blinding: prefix.blinding, hops: prefix.hops + path.hops)
    }
    public static func peel(_ message: LightningWire.Message, nodeSecret: Data, authenticationKey: Data) throws -> Peeled {
        guard message.type == 513, authenticationKey.count == 32 else { throw LightningError.invalidMessage }
        var reader = LightningWire.Reader(message.payload)
        let blinding = try reader.take(33), length = try reader.u16(), packet = try reader.take(Int(length)); try reader.requireEnd()
        let shared = try NoiseCrypto.ecdh(secret: nodeSecret, point: blinding)
        let factor = OnionPacket.derive("blinded_node_id", secret: shared)
        let secret = try ChannelKeys.privateKey(nodeSecret).multiply(Array(factor)).dataRepresentation
        let peeled = try OnionPacket.peel(packet, secret: secret, associatedData: Data())
        let fields = try Bolt12Encoding.records(peeled.payload)
        guard let encrypted = fields.first(where: { $0.type == 4 })?.value else { throw LightningError.invalidMessage }
        let control = try NoiseCrypto.decrypt(encrypted, key: OnionPacket.derive("rho", secret: shared), nonce: 0)
        var controls = LightningWire.Reader(control)
        let values = try controls.tlvs(known: [2, 4, 8, 65537])
        if let next = peeled.next { return try forward(values, fields: fields, packet: next, blinding: blinding, shared: shared) }
        return try receive(values, fields: fields, authenticationKey: authenticationKey)
    }
    private static func forward(_ controls: [LightningWire.TLV], fields: [LightningWire.TLV], packet: Data, blinding: Data, shared: Data) throws -> Peeled {
        guard fields.count == 1, fields[0].type == 4, !controls.contains(where: { $0.type == 65537 }) else { throw LightningError.invalidMessage }
        let values = Dictionary(uniqueKeysWithValues: controls.map { ($0.type, $0.value) })
        let destination: Destination
        switch (values[2], values[4]) {
        case (nil, .some(let key)): _ = try ChannelKeys.point(key); destination = .node(key)
        case (.some(let scid), nil):
            var reader = LightningWire.Reader(scid); destination = .channel(try reader.u64()); try reader.requireEnd()
        default: throw LightningError.invalidMessage
        }
        let nextBlinding = try values[8] ?? ChannelKeys.point(blinding).multiply(Array(ChannelKeys.hash(blinding + shared))).dataRepresentation
        return try .forward(destination, envelope(blinding: nextBlinding, packet: packet))
    }
    private static func receive(_ controls: [LightningWire.TLV], fields: [LightningWire.TLV], authenticationKey: Data) throws -> Peeled {
        if controls.isEmpty { return try publicInvoiceRequest(fields) }
        guard !controls.contains(where: { [2, 4, 8].contains($0.type) }), let authenticated = controls.first(where: { $0.type == 65537 })?.value,
              authenticated.count >= 32, fields.allSatisfy({ $0.type == 2 || $0.type == 4 || $0.type >= 64 }) else { throw LightningError.invalidMessage }
        let context = Data(authenticated.dropLast(32)), tag = authenticated.suffix(32)
        guard HMAC<CryptoKit.SHA256>.isValidAuthenticationCode(tag, authenticating: context, using: SymmetricKey(data: authenticationKey)) else {
            throw LightningError.authenticationFailed
        }
        let content = fields.filter { $0.type >= 64 }
        guard content.count == 1 else { throw LightningError.invalidMessage }
        let reply = try fields.first(where: { $0.type == 2 }).map { field in
            var reader = LightningWire.Reader(field.value)
            let path = try BlindedPath(reader: &reader); try reader.requireEnd(); return path
        }
        return .receive(content: content[0], context: context, reply: reply)
    }
    private static func publicInvoiceRequest(_ fields: [LightningWire.TLV]) throws -> Peeled {
        guard fields.allSatisfy({ [2, 4, 64].contains($0.type) }),
              let content = fields.first(where: { $0.type == 64 }) else { throw LightningError.invalidMessage }
        // Syntax and the payer signature are checked before this reaches the
        // engine's exact persisted-offer/path binding checks.
        _ = try InvoiceRequest(bytes: content.value)
        let reply = try fields.first(where: { $0.type == 2 }).map { field in
            var reader = LightningWire.Reader(field.value)
            let path = try BlindedPath(reader: &reader); try reader.requireEnd(); return path
        }
        return .invoiceRequest(content: content, reply: reply)
    }
    private static func envelope(blinding: Data, packet: Data) throws -> LightningWire.Message {
        _ = try ChannelKeys.point(blinding)
        guard [1366, 32834].contains(packet.count) else { throw LightningError.invalidMessage }
        var writer = LightningWire.Writer(); writer.append(blinding); writer.u16(UInt16(packet.count)); writer.append(packet)
        return try .init(type: 513, payload: writer.data)
    }
}
