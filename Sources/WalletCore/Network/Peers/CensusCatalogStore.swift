import CryptoKit
import Foundation

/// Stores original, validated source bytes atomically. Expiration changes which
/// candidates are used; it does not erase the last download or any active peers.
///
/// A download is verified against the publisher's signature when the wallet
/// trusts any key, and refused when it is thinner than a real census; the
/// signature is kept next to the list and checked again on every load.
public struct CensusCatalogStore: Sendable {
    public struct Download: Sendable {
        public let catalog: CensusCatalog
        public let sha256: String
    }
    public let url: URL
    /// The floor applied to clearnet and Tor entries (`CensusCatalog.minimumOverlayEntries`);
    /// 0 for a fixture-sized E2E census.
    public let minimumEntries: Int

    public init(url: URL, minimumEntries: Int = CensusCatalog.minimumOverlayEntries) {
        self.url = url
        self.minimumEntries = minimumEntries
    }

    /// Where the signature of the stored list is kept.
    public var signatureURL: URL { CensusSignature.endpoint(for: url) }

    public func load(now: Date = Date(),
                     trusting keys: [Curve25519.Signing.PublicKey] = CensusPublisher.trustedKeys) -> Download? {
        guard let data = Self.read(url, upTo: CensusCatalog.maximumBytes),
              (try? CensusPublisher.verify(data, signature: Self.read(signatureURL, upTo: CensusSignature.maximumBytes),
                                           trusting: keys)) != nil,
              let catalog = try? CensusCatalog.decode(data, now: now, minimumEntries: minimumEntries)
        else { return nil }
        return Download(catalog: catalog, sha256: Self.hash(data))
    }

    @discardableResult
    public func replace(with data: Data, signature: Data? = nil,
                        trusting keys: [Curve25519.Signing.PublicKey] = CensusPublisher.trustedKeys,
                        now: Date = Date()) throws -> Download {
        try CensusPublisher.verify(data, signature: signature, trusting: keys)
        let catalog = try CensusCatalog.decode(data, now: now, minimumEntries: minimumEntries)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if let signature {
            try signature.write(to: signatureURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else {
            try? FileManager.default.removeItem(at: signatureURL)
        }
        return Download(catalog: catalog, sha256: Self.hash(data))
    }

    private static func read(_ url: URL, upTo maximum: Int) -> Data? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        return try? file.read(upToCount: maximum + 1)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
