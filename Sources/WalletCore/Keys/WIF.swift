import Foundation
import P256K

public enum WIFError: Error, Equatable {
    /// Not Base58Check, or a payload that is not 33 or 34 bytes.
    case invalidEncoding
    /// A version byte that is neither mainnet's 0x80 nor the test networks' 0xEF.
    case invalidVersion(UInt8)
    /// A 34-byte payload whose last byte is not the 0x01 compression marker.
    case invalidCompressionMarker
    /// The 32 bytes are not a secp256k1 secret: zero, or at least the group order.
    case invalidSecret
    /// The key names a network other than the one the caller expects.
    case wrongNetwork(expected: HDKey.Network, found: HDKey.Network)
}

/// A single private key in wallet import format: Base58Check over a version
/// byte, the 32-byte secret and, when the key's address uses the compressed
/// public key, a trailing 0x01. Mainnet is 0x80; testnet, signet and regtest
/// share 0xEF, so a WIF can say "a test network" and no more than that.
public struct WIF: Sendable, Equatable {
    public static let mainnetVersion: UInt8 = 0x80
    public static let testnetVersion: UInt8 = 0xEF

    public let secret: Data
    public let compressed: Bool
    public let network: HDKey.Network
    /// The public key in the form the flag names: 33 bytes compressed, 65 uncompressed.
    public let publicKey: Data

    /// Wraps a secret, refusing one outside [1, n-1].
    public init(secret: Data, compressed: Bool, network: HDKey.Network) throws {
        guard secret.count == 32,
              let key = try? P256K.Signing.PrivateKey(dataRepresentation: secret,
                                                      format: compressed ? .compressed : .uncompressed)
        else { throw WIFError.invalidSecret }
        self.secret = secret
        self.compressed = compressed
        self.network = network
        publicKey = key.publicKey.dataRepresentation
    }

    /// Decodes a WIF string.
    public init(_ string: String) throws {
        guard let payload = try? Base58Check.decode(string), payload.count == 33 || payload.count == 34,
              let versionByte = payload.first
        else { throw WIFError.invalidEncoding }
        let network: HDKey.Network
        switch versionByte {
        case Self.mainnetVersion: network = .mainnet
        case Self.testnetVersion: network = .testnet
        default: throw WIFError.invalidVersion(versionByte)
        }
        let compressed = payload.count == 34
        if compressed, payload.last != 0x01 { throw WIFError.invalidCompressionMarker }
        try self.init(secret: Data(payload.dropFirst().prefix(32)), compressed: compressed, network: network)
    }

    /// Decodes a WIF string and refuses one from another network, so a test
    /// key never reaches a mainnet spend by way of a shared code path.
    public init(_ string: String, network expected: HDKey.Network) throws {
        try self.init(string)
        guard network == expected else { throw WIFError.wrongNetwork(expected: expected, found: network) }
    }

    /// The Base58Check string.
    public var serialized: String {
        var payload = Data([network == .mainnet ? Self.mainnetVersion : Self.testnetVersion])
        payload.append(secret)
        if compressed { payload.append(0x01) }
        return Base58Check.encode(payload)
    }
}
