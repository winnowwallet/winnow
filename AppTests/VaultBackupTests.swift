@testable import WinnowApp
import WalletCore
import TestSupport
import XCTest

final class VaultBackupTests: XCTestCase {
    func testBackupPreservesAccountsAndRejectsChangedOwnership() async throws {
        let keys = InMemoryStoreKeyVault()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "vaults.json")
        let (vault, _) = try TestVaults.muSig2Vault()
        let descriptor = vault.descriptor.serialized()
        let coin = try TestVaults.funding(vault: vault, amount: 80_000)
        let record = VaultRecord(id: String(descriptor.split(separator: "#").last!),
                                 name: "Phone and desktop", descriptor: descriptor,
                                 createdAtHeight: 0, nextReceiveIndex: 1, allUtxos: [coin])
        let store = VaultStore(keys: keys)
        await store.configure(storageURL: url, network: .signet)
        try await store.restore([record])
        var backup = ImportBundle(network: "signet", lastKnownHeight: coin.height)
        backup.vaults = try await store.backupRecords()
        let decoded = try ImportBundle.decode(json: backup.serialized())
        XCTAssertEqual(decoded.vaults, [record])
        XCTAssertNil(decoded.mnemonic)
        let restarted = VaultStore(keys: keys)
        let opened = await restarted.configure(storageURL: url, network: .signet)
        XCTAssertEqual(opened, .loaded)
        let loaded = await restarted.all
        XCTAssertEqual(loaded, decoded.vaults)

        var changed = record
        changed.allUtxos[0].scriptPubKey = Data([0x51])
        do {
            try await restarted.restore([changed])
            XCTFail("backup with a foreign coin was accepted")
        } catch {}
        let unchanged = await restarted.all
        XCTAssertEqual(unchanged, [record])
        XCTAssertEqual(try JSONDecoder().decode([VaultRecord].self, from: unsealedPayload(of: url)), [record])
    }

    func testBackupWaitsForPendingAccountPayments() async throws {
        let keys = InMemoryStoreKeyVault()
        let (vault, _) = try TestVaults.muSig2Vault()
        let text = vault.descriptor.serialized()
        var coin = try TestVaults.funding(vault: vault, amount: 80_000)
        coin.height = 0
        let record = VaultRecord(id: String(text.split(separator: "#").last!), name: "Pending",
                                 descriptor: text, createdAtHeight: 0,
                                 nextReceiveIndex: 1, allUtxos: [coin])
        let store = VaultStore(keys: keys)
        await store.configure(storageURL: nil, network: .signet)
        try await store.restore([record])
        do {
            _ = try await store.backupRecords()
            XCTFail("an unconfirmed account snapshot was exported")
        } catch {}
    }

    /// A reorg below a vault's coins undoes exactly what the orphaned blocks
    /// did: coins they paid disappear, spends they confirmed are released, and
    /// the rewound set is what a restarted store opens. A write that fails
    /// leaves the store as it was.
    func testRollbackUndoesOnlyWhatTheOrphanedBlocksDid() async throws {
        let keys = InMemoryStoreKeyVault()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "vaults.json")
        let (vault, _) = try TestVaults.muSig2Vault()
        let text = vault.descriptor.serialized()
        var kept = try TestVaults.funding(vault: vault, amount: 80_000)
        kept.height = 10
        kept.spent = .init(spentBy: Data(repeating: 0xCC, count: 32), height: 25)
        var orphaned = try TestVaults.funding(vault: vault, amount: 30_000)
        orphaned.txid = Data(repeating: 0xDD, count: 32)
        orphaned.height = 20
        let record = VaultRecord(id: String(text.split(separator: "#").last!), name: "Reorg",
                                 descriptor: text, createdAtHeight: 0, nextReceiveIndex: 1,
                                 allUtxos: [kept, orphaned])
        let store = VaultStore(keys: keys)
        await store.configure(storageURL: url, network: .signet)
        try await store.restore([record])

        try await store.rollBack(to: 30)
        let untouched = await store.all
        XCTAssertEqual(untouched, [record], "nothing above height 30 to undo")

        let failing = VaultStore(keys: keys) { _, _ in throw CocoaError(.fileWriteNoPermission) }
        await failing.configure(storageURL: url, network: .signet)
        do {
            try await failing.rollBack(to: 15)
            XCTFail("a rollback that could not be saved was reported as done")
        } catch {}
        let unsaved = await failing.all
        XCTAssertEqual(unsaved, [record], "a failed write keeps the previous set")

        try await store.rollBack(to: 15)
        var expected = kept
        expected.spent = nil
        let rewound = await store.all
        XCTAssertEqual(rewound.first?.allUtxos, [expected])
        let restarted = VaultStore(keys: keys)
        _ = await restarted.configure(storageURL: url, network: .signet)
        let reopened = await restarted.all
        XCTAssertEqual(reopened, rewound)
    }
}
