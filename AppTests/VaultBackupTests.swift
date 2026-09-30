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

private enum VaultSpendWriteFailure: Error { case expected }
private final class VaultSpendWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    func failWrites(_ value: Bool) { lock.withLock { failing = value } }
    func write(_ data: Data, to url: URL) throws {
        if lock.withLock({ failing }) { throw VaultSpendWriteFailure.expected }
        try data.write(to: url, options: .atomic)
    }
}

extension VaultBackupTests {
    private struct SpendFixture {
        let keys: InMemoryStoreKeyVault
        let store: VaultStore
        let record: VaultRecord
        let transaction: Transaction
        let change: Data
        let url: URL
    }
    private func spendFixture(writer: VaultSpendWriter? = nil) async throws -> SpendFixture {
        let url = tempFileURL("vault-spend.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (vault, masters) = try TestVaults.multiAVault()
        let coin = try TestVaults.funding(vault: vault, amount: 80_000)
        let descriptor = vault.descriptor.serialized()
        let record = VaultRecord(id: String(descriptor.split(separator: "#").last!), name: "Shared savings",
                                 descriptor: descriptor, createdAtHeight: 90, nextReceiveIndex: 1, allUtxos: [coin])
        let change = try vault.scriptPubKey(index: 0, choice: AddressChain.change.rawValue)
        let coordinates = [Vault.OutputCoordinate(choice: AddressChain.change.rawValue, index: 0)]
        var proposal = try vault.createSpend(utxos: [coin], payments: [.init(amount: 10_000, scriptPubKey: Data([0x51, 32]) + Data(repeating: 3, count: 32))],
            changeIndex: 0, feeRateSatPerVByte: 1, chainTip: 200, randomness: { 0.5 })
        for master in masters.prefix(2) {
            try vault.partialSign(&proposal, master: master, knownUTXOs: [coin], ownedOutputCoordinates: coordinates, chainTip: 200)
        }
        let transaction = try vault.finalizeSpend(&proposal, knownUTXOs: [coin], ownedOutputCoordinates: coordinates, chainTip: 200)
        let keys = InMemoryStoreKeyVault()
        let store = VaultStore(keys: keys, writeData: { data, url in
            if let writer { try writer.write(data, to: url) }
            else { try data.write(to: url, options: .atomic) }
        })
        await store.configure(storageURL: url, network: .signet)
        try await store.restore([record])
        return SpendFixture(keys: keys, store: store, record: record, transaction: transaction, change: change, url: url)
    }
    private func confirmSpend(_ fixture: SpendFixture, height: UInt32) async throws {
        let coinbase = Transaction(version: 2,
            inputs: [.init(previousOutput: .init(txid: Data(repeating: 0, count: 32), vout: UInt32.max), scriptSig: Data([1, 2]), sequence: UInt32.max)],
            outputs: [.init(value: 50_000, scriptPubKey: Data([0x51]))], locktime: 0)
        let header = BlockHeader(version: 1, previousHash: Data(repeating: 0, count: 32), merkleRoot: fixture.transaction.txid,
                                 time: 1_600_000_000, bits: 0x207fffff, nonce: 0)
        try await fixture.store.apply(match: .init(height: height, blockHash: header.hash,
            block: .init(header: header, transactions: [coinbase, fixture.transaction])), network: .signet)
    }
    func testSignedVaultSpendPersistsOnceAndPendingInputsStayReservedAcrossRollback() async throws {
        let fixture = try await spendFixture()
        let recorded = try await fixture.store.recordSpend(id: fixture.record.id, transaction: fixture.transaction,
                                                           changeScriptPubKey: fixture.change, changeIndex: 0)
        XCTAssertTrue(recorded)
        let savedSpend = await fixture.store.record(id: fixture.record.id)
        let afterSpend = try XCTUnwrap(savedSpend)
        XCTAssertEqual(afterSpend.allUtxos.first?.spent?.spentBy, fixture.transaction.txid)
        XCTAssertNil(afterSpend.allUtxos.first?.spent?.height)
        XCTAssertEqual(afterSpend.utxos.count, 1)
        XCTAssertEqual(afterSpend.utxos.first?.scriptPubKey, fixture.change)
        XCTAssertEqual(afterSpend.nextChangeIndex, 1)
        let duplicate = try await fixture.store.recordSpend(id: fixture.record.id, transaction: fixture.transaction,
                                                            changeScriptPubKey: fixture.change, changeIndex: 0)
        XCTAssertFalse(duplicate)
        try await fixture.store.rollBack(to: 150)
        let afterRollback = await fixture.store.all
        XCTAssertEqual(afterRollback, [afterSpend], "unconfirmed spends cannot release their reserved inputs")
        let restarted = VaultStore(keys: fixture.keys)
        let opened = await restarted.configure(storageURL: fixture.url, network: .signet)
        XCTAssertEqual(opened, .loaded)
        let persisted = await restarted.all
        XCTAssertEqual(persisted, [afterSpend])
        do { _ = try await restarted.backupRecords(); XCTFail("pending spend was exported") } catch {}
    }
    func testConfirmedVaultSpendReorgRestoresFundingAndRetainsAddressCursor() async throws {
        let fixture = try await spendFixture()
        _ = try await fixture.store.recordSpend(id: fixture.record.id, transaction: fixture.transaction,
                                               changeScriptPubKey: fixture.change, changeIndex: 0)
        try await confirmSpend(fixture, height: 200)
        let confirmed = try await fixture.store.backupRecords()
        XCTAssertEqual(confirmed.first?.allUtxos.first?.spent?.height, 200)
        XCTAssertEqual(confirmed.first?.utxos.first?.height, 200)
        try await fixture.store.rollBack(to: 150)
        let savedRewind = await fixture.store.record(id: fixture.record.id)
        let rewound = try XCTUnwrap(savedRewind)
        XCTAssertEqual(rewound.utxos, fixture.record.utxos)
        XCTAssertEqual(rewound.nextChangeIndex, 1)
        XCTAssertEqual(rewound.createdAtHeight, fixture.record.createdAtHeight)
        let bytes = try Data(contentsOf: fixture.url)
        try await fixture.store.rollBack(to: 150)
        XCTAssertEqual(try Data(contentsOf: fixture.url), bytes, "an unchanged rollback need not rewrite sealed storage")
        try await fixture.store.rollBack(to: 99)
        let beforeFunding = await fixture.store.record(id: fixture.record.id)
        XCTAssertTrue(beforeFunding?.allUtxos.isEmpty == true)
        XCTAssertEqual(beforeFunding?.nextChangeIndex, 1)
    }
    func testVaultSpendAndReorgWriteFailuresLeaveMemoryAndSealedFileUntouched() async throws {
        let writer = VaultSpendWriter(), fixture = try await spendFixture(writer: writer)
        let originalBytes = try Data(contentsOf: fixture.url)
        writer.failWrites(true)
        do {
            _ = try await fixture.store.recordSpend(id: fixture.record.id, transaction: fixture.transaction,
                                                   changeScriptPubKey: fixture.change, changeIndex: 0)
            XCTFail("a failed durable write accepted the spend")
        } catch VaultSpendWriteFailure.expected {}
        let failedSpendState = await fixture.store.all
        XCTAssertEqual(failedSpendState, [fixture.record])
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalBytes)
        writer.failWrites(false)
        _ = try await fixture.store.recordSpend(id: fixture.record.id, transaction: fixture.transaction,
                                               changeScriptPubKey: fixture.change, changeIndex: 0)
        try await confirmSpend(fixture, height: 200)
        let confirmed = await fixture.store.all, confirmedBytes = try Data(contentsOf: fixture.url)
        writer.failWrites(true)
        do { try await fixture.store.rollBack(to: 150); XCTFail("failed write accepted the reorg") }
        catch VaultSpendWriteFailure.expected {}
        let failedRollbackState = await fixture.store.all
        XCTAssertEqual(failedRollbackState, confirmed)
        XCTAssertEqual(try Data(contentsOf: fixture.url), confirmedBytes)
    }
    func testVaultSpendRejectsForeignOrAmbiguousChangeBeforeReservingCoins() async throws {
        let fixture = try await spendFixture()
        let originalBytes = try Data(contentsOf: fixture.url)
        for (transaction, script) in [
            (fixture.transaction, Data([0x51, 32]) + Data(repeating: 9, count: 32)),
            (Transaction(version: fixture.transaction.version, inputs: fixture.transaction.inputs,
                         outputs: fixture.transaction.outputs + [.init(value: 500, scriptPubKey: fixture.change)], locktime: fixture.transaction.locktime), fixture.change)
        ] {
            do {
                _ = try await fixture.store.recordSpend(id: fixture.record.id, transaction: transaction, changeScriptPubKey: script, changeIndex: 0)
                XCTFail("invalid change reserved known vault coins")
            } catch VaultStorageError.invalidState {}
        }
        var unrelated = fixture.transaction
        unrelated.inputs[0].previousOutput.txid = Data(repeating: 8, count: 32)
        let unknown = try await fixture.store.recordSpend(id: fixture.record.id, transaction: unrelated, changeScriptPubKey: nil, changeIndex: 0)
        XCTAssertFalse(unknown)
        let missing = try await fixture.store.recordSpend(id: "missing", transaction: fixture.transaction, changeScriptPubKey: nil, changeIndex: 0)
        XCTAssertFalse(missing)
        let unchanged = await fixture.store.all
        XCTAssertEqual(unchanged, [fixture.record])
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalBytes)
    }
}

