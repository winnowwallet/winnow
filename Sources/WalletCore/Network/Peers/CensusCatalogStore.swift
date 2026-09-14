import CryptoKit
import Foundation

/// Stores original, validated source bytes atomically. Expiration changes which
/// candidates are used; it does not erase the last download or any active peers.
public struct CensusCatalogStore: Sendable {
    public struct Download: Sendable {
        public let catalog: CensusCatalog
        public let sha256: String
    }
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load(now: Date = Date()) -> Download? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: CensusCatalog.maximumBytes + 1),
              let catalog = try? CensusCatalog.decode(data, now: now) else { return nil }
        return Download(catalog: catalog, sha256: Self.hash(data))
    }
    @discardableResult
    public func replace(with data: Data, now: Date = Date()) throws -> Download {
        let catalog = try CensusCatalog.decode(data, now: now)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return Download(catalog: catalog, sha256: Self.hash(data))
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
