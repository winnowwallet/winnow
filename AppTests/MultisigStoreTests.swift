@testable import WinnowApp
import TestSupport
import WalletCore
import XCTest

/// The multisig account store: sealed persistence, backups, and the coin
/// bookkeeping the combined filter scan drives (payments, spends, reorgs).
final class MultisigStoreTests: XCTestCase {
    private func account() throws -> MultisigAccount {
        let keys = try TestKeys.masters().prefix(2).map { try TestKeys.keyExpression(master: $0) }
        return try MultisigAccount(descriptor: MultisigAccount.descriptor(threshold: 2, signers: keys, network: .signet),
                                   network: .signet)
    }

    private func coin(_ account: MultisigAccount, amount: Int64, height: UInt32 = 100) throws -> WalletUTXO {
        try WalletUTXO(txid: Data(repeating: 0x5A, count: 32), vout: 0, amount: amount,
                       scriptPubKey: account.scriptPubKey(index: 0), chain: .receive, index: 0, height: height)
    }

    private func record(_ account: MultisigAccount, coins: [WalletUTXO]) -> MultisigAccountRecord {
        MultisigAccountRecord(id: account.id, name: "Phone and desktop", descriptor: account.descriptor.serialized(),
                            createdAtHeight: 0, nextReceiveIndex: 1, allUtxos: coins)
    }

    private func fetch(_ store: MultisigStore, _ id: String) async throws -> MultisigAccountRecord {
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
        spend(of: [outpoint], [.init(value: amount, scriptPubKey: script)] + (change.map { [$0] } ?? []))
    }

    private func spend(of outpoints: [Transaction.Outpoint], _ outputs: [Transaction.Output]) -> Transaction {
        Transaction(version: 2, inputs: outpoints.map { .init(previousOutput: $0, scriptSig: Data(), sequence: 0xFFFF_FFFD) },
                    outputs: outputs, locktime: 0)
    }

    /// An outpoint of a transaction this store never saw.
    private func foreign(_ byte: UInt8) -> Transaction.Outpoint {
        .init(txid: Data(repeating: byte, count: 32), vout: 0)
    }

    /// A creator's PSBT for `spend`, as the draft a phone files.
    private func psbt(for spend: Transaction, spending coins: [WalletUTXO]) throws -> PSBT {
        try PSBT(unsignedTx: spend,
                 inputs: spend.inputs.map { input in
                     let coin = coins.first { $0.outpoint == input.previousOutput }
                     return PSBT.InputInfo(spentOutput: .init(amount: coin?.amount ?? 1,
                                                              scriptPubKey: coin?.scriptPubKey ?? Data([0x51])))
                 },
                 outputs: spend.outputs.map { _ in PSBT.OutputInfo() })
    }

    func testBackupPreservesAccountsAndRejectsChangedOwnership() async throws {
        let keys = InMemoryStoreKeyVault()
        let url = tempFileURL("multisig.json")
        let account = try account()
        let record = record(account, coins: [try coin(account, amount: 80_000)])
        let store = MultisigStore(keys: keys)
        await store.configure(storageURL: url, network: .signet)
        try await store.restore([record])
        var backup = ImportBundle(network: "signet", lastKnownHeight: 100)
        backup.vaults = try await store.backupRecords()
        let decoded = try ImportBundle.decode(json: backup.serialized())
        XCTAssertEqual(decoded.vaults, [record])

        let restarted = MultisigStore(keys: keys)
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
        XCTAssertEqual(try JSONDecoder().decode([MultisigAccountRecord].self, from: unsealedPayload(of: url)), [record])
    }

    /// A backup carries what no block has taken yet, so a restored phone
    /// keeps waiting for it instead of forgetting it.
    func testBackupCarriesPendingAccountPayments() async throws {
        let account = try account()
        let store = MultisigStore(keys: InMemoryStoreKeyVault())
        await store.configure(storageURL: nil, network: .signet)
        let pending = record(account, coins: [try coin(account, amount: 80_000, height: 0)])
        try await store.restore([pending])
        var backup = ImportBundle(network: "signet", lastKnownHeight: 100)
        backup.vaults = try await store.backupRecords()
        XCTAssertEqual(try ImportBundle.decode(json: backup.serialized()).vaults, [pending])
    }

