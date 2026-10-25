import CryptoKit
import Foundation
import P256K

/// Hybrid Public Key Encryption (RFC 9180) with HKDF-SHA256 as the KDF,
/// generic over the KEM and the AEAD so one key schedule serves BIP 77's
/// `DHKEM(secp256k1, HKDF-SHA256)` + ChaCha20-Poly1305 and the RFC's own
/// X25519 vectors. Written from the RFC: CryptoKit's HPKE has no secp256k1
/// KEM and `swift-secp256k1` has no HPKE, so the schedule, the DHKEM and the
/// exporter live here on top of CryptoKit's HKDF and AEADs and P256K's ECDH.
///
/// `HPKETests` runs the RFC 9180 vectors (X25519, every mode, every
/// encryption and export) and the secp256k1 KEM draft's vectors
/// (`draft-wahby-cfrg-hpke-kem-secp256k1-01`, Base and Auth).
public enum HPKE {
    public enum Mode: UInt8, Sendable {
        case base = 0, psk = 1, auth = 2, authPSK = 3
    }

    public enum Failure: Error, Equatable {
        case invalidKey
        case invalidLength
        case openFailed
        case sequenceExhausted
        case deriveKeyPairFailed
        case missingPSK
    }

    static let version = Data("HPKE-v1".utf8)
    static let kdfID: UInt16 = 0x0001 // HKDF-SHA256
    static let nh = 32

    // MARK: - KDF

    static func labeledExtract(suite: Data, salt: Data, label: String, ikm: Data) -> Data {
        let material = version + suite + Data(label.utf8) + ikm
        let prk = HKDF<CryptoKit.SHA256>.extract(inputKeyMaterial: SymmetricKey(data: material), salt: salt)
        return prk.withUnsafeBytes { Data($0) }
    }

