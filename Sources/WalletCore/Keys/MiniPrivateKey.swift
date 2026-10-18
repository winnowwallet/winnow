import CryptoKit
import Foundation

public enum MiniPrivateKeyError: Error, Equatable {
    /// Not 22 or 30 characters, or not starting with `S`.
    case invalidLength
    /// A character outside the base58 alphabet.
    case invalidCharacter
    /// SHA256 of the text followed by `?` does not start with a zero byte: a
    /// typo, or not a mini key at all.
    case checkFailed
    /// SHA256 of the text is not a secp256k1 secret, which a real key never is.
    case invalidSecret
}

/// The mini private key printed inside physical coins: 22 or 30 base58
/// characters starting with `S`. The secret is SHA256 of the text, and the
/// text is well formed when SHA256 of the text followed by `?` starts with a
/// zero byte, a one-in-256 typo check and nothing more. The format names no
/// network and no key form; the coins used uncompressed mainnet addresses,
/// so `wif(_:)` answers that way unless told otherwise.
public enum MiniPrivateKey {
    public static let lengths: Set<Int> = [22, 30]
    private static let alphabet = Set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    /// The 32-byte secret a well-formed mini key encodes.
    public static func secret(_ text: String) throws -> Data {
        let bytes = Array(text.utf8)
        guard lengths.contains(bytes.count), bytes.first == UInt8(ascii: "S") else {
            throw MiniPrivateKeyError.invalidLength
        }
        guard bytes.allSatisfy(alphabet.contains) else { throw MiniPrivateKeyError.invalidCharacter }
        guard Data(SHA256.hash(data: Data(bytes + [UInt8(ascii: "?")]))).first == 0 else {
            throw MiniPrivateKeyError.checkFailed
        }
        return Data(SHA256.hash(data: Data(bytes)))
    }

    /// The same secret as a WIF, uncompressed and mainnet unless told otherwise.
    public static func wif(_ text: String, compressed: Bool = false,
                           network: HDKey.Network = .mainnet) throws -> WIF {
        do {
            return try WIF(secret: secret(text), compressed: compressed, network: network)
        } catch is WIFError {
            throw MiniPrivateKeyError.invalidSecret
        }
    }
}
