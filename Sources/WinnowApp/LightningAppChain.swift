import Foundation
import LightningCore
import WalletCore

extension AppModel {
    /// One verified filter scan applies both wallet matches and channel
    /// observations. No separate Bitcoin node, RPC wallet or chain model.
    func syncWalletAndLightning(filters: FilterSync, scripts: [Data],
                                onReorg: @escaping @Sendable (UInt32) async throws -> Void,
                                onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        if backgroundRunning, lightning != nil {
            return try await syncLightningInBackground(filters: filters, scripts: scripts, onReorg: onReorg, onMatch: onMatch)
        }
        guard let lightning else {
            return try await syncBitcoinWallet(filters: filters, scripts: scripts, onReorg: onReorg, onMatch: onMatch)
        }
        return try await syncLightningInForeground(lightning, filters: filters, scripts: scripts, onReorg: onReorg, onMatch: onMatch)
    }
    private func syncLightningInBackground(filters: FilterSync, scripts: [Data],
                                           onReorg: @escaping @Sendable (UInt32) async throws -> Void,
                                           onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        guard let monitor = backgroundMonitor, let stack else { throw AppError.noStack }
        let driver = LightningChainDriver(monitor: monitor, headers: stack.chain)
        let complete = try await driver.sync(using: filters, walletScripts: scripts, maxBlocks: 2_000,
            onEvent: { events in try await relayBackgroundRecovery(events, broadcaster: stack.broadcaster) },
            onReorg: onReorg, onMatch: onMatch)
        let protected = await monitor.isComplete()
        return complete && protected
    }
    private func syncBitcoinWallet(filters: FilterSync, scripts: [Data],
                                    onReorg: @escaping @Sendable (UInt32) async throws -> Void,
                                    onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        try await filters.sync(watchScripts: scripts, maxBlocks: backgroundRunning ? 2_000 : nil,
                               onReorg: onReorg, onMatch: onMatch)
        return await filters.nextScanHeight > filters.chain.height
    }
    private func syncLightningInForeground(_ lightning: LightningAppController, filters: FilterSync, scripts: [Data],
                                           onReorg: @escaping @Sendable (UInt32) async throws -> Void,
                                           onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        let generation = lightning.generation
        guard let driver = lightning.driver else { throw AppError.noStack }
        let complete = try await driver.sync(using: filters, walletScripts: scripts, onEvent: { [weak self] events in
            guard let self else { throw CancellationError() }
            try await lightning.requireNetwork(self, generation: generation)
            try await lightning.handle(events, model: self)
        }, onReorg: onReorg, onMatch: onMatch)
        try await finishLightningScan(complete: complete, controller: lightning, generation: generation)
        return complete
    }
    private func finishLightningScan(complete: Bool, controller: LightningAppController, generation: UInt64) async throws {
        try controller.requireNetwork(self, generation: generation)
        if complete { await controller.resume(model: self) }
    }
}

/// Announcing inv is not the same as serving the signed transaction. Retain
/// the connection for a bounded getdata exchange; expiry cancels this wait.
func relayBackgroundRecovery(_ events: [LightningEngine.Event], broadcaster: TxBroadcaster,
                             timeout: Duration = .seconds(8)) async throws {
    var pending = try await announceRecoveryTransactions(events, broadcaster: broadcaster)
    let deadline = ContinuousClock.now + timeout
    while !pending.isEmpty {
        try Task.checkCancellation()
        for txid in pending where await broadcaster.wasServed(txid) { pending.remove(txid) }
        if pending.isEmpty { return }
        guard ContinuousClock.now < deadline else { throw BackgroundRelayError.notServed }
        try await Task.sleep(for: .milliseconds(50))
    }
}
func announceRecoveryTransactions(_ events: [LightningEngine.Event], broadcaster: TxBroadcaster) async throws -> Set<Data> {
    let transactions = try events.map { event -> (raw: Data, transaction: Transaction) in
        switch event {
        case .broadcastClose(_, let raw), .broadcastRecovery(_, let raw): return (raw, try Transaction.decode(raw))
        default: throw LightningError.invalidState
        }
    }
    var pending = Set<Data>()
    for parent in transactions {
        try Task.checkCancellation()
        guard !pending.contains(parent.transaction.txid) else { continue }
        if let child = transactions.first(where: { $0.transaction.inputs.first?.previousOutput.txid == parent.transaction.txid }) {
            pending.formUnion(try await broadcaster.broadcastPackage(parent: parent.raw, child: child.raw))
        } else {
            pending.insert(try await broadcaster.broadcast(parent.raw))
        }
    }
    return pending
}
private enum BackgroundRelayError: LocalizedError {
    case notServed
    var errorDescription: String? {
        "Recovery transactions are saved but no peer has requested them yet. Open Winnow to finish relaying."
    }
}
