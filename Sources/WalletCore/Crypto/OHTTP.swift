import CryptoKit
import Foundation

/// Oblivious HTTP (RFC 9458) over the binary HTTP message format (RFC 9292),
/// written from both RFCs: a key configuration codec, known-length BHTTP
/// requests and responses, and the HPKE encapsulation of a request plus the
/// exporter-keyed encryption of its response. Generic over the HPKE curve
/// and AEAD like `HPKE` itself, so the RFC's X25519/AES-GCM worked example
/// checks the same code BIP 77 runs with secp256k1/ChaCha20-Poly1305. Both
/// the client half (the wallet) and the gateway half (the test directory)
/// live here; the gateway half is what proves the client half.
///
/// Exercised by `OHTTPTests` (RFC 9458 Appendix A byte for byte, BHTTP
/// round trips and padding, BIP 77 sizes).
public enum OHTTP {
    public enum Failure: Error, Equatable {
        case malformed(String)
        case unsupportedAlgorithm
        case tooLarge
    }

    // MARK: - Key configuration (RFC 9458 §3.1)

    public struct KeyConfig: Equatable, Sendable {
        public var keyID: UInt8
        public var kemID: UInt16
        /// The gateway's HPKE public key, serialized per the KEM (Npk bytes).
        public var publicKey: Data
        public var symmetricAlgorithms: [SymmetricAlgorithm]

        public struct SymmetricAlgorithm: Equatable, Sendable {
            public var kdfID: UInt16
            public var aeadID: UInt16
            public init(kdfID: UInt16, aeadID: UInt16) {
                self.kdfID = kdfID
                self.aeadID = aeadID
            }
        }

        public init(keyID: UInt8, kemID: UInt16, publicKey: Data, symmetricAlgorithms: [SymmetricAlgorithm]) {
            self.keyID = keyID
            self.kemID = kemID
            self.publicKey = publicKey
            self.symmetricAlgorithms = symmetricAlgorithms
        }

        /// Decodes one key configuration; the public key length follows the
        /// KEM id (RFC 9180's registry: 0x0010/0x0016 → 65, 0x0020 → 32).
        public init(encoded: Data) throws {
            var reader = ByteReader(encoded)
            guard encoded.count >= 3 else { throw Failure.malformed("key config too short") }
            keyID = try reader.readUInt8()
            kemID = try Self.readBigEndian16(&reader)
            guard let npk = Self.publicKeyLength(kemID: kemID) else { throw Failure.unsupportedAlgorithm }
            publicKey = try reader.readBytes(npk)
            let length = Int(try Self.readBigEndian16(&reader))
            guard length % 4 == 0, reader.remaining >= length else { throw Failure.malformed("symmetric algorithms") }
            symmetricAlgorithms = try (0 ..< length / 4).map { _ in
                SymmetricAlgorithm(kdfID: try Self.readBigEndian16(&reader), aeadID: try Self.readBigEndian16(&reader))
            }
            guard reader.remaining == 0 else { throw Failure.malformed("trailing key config bytes") }
        }

        public var encoded: Data {
            var data = Data([keyID])
            data += Self.bigEndian16(kemID)
            data += publicKey
            data += Self.bigEndian16(UInt16(symmetricAlgorithms.count * 4))
            for algorithm in symmetricAlgorithms {
                data += Self.bigEndian16(algorithm.kdfID) + Self.bigEndian16(algorithm.aeadID)
            }
            return data
        }

        static func publicKeyLength(kemID: UInt16) -> Int? {
            switch kemID {
            case 0x0010, 0x0016: 65
            case 0x0011: 97
            case 0x0012: 133
            case 0x0020, 0x0021: 32
            default: nil
            }
        }

        static func readBigEndian16(_ reader: inout ByteReader) throws -> UInt16 {
            let bytes = try reader.readBytes(2)
            return UInt16(bytes[bytes.startIndex]) << 8 | UInt16(bytes[bytes.startIndex + 1])
        }

        static func bigEndian16(_ value: UInt16) -> Data {
            Data([UInt8(value >> 8), UInt8(value & 0xFF)])
        }
    }

    // MARK: - QUIC variable-length integers (RFC 9000 §16)

