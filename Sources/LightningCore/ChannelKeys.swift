import CryptoKit
import Foundation
import P256K

public enum LightningError: Error, Equatable {
    case invalidKey, invalidHash, invalidAmount, invalidCommitment, invalidSignature
    case invalidMessage, invalidState, authenticationFailed, closed, storageFailed
}

/// BOLT 3 key derivation using Winnow's existing libsecp256k1 Swift API.
/// Curve operations and constant-time private-key arithmetic stay in P256K.
public enum ChannelKeys {
    public static let maximumCommitmentNumber: UInt64 = (1 << 48) - 1

    public static func publicKey(secret: Data) throws -> Data {
        try privateKey(secret).publicKey.dataRepresentation
    }

    public static func derivedPublicKey(basepoint: Data, commitmentPoint: Data) throws -> Data {
        _ = try point(commitmentPoint)
        return try point(basepoint).add(Array(hash(commitmentPoint + basepoint))).dataRepresentation
    }

    public static func derivedPrivateKey(baseSecret: Data, commitmentPoint: Data) throws -> Data {
        _ = try point(commitmentPoint)
        let key = try privateKey(baseSecret)
        return try key.add(Array(hash(commitmentPoint + key.publicKey.dataRepresentation))).dataRepresentation
    }

    public static func revocationPublicKey(basepoint: Data, commitmentPoint: Data) throws -> Data {
        let base = try point(basepoint), commitment = try point(commitmentPoint)
        let left = try base.multiply(Array(hash(basepoint + commitmentPoint)))
        let right = try commitment.multiply(Array(hash(commitmentPoint + basepoint)))
        return try left.combine([right], format: .compressed).dataRepresentation
    }

    public static func revocationPrivateKey(baseSecret: Data, commitmentSecret: Data) throws -> Data {
        let base = try privateKey(baseSecret), commitment = try privateKey(commitmentSecret)
        let basepoint = base.publicKey.dataRepresentation, commitmentPoint = commitment.publicKey.dataRepresentation
        let left = try base.multiply(Array(hash(basepoint + commitmentPoint)))
        let right = try commitment.multiply(Array(hash(commitmentPoint + basepoint)))
        return try left.add(Array(right.dataRepresentation)).dataRepresentation
    }

    /// The BOLT 3 shachain index counts down from 2^48-1. The wire commitment
    /// number counts up; keeping both labels explicit prevents off-by-one reuse.
    public static func commitmentSecret(seed: Data, number: UInt64) throws -> Data {
        guard seed.count == 32, number <= maximumCommitmentNumber else { throw LightningError.invalidCommitment }
        let index = maximumCommitmentNumber - number
        var secret = Array(seed)
        for bit in stride(from: 47, through: 0, by: -1) where index & (1 << bit) != 0 {
            secret[bit / 8] ^= UInt8(1 << (bit % 8))
            secret = Array(hash(Data(secret)))
        }
        return Data(secret)
    }

    public static func sign(digest: Data, secret: Data) throws -> Data {
        guard digest.count == 32 else { throw LightningError.invalidHash }
        // Digest overload: the BIP143 digest must not be hashed a third time.
        return try privateKey(secret).signature(for: HashDigest(Array(digest))).derRepresentation
    }

    public static func compactSignature(_ der: Data) throws -> Data {
        try P256K.Signing.ECDSASignature(derRepresentation: der).compactRepresentation
    }
    public static func derSignature(_ compact: Data) throws -> Data {
        guard compact.count == 64 else { throw LightningError.invalidSignature }
        return try P256K.Signing.ECDSASignature(compactRepresentation: compact).derRepresentation
    }

    public static func verify(signature: Data, digest: Data, publicKey: Data) -> Bool {
        guard digest.count == 32, let key = try? point(publicKey),
              let parsed = try? P256K.Signing.ECDSASignature(derRepresentation: signature)
        else { return false }
        return key.isValidSignature(parsed, for: HashDigest(Array(digest)))
    }

    static func hash(_ data: Data) -> Data { Data(CryptoKit.SHA256.hash(data: data)) }
    static func privateKey(_ secret: Data) throws -> P256K.Signing.PrivateKey {
        guard secret.count == 32, let key = try? P256K.Signing.PrivateKey(dataRepresentation: secret)
        else { throw LightningError.invalidKey }
        return key
    }
    static func point(_ bytes: Data) throws -> P256K.Signing.PublicKey {
        guard bytes.count == 33, let key = try? P256K.Signing.PublicKey(dataRepresentation: bytes, format: .compressed)
        else { throw LightningError.invalidKey }
        return key
    }
}
