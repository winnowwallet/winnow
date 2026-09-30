import Foundation
import WalletCore

/// The engine adds watch scripts to Winnow's verified scanner. It never opens
/// a second Bitcoin connection or treats a remote channel_ready as funding.
public actor LightningChainDriver {
    private let engine: any LightningChainMonitor
    private let headers: HeaderChain
    private var syncing = false
    public init(engine: LightningEngine, headers: HeaderChain) { self.engine = engine; self.headers = headers }
    public init(monitor: LightningBackgroundMonitor, headers: HeaderChain) { self.engine = monitor; self.headers = headers }

    @discardableResult
    public func sync(using filters: FilterSync, walletScripts: [Data], maxBlocks: UInt32? = nil,
                     onEvent: @escaping @Sendable ([LightningEngine.Event]) async throws -> Void,
                     onReorg: (@Sendable (UInt32) async throws -> Void)? = nil,
                     onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        guard !syncing else { throw LightningChainError.busy }
        syncing = true
        defer { syncing = false }
        await engine.chainDisconnected()
        guard await engine.chainHash() == headers.params.genesisHash else { throw LightningChainError.recoveryRequired }
        if !(await engine.hasChannels()) {
            // Use Winnow's ordinary scanner until the first channel exists.
            // Do not journal every historical block of a newly imported wallet.
            try await filters.sync(watchScripts: walletScripts, maxBlocks: maxBlocks,
                                   onReorg: onReorg, onMatch: onMatch)
            let height = await headers.height
            // Do not anchor channels to an unconfirmed tip: an ordinary short
            // reorg must remain replayable. Once channels exist this floor is
            // durable; the bounded ancestry window handles subsequent forks.
            let floor = max(await headers.startHeight, height > 144 ? height - 144 : 0)
            guard let hash = await headers.blockHash(at: floor) else { throw LightningChainError.missingHeader }
            try await engine.startChainScan(height: floor, hash: hash)
            let complete = await filters.nextScanHeight > height
            if complete { try await engine.chainCaughtUp(height: height) }
            return complete
        }
        // A cleared/rebuilt header cache may start below our journal cursor.
        // Winnow must catch it up before missing ancestry can mean a reorg.
        try await filters.syncHeaders(onReorg: onReorg)
        try await prepare(onReorg: onReorg)
        let observer = FilterScanObserver(watches: { try await self.engine.chainWatches() }, scanned: { scanned in
            guard await self.headers.blockHash(at: scanned.height) == scanned.header.hash else { throw LightningChainError.restartScan }
            // Persist historical observations without publishing financial
            // actions until every verified height has been inspected.
            _ = try await self.engine.scannedBlock(scanned)
        })
        let complete = try await scan(using: filters, walletScripts: walletScripts, maxBlocks: maxBlocks, observer: observer, onReorg: onReorg, onMatch: onMatch)
        if complete { try await onEvent(engine.pendingChainEvents()) }
        return complete
    }
    private func prepare(onReorg: (@Sendable (UInt32) async throws -> Void)?) async throws {
        await engine.chainDisconnected()
        if await engine.chainStatus().rescanRequired {
            let origin = await engine.chainStatus().origin
            guard await headers.blockHash(at: origin.height) == origin.hash else { throw LightningChainError.recoveryRequired }
            try await onReorg?(origin.height)
            try await engine.blocksDisconnected(to: origin.height, hash: origin.hash)
        }
        try await reconcileAncestry(onReorg: onReorg)
    }
    private func scan(using filters: FilterSync, walletScripts: [Data], maxBlocks: UInt32?, observer: FilterScanObserver,
                      onReorg: (@Sendable (UInt32) async throws -> Void)?,
                      onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        for _ in 0..<32 {
            let status = await engine.chainStatus()
            if await filters.nextScanHeight > status.nextHeight { try await filters.rollBack(to: status.nextHeight - 1) }
            do {
                try await filters.sync(watchScripts: walletScripts, maxBlocks: maxBlocks, observer: observer,
                    onReorg: { height in
                        try await onReorg?(height)
                        guard let hash = await self.headers.blockHash(at: height) else { throw LightningChainError.missingHeader }
                        try await self.engine.blocksDisconnected(to: height, hash: hash)
                    }, onMatch: onMatch)
            } catch LightningChainError.changedWatches { continue }
              catch LightningChainError.restartScan { continue }
            let height = await headers.height
            if await engine.chainStatus().nextHeight > height {
                try await engine.chainCaughtUp(height: height)
                return true
            }
            if maxBlocks != nil { return false }
        }
        throw LightningChainError.catchUpDidNotConverge
    }
    private func reconcileAncestry(onReorg: (@Sendable (UInt32) async throws -> Void)?) async throws {
        let status = await engine.chainStatus(), positions = status.positions
        try await validateOrigin(status.origin)
        guard let last = positions.last, await headers.blockHash(at: last.height) != last.hash else { return }
        guard let ancestor = await commonAncestor(status) else { throw LightningChainError.recoveryRequired }
        try await onReorg?(ancestor.height)
        try await engine.blocksDisconnected(to: ancestor.height, hash: ancestor.hash)
    }
    private func validateOrigin(_ origin: LightningEngine.ChainStatus.Position) async throws {
        guard await headers.blockHash(at: origin.height) == origin.hash else { throw LightningChainError.recoveryRequired }
    }
    private func commonAncestor(_ status: LightningEngine.ChainStatus) async -> LightningEngine.ChainStatus.Position? {
        let positions = status.positions
        for position in positions.reversed() where await headers.blockHash(at: position.height) == position.hash {
            return position
        }
        if positions.first?.height == status.origin.height + 1 {
            return status.origin
        }
        return nil
    }
}
