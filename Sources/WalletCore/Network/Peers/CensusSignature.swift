import CryptoKit
import Foundation

/// The census publisher's signature over `peers.json`: served next to it as
/// `peers.json.sig` and committed beside it in the census repository.
///
/// Ed25519 over a domain tag and the file's exact bytes. The wallet's manual
/// refresh and the release generator verify it against the keys compiled into
/// `CensusPublisher`; the census tool signs with the matching secret. Missing
/// signatures and empty trust configurations are refused.
public struct CensusSignature: Codable, Equatable, Sendable {
    public static let algorithm = "ed25519"
    public static let maximumBytes = 1_024
    static let domain = Data("winnow-census-peers-v1\u{0}".utf8)

    public var algorithm: String
    /// The signer's public key, 32 bytes hex — in the file, so a rotation is
    /// visible where it happened.
    public var publicKey: String
    /// 64 bytes hex.
    public var signature: String

    public enum Invalid: String, Error, LocalizedError, Equatable {
        case malformed, unknownKey, signature, missing
        public var errorDescription: String? {
            switch self {
            case .malformed: "The census signature is malformed."
            case .unknownKey: "The census was signed with a key this wallet does not trust."
            case .signature: "The census signature does not match the downloaded list."
            case .missing: "The census is not signed, and this wallet requires a signature."
            }
        }
    }

    /// Where the signature is served: the list's URL with `.sig` appended.
    public static func endpoint(for catalog: URL) -> URL {
        catalog.appendingPathExtension("sig")
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.algorithm == algorithm,
              Data(hex: decoded.publicKey)?.count == 32,
              Data(hex: decoded.signature)?.count == 64
        else { throw Invalid.malformed }
        return decoded
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    public static func sign(_ payload: Data, with key: Curve25519.Signing.PrivateKey) throws -> Self {
        Self(algorithm: algorithm,
             publicKey: key.publicKey.rawRepresentation.hex,
             signature: try key.signature(for: domain + payload).hex)
    }

    /// Verifies `payload` under whichever of `trusted` signed it.
    public func verify(_ payload: Data, trusting trusted: [Curve25519.Signing.PublicKey]) throws {
        guard let keyBytes = Data(hex: publicKey), let signatureBytes = Data(hex: signature) else {
            throw Invalid.malformed
        }
        guard let key = trusted.first(where: { $0.rawRepresentation == keyBytes }) else {
            throw Invalid.unknownKey
        }
        guard key.isValidSignature(signatureBytes, for: Self.domain + payload) else {
            throw Invalid.signature
        }
    }
}

/// The keys the wallet trusts to have published the census.
public enum CensusPublisher {
    /// The publisher key established on 2026-09-18. Rotation requires shipping
    /// the replacement key before the publisher switches (docs/census-signing.md).
    public static let trustedKeysHex: [String] = [
        "b999d0881c236f3f38dce334bd373c75b936677bbed952685745486131d32b74"
    ]

    public static var trustedKeys: [Curve25519.Signing.PublicKey] {
        trustedKeysHex.compactMap { Data(hex: $0) }
            .compactMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    /// Requires a signature from an explicitly trusted publisher.
    public static func verify(_ payload: Data, signature: Data?,
                              trusting keys: [Curve25519.Signing.PublicKey]) throws {
        guard !keys.isEmpty else { throw CensusSignature.Invalid.unknownKey }
        guard let signature else { throw CensusSignature.Invalid.missing }
        try CensusSignature.decode(signature).verify(payload, trusting: keys)
    }
}