    static func appendVarint(_ value: UInt64, to data: inout Data) {
        switch value {
        case 0 ..< 0x40:
            data.append(UInt8(value))
        case 0x40 ..< 0x4000:
            data += [UInt8(0x40 | value >> 8), UInt8(value & 0xFF)]
        case 0x4000 ..< 0x4000_0000:
            data += [UInt8(0x80 | value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        default:
            data.append(UInt8(0xC0 | value >> 56))
            for shift in stride(from: 48, through: 0, by: -8) { data.append(UInt8(value >> UInt64(shift) & 0xFF)) }
        }
    }

    static func readVarint(_ reader: inout ByteReader) throws -> UInt64 {
        let first = try reader.readUInt8()
        let length = 1 << Int(first >> 6)
        var value = UInt64(first & 0x3F)
        for _ in 1 ..< length { value = value << 8 | UInt64(try reader.readUInt8()) }
        return value
    }

    static func appendLengthPrefixed(_ bytes: Data, to data: inout Data) {
        appendVarint(UInt64(bytes.count), to: &data)
        data += bytes
    }

    static func readLengthPrefixed(_ reader: inout ByteReader, limit: Int = 1 << 20) throws -> Data {
        let length = try readVarint(&reader)
        guard length <= UInt64(limit), Int(length) <= reader.remaining else { throw Failure.malformed("length") }
        return try reader.readBytes(Int(length))
    }

    // MARK: - Field sections

    public typealias Field = (name: String, value: String)

    static func appendFieldSection(_ fields: [Field], to data: inout Data) {
        var section = Data()
        for field in fields {
            appendLengthPrefixed(Data(field.name.utf8), to: &section)
            appendLengthPrefixed(Data(field.value.utf8), to: &section)
        }
        appendLengthPrefixed(section, to: &data)
    }

    /// A known-length field section; a truncated message (RFC 9292 §3.8)
    /// reads as empty.
    static func readFieldSection(_ reader: inout ByteReader) throws -> [Field] {
        guard reader.remaining > 0 else { return [] }
        var section = ByteReader(try readLengthPrefixed(&reader))
        var fields: [Field] = []
        while section.remaining > 0 {
            let name = try readLengthPrefixed(&section)
            let value = try readLengthPrefixed(&section)
            guard !name.isEmpty else { throw Failure.malformed("empty field name") }
            fields.append((String(decoding: name, as: UTF8.self), String(decoding: value, as: UTF8.self)))
        }
        return fields
    }

    static func readContent(_ reader: inout ByteReader) throws -> Data {
        guard reader.remaining > 0 else { return Data() }
        return try readLengthPrefixed(&reader, limit: 16 << 20)
    }

    // MARK: - BHTTP request (RFC 9292 §3.1, §3.4)

    public struct Request: Equatable, Sendable {
        public var method: String
        public var scheme: String
        public var authority: String
        public var path: String
        public var headers: [(name: String, value: String)]
        public var body: Data

        public init(method: String, scheme: String, authority: String, path: String,
                    headers: [(name: String, value: String)] = [], body: Data = Data()) {
            self.method = method
            self.scheme = scheme
            self.authority = authority
            self.path = path
            self.headers = headers
            self.body = body
        }

        public static func == (lhs: Request, rhs: Request) -> Bool {
            lhs.method == rhs.method && lhs.scheme == rhs.scheme && lhs.authority == rhs.authority
                && lhs.path == rhs.path && lhs.body == rhs.body
                && lhs.headers.map { "\($0.name):\($0.value)" } == rhs.headers.map { "\($0.name):\($0.value)" }
        }

        /// Known-length framing with every section present (an empty
        /// trailer section included), so bytes appended after it are padding.
        public var encoded: Data {
            var data = Data([0])
            OHTTP.appendLengthPrefixed(Data(method.utf8), to: &data)
            OHTTP.appendLengthPrefixed(Data(scheme.utf8), to: &data)
            OHTTP.appendLengthPrefixed(Data(authority.utf8), to: &data)
            OHTTP.appendLengthPrefixed(Data(path.utf8), to: &data)
            OHTTP.appendFieldSection(headers, to: &data)
            OHTTP.appendLengthPrefixed(body, to: &data)
            OHTTP.appendVarint(0, to: &data)
            return data
        }

        /// Decodes a known-length request, accepting truncation and ignoring
        /// whatever follows the trailer section.
        public init(decoding data: Data) throws {
            var reader = ByteReader(data)
            guard try OHTTP.readVarint(&reader) == 0 else { throw Failure.malformed("not a known-length request") }
            method = String(decoding: try OHTTP.readLengthPrefixed(&reader), as: UTF8.self)
            scheme = String(decoding: try OHTTP.readLengthPrefixed(&reader), as: UTF8.self)
            authority = String(decoding: try OHTTP.readLengthPrefixed(&reader), as: UTF8.self)
            path = String(decoding: try OHTTP.readLengthPrefixed(&reader), as: UTF8.self)
            headers = try OHTTP.readFieldSection(&reader)
            body = try OHTTP.readContent(&reader)
            _ = try OHTTP.readFieldSection(&reader) // trailers
        }
    }

    // MARK: - BHTTP response (RFC 9292 §3.1, §3.5)

    public struct Response: Equatable, Sendable {
        public var status: Int
        public var headers: [(name: String, value: String)]
        public var body: Data

        public init(status: Int, headers: [(name: String, value: String)] = [], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        public static func == (lhs: Response, rhs: Response) -> Bool {
            lhs.status == rhs.status && lhs.body == rhs.body
                && lhs.headers.map { "\($0.name):\($0.value)" } == rhs.headers.map { "\($0.name):\($0.value)" }
        }

        public var encoded: Data {
            var data = Data([1])
            OHTTP.appendVarint(UInt64(status), to: &data)
            OHTTP.appendFieldSection(headers, to: &data)
            OHTTP.appendLengthPrefixed(body, to: &data)
            OHTTP.appendVarint(0, to: &data)
            return data
        }

        /// Decodes a known-length response, skipping informational (1xx)
        /// responses and accepting truncation and trailing padding.
        public init(decoding data: Data) throws {
            var reader = ByteReader(data)
            guard try OHTTP.readVarint(&reader) == 1 else { throw Failure.malformed("not a known-length response") }
            var code = try OHTTP.readVarint(&reader)
            while (100 ..< 200).contains(code) {
                _ = try OHTTP.readFieldSection(&reader)
                code = try OHTTP.readVarint(&reader)
            }
            guard (200 ..< 600).contains(code) else { throw Failure.malformed("status \(code)") }
            status = Int(code)
            headers = try OHTTP.readFieldSection(&reader)
            body = try OHTTP.readContent(&reader)
            _ = try OHTTP.readFieldSection(&reader)
        }
    }

    // MARK: - Encapsulation (RFC 9458 §4)

    static let requestInfoPrefix = Data("message/bhttp request".utf8) + Data([0])
    static let responseExportContext = Data("message/bhttp response".utf8)

    /// The 7-byte header: key id, KEM, KDF and AEAD ids.
    static func header<Curve: HPKE.KEMCurve, Cipher: HPKE.AEAD>(keyID: UInt8, _: Curve.Type, _: Cipher.Type) -> Data {
        Data([keyID]) + KeyConfig.bigEndian16(Curve.id) + KeyConfig.bigEndian16(HPKE.kdfID)
            + KeyConfig.bigEndian16(Cipher.id)
    }

    /// What the client keeps to decrypt the gateway's answer.
    public struct ClientContext<Curve: HPKE.KEMCurve, Cipher: HPKE.AEAD>: Sendable {
        let enc: Data
        let context: HPKE.Context<Cipher>

        /// Decrypts an encapsulated response to its BHTTP bytes.
        public func decapsulate(_ encapsulated: Data) throws -> Data {
            try OHTTP.openResponse(encapsulated, enc: enc, context: context, Curve.self, Cipher.self)
        }
    }

    /// Encapsulates BHTTP request bytes to the gateway described by
    /// `config`, which must offer the selected KDF/AEAD pair. `ephemeral`
    /// pins the HPKE ephemeral key for test vectors.
    public static func encapsulateRequest<Curve: HPKE.KEMCurve, Cipher: HPKE.AEAD>(
        _ request: Data, config: KeyConfig, _: Curve.Type, _: Cipher.Type,
        ephemeral: Curve.PrivateKey? = nil
    ) throws -> (encapsulated: Data, context: ClientContext<Curve, Cipher>) {
        guard config.kemID == Curve.id,
              config.symmetricAlgorithms.contains(where: { $0.kdfID == HPKE.kdfID && $0.aeadID == Cipher.id })
        else { throw Failure.unsupportedAlgorithm }
        let header = header(keyID: config.keyID, Curve.self, Cipher.self)
        let recipient = try Curve.deserialize(config.publicKey)
        var (enc, context) = try HPKE.Suite<Curve, Cipher>.setupSender(
            recipient: recipient, info: requestInfoPrefix + header, ephemeral: ephemeral)
        let ciphertext = try context.seal(plaintext: request)
        return (header + enc + ciphertext, ClientContext(enc: enc, context: context))
    }

    /// What the gateway keeps to answer a decapsulated request.
    public struct GatewayContext<Curve: HPKE.KEMCurve, Cipher: HPKE.AEAD>: Sendable {
        let enc: Data
        let context: HPKE.Context<Cipher>

        /// Encapsulates BHTTP response bytes; `nonce` pins the response
        /// nonce for test vectors.
        public func encapsulate(_ response: Data, nonce: Data? = nil) throws -> Data {
            let length = max(Cipher.nn, Cipher.nk)
            let responseNonce = nonce ?? ElligatorSwift.random(count: length)
            guard responseNonce.count == length else { throw Failure.malformed("response nonce") }
            let keys = OHTTP.responseKeys(enc: enc, context: context, nonce: responseNonce, Cipher.self)
            let ciphertext = try Cipher.seal(key: keys.key, nonce: keys.nonce, aad: Data(), plaintext: response)
            return responseNonce + ciphertext
        }
    }

    /// Gateway side: decrypts an encapsulated request with the key
    /// `config` advertises (its private half is `privateKey`).
    public static func decapsulateRequest<Curve: HPKE.KEMCurve, Cipher: HPKE.AEAD>(
        _ encapsulated: Data, config: KeyConfig, privateKey: Curve.PrivateKey, _: Curve.Type, _: Cipher.Type
    ) throws -> (request: Data, context: GatewayContext<Curve, Cipher>) {
        let header = header(keyID: config.keyID, Curve.self, Cipher.self)
        guard encapsulated.count >= header.count + Curve.nenc else { throw Failure.malformed("encapsulated request") }
        guard encapsulated.prefix(header.count) == header else { throw Failure.unsupportedAlgorithm }
        let enc = encapsulated.dropFirst(header.count).prefix(Curve.nenc)
        let ciphertext = encapsulated.dropFirst(header.count + Curve.nenc)
        var context = try HPKE.Suite<Curve, Cipher>.setupRecipient(
            enc: Data(enc), recipient: privateKey, info: requestInfoPrefix + header)
        let request = try context.open(ciphertext: Data(ciphertext))
        return (request, GatewayContext(enc: Data(enc), context: context))
    }

    /// RFC 9458 §4.4: the response key and nonce from the request context's
    /// exporter, the request's `enc` and the response nonce.
    static func responseKeys<Cipher: HPKE.AEAD>(enc: Data, context: HPKE.Context<Cipher>, nonce: Data,
                                                _: Cipher.Type) -> (key: Data, nonce: Data) {
        let length = max(Cipher.nn, Cipher.nk)
        let secret = context.export(context: responseExportContext, length: length)
        let prk = HKDF<CryptoKit.SHA256>.extract(inputKeyMaterial: SymmetricKey(data: secret), salt: enc + nonce)
        let key = HKDF<CryptoKit.SHA256>.expand(pseudoRandomKey: prk, info: Data("key".utf8), outputByteCount: Cipher.nk)
        let aeadNonce = HKDF<CryptoKit.SHA256>.expand(pseudoRandomKey: prk, info: Data("nonce".utf8),
                                                      outputByteCount: Cipher.nn)
        return (key.withUnsafeBytes { Data($0) }, aeadNonce.withUnsafeBytes { Data($0) })
    }

    static func openResponse<Curve: HPKE.KEMCurve, Cipher: HPKE.AEAD>(
        _ encapsulated: Data, enc: Data, context: HPKE.Context<Cipher>, _: Curve.Type, _: Cipher.Type
    ) throws -> Data {
        let length = max(Cipher.nn, Cipher.nk)
        guard encapsulated.count > length else { throw Failure.malformed("encapsulated response") }
        let nonce = encapsulated.prefix(length)
        let keys = responseKeys(enc: enc, context: context, nonce: Data(nonce), Cipher.self)
        return try Cipher.open(key: keys.key, nonce: keys.nonce, aad: Data(),
                               ciphertext: Data(encapsulated.dropFirst(length)))
    }
}
