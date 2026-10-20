import CryptoKit
import Foundation

/// The domain-separated SHA-256 construction defined by BIP340.
public enum TaggedSHA256 {
    /// Returns SHA256(SHA256(tag) || SHA256(tag) || message).
    ///
    /// The tag is encoded as UTF-8 without normalization or a terminator.
    /// Empty tags and messages are supported. The result contains 32 bytes.
    public static func hash(tag: String, message: Data) -> Data {
        let tagDigest = Data(SHA256.hash(data: Data(tag.utf8)))
        var hasher = SHA256()
        hasher.update(data: tagDigest)
        hasher.update(data: tagDigest)
        hasher.update(data: message)
        return Data(hasher.finalize())
    }
}
