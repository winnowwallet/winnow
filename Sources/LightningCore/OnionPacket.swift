import CryptoKit
import Foundation
import P256K

/// BOLT 4 Sphinx packets, shared by payment and onion-message envelopes. Hop
/// payloads are canonical TLV streams; the envelope supplies associated data.
public enum OnionPacket {
    public struct Hop: Sendable {
        public let publicKey: Data, payload: Data
        public init(publicKey: Data, payload: Data) { self.publicKey = publicKey; self.payload = payload }
    }
    public struct Peeled: Sendable {
        public let payload: Data
        public let sharedSecret: Data
        public let next: Data?
    }
    public static func create(hops: [Hop], associatedData: Data, size: Int = 1300) throws -> Data {
        try create(hops: hops, associatedData: associatedData, size: size,
                   session: P256K.Signing.PrivateKey().dataRepresentation,
                   padding: P256K.Signing.PrivateKey().dataRepresentation)
    }
    static func create(hops: [Hop], associatedData: Data, size: Int, session: Data, padding: Data) throws -> Data {
        guard (1...20).contains(hops.count), [1300, 32768].contains(size) else { throw LightningError.invalidMessage }
        let payloads = hops.map { hop in
            var writer = LightningWire.Writer(); writer.bigSize(UInt64(hop.payload.count)); writer.append(hop.payload)
            return writer.data
        }
        guard payloads.allSatisfy({ $0.count > 1 }), payloads.reduce(0, { $0 + $1.count + 32 }) <= size
        else { throw LightningError.invalidMessage }
        var secret = session, shared: [Data] = []
        for hop in hops {
            let point = try ChannelKeys.publicKey(secret: secret)
            let sharedSecret = try NoiseCrypto.ecdh(secret: secret, point: hop.publicKey)
            shared.append(sharedSecret)
            secret = try ChannelKeys.privateKey(secret).multiply(Array(ChannelKeys.hash(point + sharedSecret))).dataRepresentation
        }
        let filler = try filler(payloads: payloads, shared: shared, size: size)
        var routing = try OnionStream.bytes(key: derive("pad", secret: padding), count: size)
        var hmac = Data(repeating: 0, count: 32)
        for index in hops.indices.reversed() {
            let prefix = payloads[index] + hmac
            routing = xor(prefix + routing.prefix(size - prefix.count), try OnionStream.bytes(key: derive("rho", secret: shared[index]), count: size))
            if index == hops.count - 1 { routing.replaceSubrange((size - filler.count)..<size, with: filler) }
            hmac = authenticate(routing + associatedData, key: derive("mu", secret: shared[index]))
        }
        return try Data([0]) + ChannelKeys.publicKey(secret: session) + routing + hmac
    }
    public static func peel(_ packet: Data, secret: Data, associatedData: Data) throws -> Peeled {
        guard [1366, 32834].contains(packet.count) else { throw LightningError.invalidMessage }
        var reader = LightningWire.Reader(packet)
        guard try reader.u8() == 0 else { throw LightningError.invalidMessage }
        let point = try reader.take(33), size = packet.count - 66
        let routing = try reader.take(size), hmac = try reader.take(32)
        let shared = try NoiseCrypto.ecdh(secret: secret, point: point)
        guard HMAC<CryptoKit.SHA256>.isValidAuthenticationCode(hmac, authenticating: routing + associatedData,
            using: SymmetricKey(data: derive("mu", secret: shared))) else { throw LightningError.authenticationFailed }
        let expanded = routing + Data(repeating: 0, count: size)
        let decrypted = xor(expanded, try OnionStream.bytes(key: derive("rho", secret: shared), count: size * 2))
        var payloadReader = LightningWire.Reader(decrypted)
        let length = try payloadReader.bigSize()
        guard length >= 2, length <= UInt64(size - 32 - (decrypted.count - payloadReader.remaining)) else { throw LightningError.invalidMessage }
        let payload = try payloadReader.take(Int(length)), nextHMAC = try payloadReader.take(32)
        if nextHMAC == Data(repeating: 0, count: 32) { return Peeled(payload: payload, sharedSecret: shared, next: nil) }
        let nextPoint = try ChannelKeys.point(point).multiply(Array(ChannelKeys.hash(point + shared))).dataRepresentation
        return try Peeled(payload: payload, sharedSecret: shared, next: Data([0]) + nextPoint + payloadReader.take(size) + nextHMAC)
    }
    private static func filler(payloads: [Data], shared: [Data], size: Int) throws -> Data {
        var filler = Data(), offset = 0
        for index in payloads.indices.dropLast() {
            let start = size - offset
            offset += payloads[index].count + 32
            filler.append(Data(repeating: 0, count: payloads[index].count + 32))
            let stream = try OnionStream.bytes(key: derive("rho", secret: shared[index]), count: start + offset)
            filler = xor(filler, stream.dropFirst(start))
        }
        return filler
    }
    static func derive(_ label: String, secret: Data) -> Data { authenticate(secret, key: Data(label.utf8)) }
    static func failure(sharedSecret: Data, code: UInt16, data: Data) throws -> Data {
        guard data.count <= 254 else { throw LightningError.invalidMessage }
        var body = LightningWire.Writer(); body.u16(UInt16(data.count + 2)); body.u16(code); body.append(data)
        body.u16(UInt16(254 - data.count)); body.append(Data(repeating: 0, count: 254 - data.count))
        let authenticated = authenticate(body.data, key: derive("um", secret: sharedSecret)) + body.data
        return xor(authenticated, try OnionStream.bytes(key: derive("ammag", secret: sharedSecret), count: authenticated.count))
    }
    static func authenticate(_ bytes: Data, key: Data) -> Data { Data(HMAC<CryptoKit.SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: key))) }
    static func xor(_ lhs: Data, _ rhs: Data) -> Data { Data(zip(lhs, rhs).map { $0 ^ $1 }) }
}

