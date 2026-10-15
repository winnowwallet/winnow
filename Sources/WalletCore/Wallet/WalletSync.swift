import Foundation

/// One filter pass shared by wallet applications. The caller owns the peers,
/// scheduling, cancellation, and any additional stores such as shared vaults.
public enum WalletSync {
    /// Applies matched blocks to the wallet and keeps pending broadcasts in
    /// step with confirmations and reorganizations. Additional scripts are
    /// scanned in the same pass, with `onMatch` applying their effects.
    ///
    /// Reorganization order is `beforeReorg`, wallet rollback, `onReorg`, then
    /// broadcast rollback. A caller with independently persisted stores can
    /// record its recovery intent first and rewind its additional stores in
    /// `onReorg`. It clears that intent only after this call succeeds.
    ///
    /// Returns the next block to scan. On failure or cancellation, verified
    /// filter progress is saved to the wallet on a best-effort basis without
    /// replacing the original error. Rejected concurrent passes and failed
    /// rollbacks or filter writes do not copy a possibly stale frontier.
    @discardableResult
    public static func run(
        wallet: Wallet,
        filters: FilterSync,
        broadcaster: TxBroadcaster,
        additionalScripts: [Data] = [],
        maxBlocks: UInt32? = nil,
        beforeReorg: (@Sendable (UInt32) async throws -> Void)? = nil,
        onReorg: (@Sendable (UInt32) async throws -> Void)? = nil,
        onMatch: (@Sendable (BlockMatch) async throws -> Void)? = nil
    ) async throws -> UInt32 {
        try Task.checkCancellation()
        do {
            let scripts = try await wallet.watchScripts() + additionalScripts
            try await filters.sync(watchScripts: scripts, maxBlocks: maxBlocks,
                                   onReorg: { height in
                try await rollBack(to: height, wallet: wallet, broadcaster: broadcaster,
                                   beforeReorg: beforeReorg, onReorg: onReorg)
            }) { match in
                try await apply(match, wallet: wallet, broadcaster: broadcaster, onMatch: onMatch)
            }
            // A rollback-only pass can return without delivering a match.
            // Finish its rewinds, but do not report a cancelled run as complete.
            try Task.checkCancellation()
            let frontier = await filters.nextScanHeight
            try await wallet.recordScanHeight(frontier)
            try await broadcaster.pruneConfirmed(scannedTo: frontier)
            return frontier
        } catch let failure as RollbackFailure {
            // FilterSync has not rewound its frontier yet. Copying it here
            // would undo the wallet rollback when an additional store failed.
            throw failure.underlying
        } catch {
            if (error as? FilterSyncError) != .busy,
               (error as? FilterSyncStorageError) != .writeFailed {
                try? await wallet.recordScanHeight(await filters.nextScanHeight)
            }
            throw error
        }
    }

    private struct RollbackFailure: Error {
        let underlying: any Error
    }

    private static func rollBack(
        to height: UInt32, wallet: Wallet, broadcaster: TxBroadcaster,
        beforeReorg: (@Sendable (UInt32) async throws -> Void)?,
        onReorg: (@Sendable (UInt32) async throws -> Void)?
    ) async throws {
        do {
            // Headers have already changed branch. Finish the rollback
            // bookkeeping even if cancellation arrived during header sync.
            try await beforeReorg?(height)
            try await wallet.rollBack(to: height)
            try await onReorg?(height)
            try await broadcaster.rollBack(to: height)
        } catch {
            throw RollbackFailure(underlying: error)
        }
    }

    private static func apply(
        _ match: BlockMatch, wallet: Wallet, broadcaster: TxBroadcaster,
        onMatch: (@Sendable (BlockMatch) async throws -> Void)?
    ) async throws {
        try Task.checkCancellation()
        let effect = try await wallet.apply(match: match)
        for discarded in effect.discardedReplacements {
            try await broadcaster.cancel(discarded)
        }
        try await onMatch?(match)
        // The final hook may cancel without throwing; there need not be
        // another match to observe it before FilterSync commits the batch.
        try Task.checkCancellation()
        let pending = await broadcaster.pendingTxids
        for transaction in match.block.transactions where pending.contains(transaction.txid) {
            try await broadcaster.markConfirmed(transaction.txid, atHeight: match.height)
        }
    }
}
