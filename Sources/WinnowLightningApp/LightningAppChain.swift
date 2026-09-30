import Foundation
import LightningCore
import WalletCore

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