    static func labeledExpand(suite: Data, prk: Data, label: String, info: Data, length: Int) -> Data {
        var labeledInfo = Data([UInt8(length >> 8), UInt8(length & 0xFF)])
        labeledInfo += version + suite + Data(label.utf8) + info
        let key = HKDF<CryptoKit.SHA256>.expand(pseudoRandomKey: SymmetricKey(data: prk), info: labeledInfo,
                                      outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    // MARK: - KEM abstraction

    /// A Diffie-Hellman KEM (RFC 9180 §4.1): the curve supplies key
    /// handling and the raw DH; `DHKEM` builds encap/decap on top.
    public protocol KEMCurve {
        associatedtype PrivateKey
        associatedtype PublicKey
        static var id: UInt16 { get }
        static var nsecret: Int { get }
        static var nenc: Int { get }
        static var npk: Int { get }
        static var nsk: Int { get }
        static func generatePrivateKey() throws -> PrivateKey
        static func privateKey(_ bytes: Data) throws -> PrivateKey
        static func publicKey(of privateKey: PrivateKey) -> PublicKey
        static func serialize(_ publicKey: PublicKey) -> Data
        static func deserialize(_ bytes: Data) throws -> PublicKey
        static func dh(_ privateKey: PrivateKey, _ publicKey: PublicKey) throws -> Data
        /// RFC 9180 §7.1.3: nil derives `sk` by one expand (X25519); a
        /// bitmask runs the rejection-sampling loop (NIST and secp256k1).
        static var deriveKeyPairBitmask: UInt8? { get }
    }

    public enum DHKEM<Curve: KEMCurve> {
        static var suite: Data { Data("KEM".utf8) + Data([UInt8(Curve.id >> 8), UInt8(Curve.id & 0xFF)]) }

        static func extractAndExpand(dh: Data, kemContext: Data) -> Data {
            let eaePRK = labeledExtract(suite: suite, salt: Data(), label: "eae_prk", ikm: dh)
            return labeledExpand(suite: suite, prk: eaePRK, label: "shared_secret", info: kemContext,
                                 length: Curve.nsecret)
        }

        /// Encap: `(shared_secret, enc)`; `ephemeral` fixes the ephemeral
        /// key for test vectors.
        public static func encap(to recipient: Curve.PublicKey, sender: Curve.PrivateKey? = nil,
                                 ephemeral: Curve.PrivateKey? = nil) throws -> (sharedSecret: Data, enc: Data) {
            let skE = try ephemeral ?? Curve.generatePrivateKey()
            let enc = Curve.serialize(Curve.publicKey(of: skE))
            let pkRm = Curve.serialize(recipient)
            var dh = try Curve.dh(skE, recipient)
            var context = enc + pkRm
            if let sender {
                dh += try Curve.dh(sender, recipient)
                context += Curve.serialize(Curve.publicKey(of: sender))
            }
            return (extractAndExpand(dh: dh, kemContext: context), enc)
        }

        /// Decap with the recipient key; `sender` is the authenticating key
        /// in Auth mode.
        public static func decap(enc: Data, recipient: Curve.PrivateKey,
                                 sender: Curve.PublicKey? = nil) throws -> Data {
            guard enc.count == Curve.nenc else { throw Failure.invalidLength }
            let pkE = try Curve.deserialize(enc)
            let pkRm = Curve.serialize(Curve.publicKey(of: recipient))
            var dh = try Curve.dh(recipient, pkE)
            var context = enc + pkRm
            if let sender {
                dh += try Curve.dh(recipient, sender)
                context += Curve.serialize(sender)
            }
            return extractAndExpand(dh: dh, kemContext: context)
        }

        /// RFC 9180 §7.1.3 DeriveKeyPair.
        public static func deriveKeyPair(ikm: Data) throws -> Curve.PrivateKey {
            let dkpPRK = labeledExtract(suite: suite, salt: Data(), label: "dkp_prk", ikm: ikm)
            guard let bitmask = Curve.deriveKeyPairBitmask else {
                let sk = labeledExpand(suite: suite, prk: dkpPRK, label: "sk", info: Data(), length: Curve.nsk)
                return try Curve.privateKey(sk)
            }
            for counter in 0 ... 255 {
                var candidate = labeledExpand(suite: suite, prk: dkpPRK, label: "candidate",
                                              info: Data([UInt8(counter)]), length: Curve.nsk)
                candidate[candidate.startIndex] &= bitmask
                if let key = try? Curve.privateKey(candidate) { return key }
            }
            throw Failure.deriveKeyPairFailed
        }
    }

    // MARK: - AEAD abstraction

    public protocol AEAD {
        static var id: UInt16 { get }
        static var nk: Int { get }
        static var nn: Int { get }
        static func seal(key: Data, nonce: Data, aad: Data, plaintext: Data) throws -> Data
        static func open(key: Data, nonce: Data, aad: Data, ciphertext: Data) throws -> Data
    }

    // MARK: - Context

    /// One direction of an established HPKE session: the AEAD key, the
    /// nonce counter and the exporter secret.
    public struct Context<Cipher: AEAD>: Sendable {
        let suite: Data
        let key: Data
        let baseNonce: Data
        let exporterSecret: Data
        var sequence: UInt64 = 0

        /// Seal (sender side); the nonce advances, so the context is `inout`.
        public mutating func seal(aad: Data = Data(), plaintext: Data) throws -> Data {
            let nonce = try nextNonce()
            return try Cipher.seal(key: key, nonce: nonce, aad: aad, plaintext: plaintext)
        }

        /// Open (recipient side).
        public mutating func open(aad: Data = Data(), ciphertext: Data) throws -> Data {
            let nonce = try nextNonce()
            return try Cipher.open(key: key, nonce: nonce, aad: aad, ciphertext: ciphertext)
        }

        /// RFC 9180 §5.3 secret export.
        public func export(context: Data, length: Int) -> Data {
            labeledExpand(suite: suite, prk: exporterSecret, label: "sec", info: context, length: length)
        }

        private mutating func nextNonce() throws -> Data {
            guard sequence != UInt64.max else { throw Failure.sequenceExhausted }
            var nonce = baseNonce
            var counter = sequence
            for index in (0 ..< Cipher.nn).reversed() {
                nonce[nonce.startIndex + index] ^= UInt8(truncatingIfNeeded: counter)
                counter >>= 8
            }
            sequence += 1
            return nonce
        }
    }

    // MARK: - Suite

    public enum Suite<Curve: KEMCurve, Cipher: AEAD> {
        static var suiteID: Data {
            Data("HPKE".utf8) + Data([UInt8(Curve.id >> 8), UInt8(Curve.id & 0xFF)])
                + Data([UInt8(kdfID >> 8), UInt8(kdfID & 0xFF)])
                + Data([UInt8(Cipher.id >> 8), UInt8(Cipher.id & 0xFF)])
        }

        /// RFC 9180 §5.1 KeySchedule.
        static func keySchedule(mode: Mode, sharedSecret: Data, info: Data,
                                psk: Data = Data(), pskID: Data = Data()) throws -> Context<Cipher> {
            let hasPSK = !psk.isEmpty
            guard hasPSK == (mode == .psk || mode == .authPSK) else { throw Failure.missingPSK }
            let suite = suiteID
            let pskIDHash = labeledExtract(suite: suite, salt: Data(), label: "psk_id_hash", ikm: pskID)
            let infoHash = labeledExtract(suite: suite, salt: Data(), label: "info_hash", ikm: info)
            let scheduleContext = Data([mode.rawValue]) + pskIDHash + infoHash
            let secret = labeledExtract(suite: suite, salt: sharedSecret, label: "secret", ikm: psk)
            return Context(
                suite: suite,
                key: labeledExpand(suite: suite, prk: secret, label: "key", info: scheduleContext, length: Cipher.nk),
                baseNonce: labeledExpand(suite: suite, prk: secret, label: "base_nonce", info: scheduleContext,
                                         length: Cipher.nn),
                exporterSecret: labeledExpand(suite: suite, prk: secret, label: "exp", info: scheduleContext,
                                              length: nh))
        }

        /// SetupBaseS / SetupPSKS: `enc` and the sender context.
        public static func setupSender(recipient: Curve.PublicKey, info: Data, psk: Data = Data(),
                                       pskID: Data = Data(),
                                       ephemeral: Curve.PrivateKey? = nil) throws -> (enc: Data, context: Context<Cipher>) {
            let (shared, enc) = try DHKEM<Curve>.encap(to: recipient, ephemeral: ephemeral)
            let mode: Mode = psk.isEmpty ? .base : .psk
            return (enc, try keySchedule(mode: mode, sharedSecret: shared, info: info, psk: psk, pskID: pskID))
        }

        /// SetupAuthS / SetupAuthPSKS: the sender authenticates with `sender`.
        public static func setupAuthSender(recipient: Curve.PublicKey, sender: Curve.PrivateKey, info: Data,
                                           psk: Data = Data(), pskID: Data = Data(),
                                           ephemeral: Curve.PrivateKey? = nil) throws -> (enc: Data, context: Context<Cipher>) {
            let (shared, enc) = try DHKEM<Curve>.encap(to: recipient, sender: sender, ephemeral: ephemeral)
            let mode: Mode = psk.isEmpty ? .auth : .authPSK
            return (enc, try keySchedule(mode: mode, sharedSecret: shared, info: info, psk: psk, pskID: pskID))
        }

        /// SetupBaseR / SetupPSKR.
        public static func setupRecipient(enc: Data, recipient: Curve.PrivateKey, info: Data,
                                          psk: Data = Data(), pskID: Data = Data()) throws -> Context<Cipher> {
            let shared = try DHKEM<Curve>.decap(enc: enc, recipient: recipient)
            let mode: Mode = psk.isEmpty ? .base : .psk
            return try keySchedule(mode: mode, sharedSecret: shared, info: info, psk: psk, pskID: pskID)
        }

        /// SetupAuthR / SetupAuthPSKR: `sender` is the key the message must
        /// have been sealed with.
        public static func setupAuthRecipient(enc: Data, recipient: Curve.PrivateKey, sender: Curve.PublicKey,
                                              info: Data, psk: Data = Data(),
                                              pskID: Data = Data()) throws -> Context<Cipher> {
            let shared = try DHKEM<Curve>.decap(enc: enc, recipient: recipient, sender: sender)
            let mode: Mode = psk.isEmpty ? .auth : .authPSK
            return try keySchedule(mode: mode, sharedSecret: shared, info: info, psk: psk, pskID: pskID)
        }
    }
}

// MARK: - Curves

extension HPKE {
    /// DHKEM(secp256k1, HKDF-SHA256), id 0x0016
    /// (draft-wahby-cfrg-hpke-kem-secp256k1): uncompressed 65-byte keys, the
    /// DH value is the shared point's x coordinate, DeriveKeyPair uses the
    /// 0xFF bitmask. Keys and ECDH come from P256K.
    public enum Secp256k1: KEMCurve {
        public typealias PrivateKey = P256K.KeyAgreement.PrivateKey
        public typealias PublicKey = P256K.KeyAgreement.PublicKey
        public static let id: UInt16 = 0x0016
        public static let nsecret = 32
        public static let nenc = 65
        public static let npk = 65
        public static let nsk = 32
        public static let deriveKeyPairBitmask: UInt8? = 0xFF

        public static func generatePrivateKey() throws -> PrivateKey {
            try PrivateKey(format: .uncompressed)
        }

        public static func privateKey(_ bytes: Data) throws -> PrivateKey {
            guard bytes.count == nsk else { throw Failure.invalidLength }
            guard let key = try? PrivateKey(dataRepresentation: bytes, format: .uncompressed) else {
                throw Failure.invalidKey
            }
            return key
        }

        public static func publicKey(of privateKey: PrivateKey) -> PublicKey { privateKey.publicKey }

        public static func serialize(_ publicKey: PublicKey) -> Data { publicKey.uncompressedRepresentation }

        public static func deserialize(_ bytes: Data) throws -> PublicKey {
            guard bytes.count == npk else { throw Failure.invalidLength }
            guard let key = try? PublicKey(dataRepresentation: bytes, format: .uncompressed) else {
                throw Failure.invalidKey
            }
            return key
        }

        public static func dh(_ privateKey: PrivateKey, _ publicKey: PublicKey) throws -> Data {
            let point = privateKey.sharedSecretFromKeyAgreement(with: publicKey, format: .uncompressed)
            let bytes = point.withUnsafeBytes { Data($0) }
            guard bytes.count == 65 else { throw Failure.invalidKey }
            return bytes[bytes.startIndex + 1 ..< bytes.startIndex + 33]
        }

        /// The 33-byte compressed form BIP 77 carries in URIs and messages.
        public static func compressed(_ publicKey: PublicKey) -> Data { publicKey.dataRepresentation }

        public static func publicKey(compressed bytes: Data) throws -> PublicKey {
            guard bytes.count == 33 else { throw Failure.invalidLength }
            guard let key = try? PublicKey(dataRepresentation: bytes, format: .compressed) else {
                throw Failure.invalidKey
            }
            return key
        }
    }

    /// DHKEM(X25519, HKDF-SHA256), id 0x0020, for the RFC 9180 and RFC 9458
    /// test vectors.
    public enum X25519: KEMCurve {
        public typealias PrivateKey = Curve25519.KeyAgreement.PrivateKey
        public typealias PublicKey = Curve25519.KeyAgreement.PublicKey
        public static let id: UInt16 = 0x0020
        public static let nsecret = 32
        public static let nenc = 32
        public static let npk = 32
        public static let nsk = 32
        public static let deriveKeyPairBitmask: UInt8? = nil

        public static func generatePrivateKey() throws -> PrivateKey { PrivateKey() }

        public static func privateKey(_ bytes: Data) throws -> PrivateKey {
            guard let key = try? PrivateKey(rawRepresentation: bytes) else { throw Failure.invalidKey }
            return key
        }

        public static func publicKey(of privateKey: PrivateKey) -> PublicKey { privateKey.publicKey }
        public static func serialize(_ publicKey: PublicKey) -> Data { publicKey.rawRepresentation }

        public static func deserialize(_ bytes: Data) throws -> PublicKey {
            guard let key = try? PublicKey(rawRepresentation: bytes) else { throw Failure.invalidKey }
            return key
        }

        public static func dh(_ privateKey: PrivateKey, _ publicKey: PublicKey) throws -> Data {
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            let bytes = shared.withUnsafeBytes { Data($0) }
            // RFC 9180 §7.1.4: the all-zero output is an invalid public key.
            guard bytes.contains(where: { $0 != 0 }) else { throw Failure.invalidKey }
            return bytes
        }
    }
}

// MARK: - AEADs

extension HPKE {
    /// ChaCha20-Poly1305, id 0x0003.
    public enum ChaChaPolyAEAD: AEAD {
        public static let id: UInt16 = 0x0003
        public static let nk = 32
        public static let nn = 12

        public static func seal(key: Data, nonce: Data, aad: Data, plaintext: Data) throws -> Data {
            let box = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key),
                                          nonce: ChaChaPoly.Nonce(data: nonce), authenticating: aad)
            return box.ciphertext + box.tag
        }

        public static func open(key: Data, nonce: Data, aad: Data, ciphertext: Data) throws -> Data {
            guard ciphertext.count >= 16 else { throw Failure.openFailed }
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce),
                                               ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
            guard let plaintext = try? ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
            else { throw Failure.openFailed }
            return plaintext
        }
    }

    /// AES-128-GCM, id 0x0001 (the RFC 9458 worked example).
    public enum AESGCM128AEAD: AEAD {
        public static let id: UInt16 = 0x0001
        public static let nk = 16
        public static let nn = 12
        public static func seal(key: Data, nonce: Data, aad: Data, plaintext: Data) throws -> Data {
            try AESGCM.seal(key: key, nonce: nonce, aad: aad, plaintext: plaintext)
        }

        public static func open(key: Data, nonce: Data, aad: Data, ciphertext: Data) throws -> Data {
            try AESGCM.open(key: key, nonce: nonce, aad: aad, ciphertext: ciphertext)
        }
    }

    /// AES-256-GCM, id 0x0002 (the secp256k1 draft's vectors).
    public enum AESGCM256AEAD: AEAD {
        public static let id: UInt16 = 0x0002
        public static let nk = 32
        public static let nn = 12
        public static func seal(key: Data, nonce: Data, aad: Data, plaintext: Data) throws -> Data {
            try AESGCM.seal(key: key, nonce: nonce, aad: aad, plaintext: plaintext)
        }

        public static func open(key: Data, nonce: Data, aad: Data, ciphertext: Data) throws -> Data {
            try AESGCM.open(key: key, nonce: nonce, aad: aad, ciphertext: ciphertext)
        }
    }

    enum AESGCM {
        static func seal(key: Data, nonce: Data, aad: Data, plaintext: Data) throws -> Data {
            let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
                                       nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
            return box.ciphertext + box.tag
        }

        static func open(key: Data, nonce: Data, aad: Data, ciphertext: Data) throws -> Data {
            guard ciphertext.count >= 16 else { throw Failure.openFailed }
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                            ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
            guard let plaintext = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
            else { throw Failure.openFailed }
            return plaintext
        }
    }
}
