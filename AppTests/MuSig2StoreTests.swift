@testable import WinnowApp
import TestSupport
import WalletCore
import XCTest

/// The MuSig2 account store: sealed persistence, backups, and the coin
/// bookkeeping the combined filter scan drives (payments, spends, reorgs).
final class MuSig2StoreTests: XCTestCase {
    private func account() throws -> MuSig2Account {
        let keys = try TestKeys.masters().prefix(2).map { try TestKeys.bareKeyExpression(master: $0) }
        return try MuSig2Account("tr(musig(\(keys.joined(separator: ",")))/<0;1>/*)", network: .signet)
    }

    private func coin(_ account: MuSig2Account, amount: Int64, height: UInt32 = 100) throws -> WalletUTXO {
        try WalletUTXO(txid: Data(repeating: 0x5A, count: 32), vout: 0, amount: amount,
                       scriptPubKey: account.scriptPubKey(index: 0), chain: .receive, index: 0, height: height)
    }

    private func record(_ account: MuSig2Account, coins: [WalletUTXO]) -> MuSig2AccountRecord {
        MuSig2AccountRecord(id: account.id, name: "Phone and desktop", descriptor: account.descriptor.serialized(),
                            createdAtHeight: 0, nextReceiveIndex: 1, allUtxos: coins)
    }

    private func fetch(_ store: MuSig2Store, _ id: String) async throws -> MuSig2AccountRecord {
        let record = await store.record(id: id)
        return try XCTUnwrap(record)
    }

    /// A block whose first transaction is a coinbase paying no one we watch.
    private func block(at height: UInt32, _ transactions: [Transaction]) -> BlockMatch {
        let coinbase = Transaction(version: 1, inputs: [coinbaseInput()],
                                   outputs: [.init(value: 50, scriptPubKey: Data([0x51]))], locktime: height)
        return fakeMatch(height: height, transactions: [coinbase] + transactions)
    }

    private func payment(to script: Data, amount: Int64, from outpoint: Transaction.Outpoint,
                         change: Transaction.Output? = nil) -> Transaction {
        Transaction(version: 2, inputs: [.init(previousOutput: outpoint, scriptSig: Data(), sequence: 0xFFFF_FFFD)],
                    outputs: [.init(value: amount, scriptPubKey: script)] + (change.map { [$0] } ?? []), locktime: 0)
    }

    func testBackupPreservesAccountsAndRejectsChangedOwnership() async throws {
        let keys = InMemoryStoreKeyVault()
        let url = tempFileURL("musig2.json")
        let account = try account()
        let record = record(account, coins: [try coin(account, amount: 80_000)])
        let store = MuSig2Store(keys: keys)
        await store.configure(storageURL: url, network: .signet)
        try await store.restore([record])
        var backup = ImportBundle(network: "signet", lastKnownHeight: 100)
        backup.vaults = try await store.backupRecords()
        let decoded = try ImportBundle.decode(json: backup.serialized())
        XCTAssertEqual(decoded.vaults, [record])

        let restarted = MuSig2Store(keys: keys)
        let opened = await restarted.configure(storageURL: url, network: .signet)
        XCTAssertEqual(opened, .loaded)
        let loaded = await restarted.all
        XCTAssertEqual(loaded, [record])

        var changed = record
        changed.allUtxos[0].scriptPubKey = Data([0x51])
        do {
            try await restarted.restore([changed])
            XCTFail("a backup with a foreign coin was accepted")
        } catch {}
        let unchanged = await restarted.all
        XCTAssertEqual(unchanged, [record])
        XCTAssertEqual(try JSONDecoder().decode([MuSig2AccountRecord].self, from: unsealedPayload(of: url)), [record])
    }

    func testBackupWaitsForPendingAccountPayments() async throws {
        let account = try account()
        let store = MuSig2Store(keys: InMemoryStoreKeyVault())
        await store.configure(storageURL: nil, network: .signet)
        try await store.restore([record(account, coins: [try coin(account, amount: 80_000, height: 0)])])
        do {
            _ = try await store.backupRecords()
            XCTFail("an unconfirmed account snapshot was exported")
        } catch {}
    }

    /// Payments arrive, a spend goes out with change, a reorg drops a block:
    /// the same rules `Wallet` applies to its own coins.
    func testPaymentsSpendsAndRollbacks() async throws {
        let keys = InMemoryStoreKeyVault()
        let url = tempFileURL("musig2.json")
        let account = try account()
        let store = MuSig2Store(keys: keys)
        await store.configure(storageURL: url, network: .signet)
        let added = try await store.add(name: "Shared", account: account, createdAtHeight: 100)
        let initialScripts = try await store.watchScripts(network: .signet)
        XCTAssertEqual(initialScripts.count, 6, "receive and change for indices 0, 1 and 2")

        let funding = payment(to: try account.scriptPubKey(index: 0), amount: 60_000,
                              from: .init(txid: Data(repeating: 0x11, count: 32), vout: 0))
        try await store.apply(match: block(at: 101, [funding]), network: .signet)
        let later = payment(to: try account.scriptPubKey(index: 2), amount: 7_000,
                            from: .init(txid: Data(repeating: 0x12, count: 32), vout: 0))
        try await store.apply(match: block(at: 102, [later]), network: .signet)
        var current = try await fetch(store, added.id)
        XCTAssertEqual(current.balance, 67_000)
        XCTAssertEqual(current.nextReceiveIndex, 3, "a payment at index 2 moves the frontier past it")
        XCTAssertFalse(current.utxos.contains { $0.isCoinbase })

        // Our own spend, recorded at broadcast: the input is reserved and the
        // change waits at height 0.
        let changeScript = try account.scriptPubKey(index: 0, choice: AddressChain.change.rawValue)
        let spend = payment(to: Data([0x51, 0x20] + repeatElement(0x77, count: 32)), amount: 40_000,
                            from: .init(txid: funding.txid, vout: 0),
                            change: .init(value: 19_000, scriptPubKey: changeScript))
        let recorded = try await store.recordSpend(id: added.id, transaction: spend, changeIndex: 0)
        XCTAssertTrue(recorded)
        let repeated = try await store.recordSpend(id: added.id, transaction: spend, changeIndex: 0)
        XCTAssertFalse(repeated, "a repeated relay changes nothing")
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.balance, 26_000)
        XCTAssertEqual(current.nextChangeIndex, 1)
        let backupWhilePending = try? await store.backupRecords()
        XCTAssertNil(backupWhilePending)

