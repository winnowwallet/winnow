import Foundation
import LightningCore
import WalletCore

extension PeerFixture {
    private struct RecoveryBlock: Decodable { let height: UInt32; let raw: String }

    /// Disposable regtest-only evidence. The test driver owns real Bitcoin Core
    /// blocks and peers. Production backups always encrypt this payload inside
    /// CloudWalletBackup; this process passes fixture secrets only through its
    /// test-driver pipe so the driver can simulate loss of the device.
    static func recoveryCommand(_ input: [String: String], engine: LightningEngine) async throws -> [String: String] {
        switch input["command"] {
        case "recovery_export":
            let backup = try await engine.recoveryBackup()
            return ["backup": try backup.encoded().base64EncodedString(), "node_id": backup.nodeID.hex,
                    "revision": String(backup.revision), "channel_count": String(backup.channelCount)]
        case "recovery_claim":
            return try await recoveryClaims(input, original: engine)
        default: throw LightningError.invalidMessage
        }
    }
    private static func recoveryClaims(_ input: [String: String], original: LightningEngine) async throws -> [String: String] {
        guard let encoded = input["backup"].flatMap({ Data(base64Encoded: $0) }),
              let directory = input["directory"], let text = input["blocks"] else { throw LightningError.invalidMessage }
        let chain = await original.chainHash(), backup = try LightningRecoveryBackup.decode(encoded, chain: chain)
        let journal = try FileLightningJournal(directory: URL(fileURLWithPath: directory), key: Data(repeating: 42, count: 32))
        let restored = try LightningEngine.restoringRecovery(backup, chain: chain, journal: journal)
        let blocks = try JSONDecoder().decode([RecoveryBlock].self, from: Data(text.utf8))
        for item in blocks {
            guard let bytes = Data(hex: item.raw) else { throw LightningError.invalidMessage }
            let block = try Block.decode(bytes), revision = await restored.currentRevision()
            _ = try await restored.scannedBlock(.init(height: item.height, header: block.header, block: block, watchRevision: revision))
        }
        try await restored.chainCaughtUp(height: blocks.last?.height ?? 0)
        let events = try await restored.pendingRecoveryBroadcasts()
        let claims = try recoveryTransactions(events)
        let channels = await restored.channels(), status = await restored.recoveryStatus()
        guard status != nil, channels.allSatisfy({ $0.signedCommitment == nil && $0.phase == .recovering }),
              try await restored.pendingCloseBroadcasts().isEmpty,
              try await restored.pendingFundingBroadcasts().isEmpty else { throw LightningError.invalidState }
        return ["claims": String(decoding: try JSONEncoder().encode(claims), as: UTF8.self),
                "status": "recovery-only", "node_id": try await restored.nodeID().hex,
                "channel_count": String(channels.count), "source_revision": String(backup.revision)]
    }
    private static func recoveryTransactions(_ events: [LightningEngine.Event]) throws -> [String] {
        try events.map { event in
            guard case .broadcastRecovery(_, let transaction) = event else { throw LightningError.invalidState }
            return transaction.hex
        }
    }
}