    /// Payments arrive, a spend goes out with change, a reorg drops a block:
    /// the same rules `Wallet` applies to its own coins.
    func testPaymentsSpendsAndRollbacks() async throws {
        let keys = InMemoryStoreKeyVault()
        let url = tempFileURL("multisig.json")
        let account = try account()
        let store = MultisigStore(keys: keys)
        await store.configure(storageURL: url, network: .signet)
        let added = try await store.add(name: "Shared", account: account, createdAtHeight: 100)
        let initialScripts = try await store.watchScripts(network: .signet)
        XCTAssertEqual(initialScripts.count, 2 * Int(Wallet.gapLimit), "receive and change up to the gap limit")

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
        // The spend is in the account's history as pending, with its exact
        // fee and breakdown, and its bytes are kept for announcing it again;
        // a backup carries all of it.
        let pendingEntry = try XCTUnwrap(current.history.first { $0.txid == spend.txid })
        XCTAssertEqual(pendingEntry.height, 0)
        XCTAssertEqual(pendingEntry.spent, 60_000)
        XCTAssertEqual(pendingEntry.received, 19_000)
        XCTAssertEqual(pendingEntry.fee, 1_000)
        XCTAssertEqual(pendingEntry.outputs?.change, [1])
        XCTAssertEqual(pendingEntry.outputs?.external.map(\.amount), [40_000])
        XCTAssertEqual(current.inFlight.map(\.txid), [spend.txid])
        XCTAssertEqual(try current.inFlight[0].transaction(), spend)
        XCTAssertEqual(current.history.map(\.txid), [funding.txid, later.txid, spend.txid])
        XCTAssertEqual(current.history[0].received, 60_000)
        XCTAssertEqual(current.history[0].height, 101)
        XCTAssertNil(current.history[0].fee, "a payment from elsewhere has no exact fee")
        let backupWhilePending = try await store.backupRecords()
        XCTAssertEqual(backupWhilePending, [current])

        // A reorg below the later payment drops it, with its history entry,
        // and keeps the in-flight spend's input reserved.
        try await store.rollBack(to: 101)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.balance, 19_000)
        XCTAssertEqual(current.nextReceiveIndex, 3, "a reorg never costs an address gap")
        XCTAssertEqual(current.history.map(\.txid), [funding.txid, spend.txid])