        // A reorg below the later payment drops it, and keeps the in-flight
        // spend's input reserved.
        try await store.rollBack(to: 101)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.balance, 19_000)
        XCTAssertEqual(current.nextReceiveIndex, 3, "a reorg never costs an address gap")

        // The spend confirms; a reorg below it undoes it.
        try await store.apply(match: block(at: 103, [spend]), network: .signet)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.allUtxos.first { $0.txid == funding.txid }?.spent?.height, 103)
        XCTAssertEqual(current.utxos.first { $0.txid == spend.txid }?.height, 103)
        let confirmedBackup = try? await store.backupRecords()
        XCTAssertNotNil(confirmedBackup, "a confirmed spend can be backed up")
        try await store.rollBack(to: 102)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.balance, 60_000)

        let restarted = MuSig2Store(keys: keys)
        await restarted.configure(storageURL: url, network: .signet)
        let reloaded = await restarted.all
        XCTAssertEqual(reloaded, [current])
    }

    func testTamperedUnsealedAndOversizedFilesAreRefusedAndKept() async throws {
        let keys = InMemoryStoreKeyVault()
        let url = tempFileURL("musig2.json")
        let account = try account()
        let store = MuSig2Store(keys: keys)
        await store.configure(storageURL: url, network: .signet)
        try await store.add(name: "Shared", account: account, createdAtHeight: 100)
        XCTAssertTrue(SealedStoreFile.isSealed(try Data(contentsOf: url)))
        XCTAssertNotNil(try keys.key(for: "musig2.signet"))

        // One payload byte changed: the seal refuses it, and nothing is written.
        var bytes = try Data(contentsOf: url)
        let index = try XCTUnwrap(bytes.lastIndex(of: UInt8(ascii: "S")))
        bytes[index] = UInt8(ascii: "T")
        try bytes.write(to: url)
        let tampered = MuSig2Store(keys: keys)
        guard case .damaged = await tampered.configure(storageURL: url, network: .signet) else {
            return XCTFail("a tampered account file was read")
        }
        do {
            try await tampered.add(name: "Other", account: account, createdAtHeight: 1)
            XCTFail("a damaged store accepted a change")
        } catch MuSig2StorageError.damaged {}
        XCTAssertEqual(try Data(contentsOf: url), bytes, "the damaged file is left as it was")

        // A well-formed but unsealed file, on a phone that never sealed one.
        let planted = tempFileURL("musig2.json")
        try JSONEncoder().encode([record(account, coins: [])]).write(to: planted)
        let fresh = MuSig2Store(keys: InMemoryStoreKeyVault())
        guard case .damaged = await fresh.configure(storageURL: planted, network: .signet) else {
            return XCTFail("an unsealed account file was adopted")
        }

        let oversized = tempFileURL("musig2.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(MuSig2Store.maximumFileBytes + 1))
        try handle.close()
        guard case .damaged = await MuSig2Store(keys: keys).configure(storageURL: oversized, network: .signet) else {
            return XCTFail("an oversized account file was read")
        }
    }

    func testDuplicateWrongNetworkAndBadNamesAreRefused() async throws {
        let account = try account()
        let store = MuSig2Store(keys: InMemoryStoreKeyVault())
        await store.configure(storageURL: tempFileURL("musig2.json"), network: .signet)
        try await store.add(name: "Shared", account: account, createdAtHeight: 1)
        do {
            try await store.add(name: "Again", account: account, createdAtHeight: 1)
            XCTFail("the same account was added twice")
        } catch MuSig2StorageError.duplicate {}
        let regtest = try MuSig2Account(descriptor: account.descriptor, network: .regtest)
        do {
            try await store.add(name: "Regtest", account: regtest, createdAtHeight: 1)
            XCTFail("another network's account was added")
        } catch MuSig2StorageError.invalidState {}
        for name in ["", "two\nlines", String(repeating: "x", count: DisplayName.maximumLength + 1)] {
            let store = MuSig2Store(keys: InMemoryStoreKeyVault())
            await store.configure(storageURL: nil, network: .signet)
            do {
                try await store.add(name: name, account: account, createdAtHeight: 1)
                XCTFail("an unusable name was accepted")
            } catch MuSig2StorageError.invalidState {}
        }
        let all = await store.all
        XCTAssertEqual(all.count, 1)
    }
}
