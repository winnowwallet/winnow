import Foundation
import NativeSecp256k1

/// BIP340 tagged hash, delegated to the native secp256k1 module (CryptoKit SHA-256).
public enum TaggedHash {
    public static func hash(_ tag: String, _ message: Data) -> Data {
        TaggedSHA256.hash(tag: tag, message: message)
    }
}