        // The spend confirms in place; a reorg below it puts it back in
        // flight, so its input stays reserved, its change leaves with the
        // block, and its entry re-pends with its bytes still kept.
        try await store.apply(match: block(at: 103, [spend]), network: .signet)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.allUtxos.first { $0.txid == funding.txid }?.spent?.height, 103)
        XCTAssertEqual(current.utxos.first { $0.txid == spend.txid }?.height, 103)
        let confirmed = try XCTUnwrap(current.history.first { $0.txid == spend.txid })
        XCTAssertEqual(confirmed.height, 103)
        XCTAssertEqual(confirmed.fee, 1_000)
        XCTAssertEqual(confirmed.outputs?.change, [1], "the breakdown survives confirmation")
        XCTAssertEqual(current.history.count, 2, "confirmed in place, not appended again")
        XCTAssertEqual(current.inFlight.map(\.txid), [spend.txid], "kept until the block is buried")
        try await store.rollBack(to: 102)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.allUtxos.first { $0.txid == funding.txid }?.spent,
                       WalletUTXO.SpentMarker(spentBy: spend.txid, height: nil))
        XCTAssertEqual(current.balance, 0)
        XCTAssertEqual(current.history.first { $0.txid == spend.txid }?.height, 0, "re-pended")
        XCTAssertEqual(current.inFlight.map(\.txid), [spend.txid])

        // Buried deep enough, the bytes are no longer kept.
        try await store.apply(match: block(at: 103, [spend]), network: .signet)
        for height in 104 ... 103 + MultisigStore.inFlightDepth {
            try await store.apply(match: block(at: height, [payment(to: Data([0x51]), amount: 1, from: foreign(UInt8(height)))]), network: .signet)
        }
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.inFlight, [])
        XCTAssertEqual(current.history.first { $0.txid == spend.txid }?.height, 103)

        let restarted = MultisigStore(keys: keys)
        await restarted.configure(storageURL: url, network: .signet)
        let reloaded = await restarted.all
        XCTAssertEqual(reloaded, [current])
    }

    /// A reorg takes away the block that confirmed an account spend, but
    /// every node that saw the spend puts it back in its mempool. Its inputs
    /// stay reserved for it, as `Wallet.rollBack` keeps the wallet's (#157):
    /// released, they would go into a new spend the network rejects. Its
    /// change leaves with the block, and returns when the spend confirms
    /// again.
    func testARollbackKeepsTheInputsOfAFallenSpendReserved() async throws {
        let account = try account()
        let store = MultisigStore(keys: InMemoryStoreKeyVault())
        await store.configure(storageURL: tempFileURL("multisig.json"), network: .signet)
        let added = try await store.add(name: "Shared", account: account, createdAtHeight: 100)
        let funding = payment(to: try account.scriptPubKey(index: 0), amount: 60_000, from: foreign(0x51))
        let other = payment(to: try account.scriptPubKey(index: 1), amount: 5_000, from: foreign(0x52))
        try await store.apply(match: block(at: 101, [funding, other]), network: .signet)
        let fundingCoin = Transaction.Outpoint(txid: funding.txid, vout: 0)

        let change = try account.scriptPubKey(index: 0, choice: AddressChain.change.rawValue)
        let spend = payment(to: Data([0x51, 0x20] + repeatElement(0x77, count: 32)), amount: 40_000,
                            from: fundingCoin, change: .init(value: 19_000, scriptPubKey: change))
        try await store.recordSpend(id: added.id, transaction: spend, changeIndex: 0)
        try await store.apply(match: block(at: 103, [spend]), network: .signet)
        var current = try await fetch(store, added.id)
        XCTAssertEqual(current.balance, 24_000)

        try await store.rollBack(to: 102)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.allUtxos.first { $0.outpoint == fundingCoin }?.spent,
                       WalletUTXO.SpentMarker(spentBy: spend.txid, height: nil), "in flight again")
        XCTAssertEqual(current.utxos.map(\.outpoint), [.init(txid: other.txid, vout: 0)],
                       "only the coin no spend holds can go into a new one")
        XCTAssertEqual(current.balance, 5_000, "the change left with its block")
        let backupWhileInFlight = try await store.backupRecords()
        XCTAssertEqual(backupWhileInFlight.first?.allUtxos.first { $0.outpoint == fundingCoin }?.spent,
                       WalletUTXO.SpentMarker(spentBy: spend.txid, height: nil),
                       "a backup carries the reservation, so a restore cannot double-spend it")
        try await store.rollBack(to: 102)
        let redone = try await fetch(store, added.id)
        XCTAssertEqual(redone, current, "a rollback redone after a crash changes nothing")

        // The spend confirms on the new branch: the reservation takes its
        // height, and the change is back.
        let discarded = try await store.apply(match: block(at: 104, [spend]), network: .signet)
        XCTAssertEqual(discarded, [])
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.allUtxos.first { $0.outpoint == fundingCoin }?.spent,
                       WalletUTXO.SpentMarker(spentBy: spend.txid, height: 104))
        XCTAssertEqual(current.balance, 24_000)
    }

    /// The fallen spend's input can itself sit above the fork: change from an
    /// earlier spend in a fallen block. The row stays, at height 0, so the
    /// rescan re-heights it rather than admitting it again unspent while the
    /// later spend is back in mempools, which is what `Wallet.rollBack` does
    /// with a reserved coin above the fork.
    func testARollbackKeepsAReservedCoinFromAFallenBlock() async throws {
        let account = try account()
        let store = MultisigStore(keys: InMemoryStoreKeyVault())
        await store.configure(storageURL: tempFileURL("multisig.json"), network: .signet)
        let added = try await store.add(name: "Shared", account: account, createdAtHeight: 100)
        let funding = payment(to: try account.scriptPubKey(index: 0), amount: 60_000, from: foreign(0x61))
        try await store.apply(match: block(at: 101, [funding]), network: .signet)

        // Another signer's spend with change to the account, then a spend of
        // that change, each confirmed above the fork.
        let elsewhere = Data([0x51, 0x20] + repeatElement(0x77, count: 32))
        let change = try account.scriptPubKey(index: 0, choice: AddressChain.change.rawValue)
        let first = payment(to: elsewhere, amount: 40_000, from: .init(txid: funding.txid, vout: 0),
                            change: .init(value: 19_000, scriptPubKey: change))
        let changeCoin = Transaction.Outpoint(txid: first.txid, vout: 1)
        let second = payment(to: elsewhere, amount: 18_000, from: changeCoin)
        try await store.apply(match: block(at: 103, [first]), network: .signet)
        try await store.apply(match: block(at: 104, [second]), network: .signet)

        try await store.rollBack(to: 102)
        var current = try await fetch(store, added.id)
        let kept = try XCTUnwrap(current.allUtxos.first { $0.outpoint == changeCoin }, "the reserved row stays")
        XCTAssertEqual(kept.height, 0, "not in a block yet")
        XCTAssertEqual(kept.spent, WalletUTXO.SpentMarker(spentBy: second.txid, height: nil))
        XCTAssertEqual(current.balance, 0)

        // The rescan finds the first spend again: its change is re-heighted,
        // not admitted a second time, and stays reserved for the second.
        try await store.apply(match: block(at: 103, [first]), network: .signet)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.allUtxos.filter { $0.outpoint == changeCoin }.map(\.height), [103])
        XCTAssertEqual(current.balance, 0, "the change is still the second spend's")
        try await store.apply(match: block(at: 104, [second]), network: .signet)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.allUtxos.first { $0.outpoint == changeCoin }?.spent,
                       WalletUTXO.SpentMarker(spentBy: second.txid, height: 104))
        XCTAssertFalse(current.allUtxos.contains { $0.height == 0 || ($0.spent != nil && $0.spent?.height == nil) })
    }

    /// A zero-value output is consensus-valid, and anyone who knows one
    /// account address can send it. It is not a coin; refusing its block
    /// instead would fail that block on every later sync pass.
    func testZeroValueOutputIsIgnoredAndTheScanMovesOn() async throws {
        let account = try account()
        let store = MultisigStore(keys: InMemoryStoreKeyVault())
        await store.configure(storageURL: tempFileURL("multisig.json"), network: .signet)
        let added = try await store.add(name: "Shared", account: account, createdAtHeight: 100)

        let dust = spend(of: [foreign(0x21)], [.init(value: 0, scriptPubKey: try account.scriptPubKey(index: 1)),
                                               .init(value: 5_000, scriptPubKey: try account.scriptPubKey(index: 0))])
        try await store.apply(match: block(at: 101, [dust]), network: .signet)
        var current = try await fetch(store, added.id)
        XCTAssertEqual(current.allUtxos.map(\.amount), [5_000], "the zero-value output is not a coin")
        XCTAssertEqual(current.nextReceiveIndex, 1, "and does not use up its address")

        let later = payment(to: try account.scriptPubKey(index: 1), amount: 7_000, from: foreign(0x22))
        try await store.apply(match: block(at: 102, [later]), network: .signet)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.balance, 12_000)
        XCTAssertEqual(current.nextReceiveIndex, 2)
    }

    /// Another signer's spend of a coin ours also spends confirms instead of
    /// ours. Ours can never confirm now: its change never existed, the
    /// inputs the winner left are the account's again, and a spend of that
    /// change loses with it. A reorg below the winner puts it back in flight,
    /// holding the coin it took; if ours confirms on the new branch instead,
    /// the winner is the one undone.
    func testALosingInFlightSpendReleasesItsCoinsAndDropsItsChange() async throws {
        let account = try account()
        let store = MultisigStore(keys: InMemoryStoreKeyVault())
        await store.configure(storageURL: tempFileURL("multisig.json"), network: .signet)
        let added = try await store.add(name: "Shared", account: account, createdAtHeight: 100)
        let first = payment(to: try account.scriptPubKey(index: 0), amount: 60_000, from: foreign(0x31))
        let second = payment(to: try account.scriptPubKey(index: 1), amount: 30_000, from: foreign(0x32))
        try await store.apply(match: block(at: 101, [first, second]), network: .signet)
        let firstCoin = Transaction.Outpoint(txid: first.txid, vout: 0)
        let secondCoin = Transaction.Outpoint(txid: second.txid, vout: 0)

        // Ours, broadcast from this phone: both coins in, change at index 0,
        // then a spend of that change before either confirms.
        let elsewhere = Data([0x51, 0x20] + repeatElement(0x77, count: 32))
        let change = { (index: UInt32) in try account.scriptPubKey(index: index, choice: AddressChain.change.rawValue) }
        let ours = spend(of: [firstCoin, secondCoin], [.init(value: 70_000, scriptPubKey: elsewhere),
                                                      .init(value: 19_000, scriptPubKey: try change(0))])
        try await store.recordSpend(id: added.id, transaction: ours, changeIndex: 0)
        let chained = payment(to: elsewhere, amount: 10_000, from: .init(txid: ours.txid, vout: 1),
                              change: .init(value: 8_000, scriptPubKey: try change(1)))
        try await store.recordSpend(id: added.id, transaction: chained, changeIndex: 1)
        var current = try await fetch(store, added.id)
        XCTAssertEqual(current.balance, 8_000)

        // Another signer spent the first coin alone, with change to the
        // change address its own phone had next.
        let theirs = payment(to: elsewhere, amount: 45_000, from: firstCoin,
                             change: .init(value: 14_000, scriptPubKey: try change(0)))
        let discarded = try await store.apply(match: block(at: 102, [theirs]), network: .signet)
        XCTAssertEqual(discarded, [ours.txid, chained.txid], "the broadcaster stops relaying both")
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.allUtxos.first { $0.outpoint == firstCoin }?.spent,
                       WalletUTXO.SpentMarker(spentBy: theirs.txid, height: 102))
        XCTAssertEqual(Set(current.utxos.map(\.outpoint)), [secondCoin, .init(txid: theirs.txid, vout: 1)])
        XCTAssertEqual(current.balance, 44_000)
        XCTAssertFalse(current.allUtxos.contains { $0.txid == ours.txid || $0.txid == chained.txid },
                       "the losing spends' outputs never existed")
        XCTAssertFalse(current.allUtxos.contains { $0.spent != nil && $0.spent?.height == nil },
                       "nothing stays reserved for a spend that cannot confirm")
        XCTAssertEqual(current.history.first { $0.txid == ours.txid }?.replacedBy, theirs.txid,
                       "the losing spend stays listed beside the one that took its coin")
        XCTAssertEqual(current.history.first { $0.txid == chained.txid }?.replacedBy, theirs.txid)
        XCTAssertEqual(current.inFlight, [], "nothing is left to announce")
        XCTAssertEqual(current.history.first { $0.txid == theirs.txid }?.spent, 60_000)
        XCTAssertEqual(current.history.first { $0.txid == theirs.txid }?.fee, 1_000,
                       "its one input was the account's, so the fee is exact")

        // A reorg below the winner: it is back in mempools, so the coin it
        // took stays reserved for it and its change leaves with the block...
        try await store.rollBack(to: 101)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.allUtxos.first { $0.outpoint == firstCoin }?.spent,
                       WalletUTXO.SpentMarker(spentBy: theirs.txid, height: nil))
        XCTAssertEqual(current.balance, 30_000)
        // ...and on the new branch ours confirms after all, beating it.
        let beaten = try await store.apply(match: block(at: 102, [ours]), network: .signet)
        XCTAssertEqual(beaten, [theirs.txid])
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.utxos.map(\.outpoint), [.init(txid: ours.txid, vout: 1)])
        XCTAssertEqual(current.balance, 19_000)
        XCTAssertNil(current.history.first { $0.txid == ours.txid }?.replacedBy, "ours won after all")
        XCTAssertEqual(current.history.first { $0.txid == theirs.txid }?.replacedBy, ours.txid)
    }

    /// A draft lives on the record until its coins are gone: this phone
    /// broadcasting it, a co-signer's conflicting spend confirming, or a
    /// reorg taking a coin all drop it. A spend given up on frees its coins.
    func testDraftsFollowTheirCoinsAndAnAbandonedSpendFreesThem() async throws {
        let keys = InMemoryStoreKeyVault()
        let url = tempFileURL("multisig.json")
        let account = try account()
        let store = MultisigStore(keys: keys)
        await store.configure(storageURL: url, network: .signet)
        let added = try await store.add(name: "Shared", account: account, createdAtHeight: 100)
        let funding = payment(to: try account.scriptPubKey(index: 0), amount: 60_000, from: foreign(0x71))
        try await store.apply(match: block(at: 101, [funding]), network: .signet)
        let fundingCoin = Transaction.Outpoint(txid: funding.txid, vout: 0)
        let elsewhere = Data([0x51, 0x20] + repeatElement(0x77, count: 32))
        let change = try account.scriptPubKey(index: 0, choice: AddressChain.change.rawValue)
        let spend = payment(to: elsewhere, amount: 40_000, from: fundingCoin, change: .init(value: 19_000, scriptPubKey: change))
        let coins = try await fetch(store, added.id).allUtxos
        let draft = MultisigSpendDraft(psbtBase64: try psbt(for: spend, spending: coins).base64,
                                       personID: "bob", paymentIndex: 3, createdAtHeight: 101)

        // Filed, read back from disk, and carried by a backup.
        try await store.setDraft(id: added.id, draft)
        let filed = try await fetch(store, added.id)
        XCTAssertEqual(filed.draft, draft)
        let restarted = MultisigStore(keys: keys)
        await restarted.configure(storageURL: url, network: .signet)
        let reloaded = try await fetch(restarted, added.id)
        XCTAssertEqual(reloaded.draft, draft)
        let backup = try await store.backupRecords()
        XCTAssertEqual(backup.first?.draft, draft)

        // A draft of a coin the account does not hold is refused.
        var stranger = draft
        stranger.psbtBase64 = try psbt(for: payment(to: elsewhere, amount: 1, from: foreign(0x72)), spending: []).base64
        do {
            try await store.setDraft(id: added.id, stranger)
            XCTFail("a draft of a foreign coin was filed")
        } catch MultisigStorageError.invalidState {}

        // Broadcast: the draft is retired with the coin it spent...
        try await store.recordSpend(id: added.id, transaction: spend, changeIndex: 0, broadcastHeight: 102)
        var current = try await fetch(store, added.id)
        XCTAssertNil(current.draft)
        XCTAssertEqual(current.inFlight.map(\.broadcastHeight), [102])
        // ...and given up on, everything it took is back.
        try await store.abandonSpend(id: added.id, txid: spend.txid)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.utxos.map(\.outpoint), [fundingCoin])
        XCTAssertEqual(current.balance, 60_000)
        XCTAssertEqual(current.history.map(\.txid), [funding.txid])
        XCTAssertEqual(current.inFlight, [])
        do {
            try await store.abandonSpend(id: added.id, txid: funding.txid)
            XCTFail("a confirmed transaction was given up on")
        } catch MultisigStorageError.invalidState {}

        // Filed again, then a co-signer's spend of the same coin confirms:
        // the draft can never be broadcast, so it goes.
        try await store.setDraft(id: added.id, draft)
        let theirs = payment(to: elsewhere, amount: 50_000, from: fundingCoin)
        try await store.apply(match: block(at: 103, [theirs]), network: .signet)
        current = try await fetch(store, added.id)
        XCTAssertNil(current.draft)
        XCTAssertEqual(current.history.map(\.txid), [funding.txid, theirs.txid])

        // And one whose coin a reorg takes away goes with it.
        try await store.rollBack(to: 102)
        let late = payment(to: try account.scriptPubKey(index: 1), amount: 9_000, from: foreign(0x73))
        try await store.apply(match: block(at: 103, [late]), network: .signet)
        let lateCoins = try await fetch(store, added.id).allUtxos
        let lateDraft = MultisigSpendDraft(
            psbtBase64: try psbt(for: payment(to: elsewhere, amount: 8_000, from: .init(txid: late.txid, vout: 0)),
                                 spending: lateCoins).base64,
            createdAtHeight: 103)
        try await store.setDraft(id: added.id, lateDraft)
        try await store.rollBack(to: 102)
        let afterFork = try await fetch(store, added.id)
        XCTAssertNil(afterFork.draft)
    }

    /// Each signer's phone hands out its own addresses, so a payment can
    /// land up to the gap limit past this phone's frontier. The store
    /// watches as far as the wallet does, and the window moves with the
    /// frontier.
    func testLookaheadFindsPaymentsUpToTheGapLimitAhead() async throws {
        let account = try account()
        let store = MultisigStore(keys: InMemoryStoreKeyVault())
        await store.configure(storageURL: nil, network: .signet)
        let added = try await store.add(name: "Shared", account: account, createdAtHeight: 100)
        let last = Wallet.gapLimit - 1
        let watched = Set(try await store.watchScripts(network: .signet))
        XCTAssertTrue(watched.contains(try account.scriptPubKey(index: last)))
        XCTAssertTrue(watched.contains(try account.scriptPubKey(index: last, choice: AddressChain.change.rawValue)))
        XCTAssertFalse(watched.contains(try account.scriptPubKey(index: Wallet.gapLimit)))

        let far = payment(to: try account.scriptPubKey(index: last), amount: 9_000, from: foreign(0x41))
        try await store.apply(match: block(at: 101, [far]), network: .signet)
        var current = try await fetch(store, added.id)
        XCTAssertEqual(current.balance, 9_000)
        XCTAssertEqual(current.nextReceiveIndex, Wallet.gapLimit)

        // The frontier moved, and the window with it.
        let furthest = 2 * Wallet.gapLimit - 1
        let receive = payment(to: try account.scriptPubKey(index: furthest), amount: 3_000, from: foreign(0x42))
        let toChange = payment(to: try account.scriptPubKey(index: furthest, choice: AddressChain.change.rawValue),
                               amount: 2_000, from: foreign(0x43))
        try await store.apply(match: block(at: 102, [receive, toChange]), network: .signet)
        current = try await fetch(store, added.id)
        XCTAssertEqual(current.balance, 14_000)
        XCTAssertEqual(current.nextReceiveIndex, 2 * Wallet.gapLimit)
        XCTAssertEqual(current.nextChangeIndex, 2 * Wallet.gapLimit)
    }

    func testTamperedUnsealedAndOversizedFilesAreRefusedAndKept() async throws {
        let keys = InMemoryStoreKeyVault()
        let url = tempFileURL("multisig.json")
        let account = try account()
        let store = MultisigStore(keys: keys)
        await store.configure(storageURL: url, network: .signet)
        try await store.add(name: "Shared", account: account, createdAtHeight: 100)
        XCTAssertTrue(SealedStoreFile.isSealed(try Data(contentsOf: url)))
        XCTAssertNotNil(try keys.key(for: "multisig.signet"))

        // One payload byte changed: the seal refuses it, and nothing is written.
        var bytes = try Data(contentsOf: url)
        let index = try XCTUnwrap(bytes.lastIndex(of: UInt8(ascii: "S")))
        bytes[index] = UInt8(ascii: "T")
        try bytes.write(to: url)
        let tampered = MultisigStore(keys: keys)
        guard case .damaged = await tampered.configure(storageURL: url, network: .signet) else {
            return XCTFail("a tampered account file was read")
        }
        do {
            try await tampered.add(name: "Other", account: account, createdAtHeight: 1)
            XCTFail("a damaged store accepted a change")
        } catch MultisigStorageError.damaged {}
        XCTAssertEqual(try Data(contentsOf: url), bytes, "the damaged file is left as it was")

        // A well-formed but unsealed file, on a phone that never sealed one.
        let planted = tempFileURL("multisig.json")
        try JSONEncoder().encode([record(account, coins: [])]).write(to: planted)
        let fresh = MultisigStore(keys: InMemoryStoreKeyVault())
        guard case .damaged = await fresh.configure(storageURL: planted, network: .signet) else {
            return XCTFail("an unsealed account file was adopted")
        }

        let oversized = tempFileURL("multisig.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(MultisigStore.maximumFileBytes + 1))
        try handle.close()
        guard case .damaged = await MultisigStore(keys: keys).configure(storageURL: oversized, network: .signet) else {
            return XCTFail("an oversized account file was read")
        }
    }

    func testDuplicateWrongNetworkAndBadNamesAreRefused() async throws {
        let account = try account()
        let store = MultisigStore(keys: InMemoryStoreKeyVault())
        await store.configure(storageURL: tempFileURL("multisig.json"), network: .signet)
        try await store.add(name: "Shared", account: account, createdAtHeight: 1)
        do {
            try await store.add(name: "Again", account: account, createdAtHeight: 1)
            XCTFail("the same account was added twice")
        } catch MultisigStorageError.duplicate {}
        let regtest = try MultisigAccount(descriptor: account.descriptor, network: .regtest)
        do {
            try await store.add(name: "Regtest", account: regtest, createdAtHeight: 1)
            XCTFail("another network's account was added")
        } catch MultisigStorageError.invalidState {}
        for name in ["", "two\nlines", String(repeating: "x", count: DisplayName.maximumLength + 1)] {
            let store = MultisigStore(keys: InMemoryStoreKeyVault())
            await store.configure(storageURL: nil, network: .signet)
            do {
                try await store.add(name: name, account: account, createdAtHeight: 1)
                XCTFail("an unusable name was accepted")
            } catch MultisigStorageError.invalidState {}
        }
        let all = await store.all
        XCTAssertEqual(all.count, 1)
    }
}
