import Foundation

/// A consumer's current watches and an opaque revision it can recheck when
/// accepting the scan result. A changed revision can reject a stale result
/// without allowing the shared scanner to advance its saved frontier.
public struct FilterWatchSet: Sendable {
    public let scripts: [Data]
    public let revision: UInt64
    public init(scripts: [Data], revision: UInt64) { self.scripts = scripts; self.revision = revision }
}

/// A verified filter has been processed for this header. A full block is
/// present if either the ordinary wallet or the additional consumer matched.
public struct FilterScannedBlock: Sendable {
    public let height: UInt32
    public let header: BlockHeader
    public let block: Block?
    public let watchRevision: UInt64
    // Package-only construction also lets the host reference fixture replay
    // complete blocks independently validated by Bitcoin Core. Applications
    // obtain observations from FilterSync, never from an untrusted RPC tip.
    package init(height: UInt32, header: BlockHeader, block: Block?, watchRevision: UInt64) {
        self.height = height; self.header = header; self.block = block; self.watchRevision = watchRevision
    }
}

/// Optional consumers share the ordinary peer pool and filter verification.
/// Watches are refreshed between blocks, and callbacks run in chain order.
/// The consumer owns its durable cursor and requests historical catch-up by
/// rewinding FilterSync before a run; it must not equate the header tip with
/// completion of its own scan. Callback failures leave batch progress behind.
public struct FilterScanObserver: Sendable {
    public let watches: @Sendable () async throws -> FilterWatchSet
    public let scanned: @Sendable (FilterScannedBlock) async throws -> Void
    public init(watches: @escaping @Sendable () async throws -> FilterWatchSet,
                scanned: @escaping @Sendable (FilterScannedBlock) async throws -> Void) {
        self.watches = watches
        self.scanned = scanned
    }
}