extension VaultBackupTests {
    private func missingRecoveryRecord() throws -> VaultRecord {
        let (vault, _) = try TestVaults.multiAVault(threshold: 3)
        var coin = try TestVaults.funding(vault: vault, amount: 50_000)
        coin.txid = Data(repeating: 0x66, count: 32)
        let descriptor = vault.descriptor.serialized()
        return VaultRecord(id: String(descriptor.split(separator: "#").last!), name: "Recovered account",
                           descriptor: descriptor, createdAtHeight: 70, nextReceiveIndex: 1, allUtxos: [coin])
    }
    func testInterruptedRecoveryAddsMissingVaultAndPreservesCurrentPendingSpend() async throws {
        let fixture = try await spendFixture(), missing = try missingRecoveryRecord()
        _ = try await fixture.store.recordSpend(id: fixture.record.id, transaction: fixture.transaction,
                                               changeScriptPubKey: fixture.change, changeIndex: 0)
        let current = await fixture.store.all
        try await fixture.store.mergeMissingRecoveryRecords([fixture.record, missing])
        let merged = await fixture.store.all
        XCTAssertEqual(merged, current + [missing], "old backup must not release pending coins or rewind current indices")
        let bytes = try Data(contentsOf: fixture.url)
        try await fixture.store.mergeMissingRecoveryRecords([fixture.record, missing])
        XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
        let restarted = VaultStore(keys: fixture.keys)
        let opened = await restarted.configure(storageURL: fixture.url, network: .signet)
        XCTAssertEqual(opened, .loaded)
        let persisted = await restarted.all
        XCTAssertEqual(persisted, merged)
    }
    func testRecoveryVaultMergeRejectsInvalidOwnershipDuplicateOutpointsAndFailedWrite() async throws {
        let writer = VaultSpendWriter(), fixture = try await spendFixture(writer: writer)
        let missing = try missingRecoveryRecord(), originalBytes = try Data(contentsOf: fixture.url)
        var invalid = missing; invalid.allUtxos[0].scriptPubKey = fixture.record.allUtxos[0].scriptPubKey
        do { try await fixture.store.mergeMissingRecoveryRecords([invalid]); XCTFail("foreign recovered output accepted") }
        catch VaultStorageError.invalidState {}
        var conflict = missing; conflict.allUtxos[0].txid = fixture.record.allUtxos[0].txid
        do { try await fixture.store.mergeMissingRecoveryRecords([conflict]); XCTFail("merged records repeated a funding outpoint") }
        catch VaultStorageError.invalidState {}
        writer.failWrites(true)
        do { try await fixture.store.mergeMissingRecoveryRecords([missing]); XCTFail("failed write installed recovered vault") }
        catch VaultSpendWriteFailure.expected {}
        let unchanged = await fixture.store.all
        XCTAssertEqual(unchanged, [fixture.record])
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalBytes)
    }
}