/// IETF ChaCha20 with zero nonce and initial counter zero, as specified by
/// BOLT 4. CryptoKit's AEAD intentionally doesn't expose this stream primitive.
enum OnionStream {
    static func bytes(key: Data, count: Int) throws -> Data {
        guard key.count == 32, (0...65_536).contains(count) else { throw LightningError.invalidKey }
        let bytes = Array(key)
        let words: [UInt32] = stride(from: 0, to: 32, by: 4).map { index in
            let low = UInt32(bytes[index]) | (UInt32(bytes[index + 1]) << 8)
            let high = (UInt32(bytes[index + 2]) << 16) | (UInt32(bytes[index + 3]) << 24)
            return low | high
        }
        var output = Data()
        for counter in 0..<((count + 63) / 64) {
            let initial: [UInt32] = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574] + words + [UInt32(counter), 0, 0, 0]
            var state = initial
            for _ in 0..<10 { rounds(&state) }
            for index in state.indices {
                let word = state[index] &+ initial[index]
                for shift in stride(from: 0, through: 24, by: 8) { output.append(UInt8(truncatingIfNeeded: word >> shift)) }
            }
        }
        return Data(output.prefix(count))
    }
    private static func rounds(_ state: inout [UInt32]) {
        quarter(&state, 0, 4, 8, 12); quarter(&state, 1, 5, 9, 13)
        quarter(&state, 2, 6, 10, 14); quarter(&state, 3, 7, 11, 15)
        quarter(&state, 0, 5, 10, 15); quarter(&state, 1, 6, 11, 12)
        quarter(&state, 2, 7, 8, 13); quarter(&state, 3, 4, 9, 14)
    }
    private static func rotate(_ value: UInt32, _ bits: Int) -> UInt32 { (value << bits) | (value >> (32 - bits)) }
    private static func quarter(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] &+= s[b]; s[d] = rotate(s[d] ^ s[a], 16)
        s[c] &+= s[d]; s[b] = rotate(s[b] ^ s[c], 12)
        s[a] &+= s[b]; s[d] = rotate(s[d] ^ s[a], 8)
        s[c] &+= s[d]; s[b] = rotate(s[b] ^ s[c], 7)
    }
}
