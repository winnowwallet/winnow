import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// The shared pass must preserve the ordering and recovery guarantees of the
/// app's former orchestration. All peers below are local loopback listeners.
@Suite("WalletSync")
struct WalletSyncTests {
    @Test("bounded passes persist the frontier and combine wallet and additional scripts")
    func boundedPassAndAdditionalScripts() async throws {
        let directory = TempDir()
        let keyStore = InMemoryKeyStore()
        let walletURL = directory.fileURL("wallet.json")
        let wallet = try makeTestWallet(storageURL: walletURL, keyStore: keyStore,
                                        creationHeight: 1)
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let additional = Data([0x51, 0x20] + repeatElement(0x44, count: 32))
        let ownPayment = payment(to: script, amount: 10_000, tag: 1)
        let additionalPayment = payment(to: additional, amount: 20_000, tag: 2)
        let blocks = chain(length: 6, transactions: [2: ownPayment, 4: additionalPayment])
        let fixture = try await Fixture(blocks: blocks, directory: directory)
        defer { Task { await fixture.stop() } }
        try await fixture.broadcaster.broadcast(ownPayment.serialized(includeWitness: true))
        try await fixture.broadcaster.broadcast(additionalPayment.serialized(includeWitness: true))
        let matches = MatchCollector()
        let hook: @Sendable (BlockMatch) async throws -> Void = { match in
            matches.add(match)
            #expect(await wallet.balance == 10_000, "wallet application precedes the extension hook")
            #expect(await fixture.broadcaster.pendingTxids.contains(match.block.transactions[0].txid),
                    "the extension store must succeed before relay confirmation")
        }

        let first = try await WalletSync.run(
            wallet: wallet, filters: fixture.filters, broadcaster: fixture.broadcaster,
            additionalScripts: [additional], maxBlocks: 3, onMatch: hook)
        #expect(first == 4)
        #expect(await wallet.nextScanHeight == first)
        #expect(await fixture.filters.nextScanHeight == first)
        let reloaded = try Wallet.open(storageURL: walletURL, keyStore: keyStore)
        #expect(await reloaded.nextScanHeight == first)
        #expect(await reloaded.balance == 10_000)
        #expect(await fixture.broadcaster.pendingTxids == [additionalPayment.txid])

        let second = try await WalletSync.run(
            wallet: wallet, filters: fixture.filters, broadcaster: fixture.broadcaster,
            additionalScripts: [additional], onMatch: hook)
        #expect(second == 7, "nonmatching blocks advance the persisted frontier too")
        #expect(matches.matches.map(\.height) == [2, 4])
        #expect(await wallet.balance == 10_000, "additional scripts do not become wallet-owned outputs")
        #expect(await fixture.broadcaster.pendingTxids.isEmpty)
        let reopened = try Wallet.open(storageURL: walletURL, keyStore: keyStore)
        #expect(await reopened.nextScanHeight == second)
        let savedFilters = try JSONDecoder().decode(
            FilterSync.Progress.self, from: Data(contentsOf: directory.fileURL("filters.json")))
        #expect(savedFilters.nextScanHeight == second)
    }

    @Test("failure and cancellation keep the last completed batch and can be retried",
          arguments: [false, true])
    func interruptedPassPreservesFrontier(cancel: Bool) async throws {
        let directory = TempDir()
        let keyStore = InMemoryKeyStore()
        let walletURL = directory.fileURL("wallet.json")
        let wallet = try makeTestWallet(storageURL: walletURL, keyStore: keyStore,
                                        creationHeight: 1)
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let firstPayment = payment(to: script, amount: 10_000, tag: 1)
        let laterPayment = payment(to: script, amount: 20_000, tag: 2)
        let blocks = chain(length: 1_003, transactions: [1_002: firstPayment, 1_003: laterPayment])
        let fixture = try await Fixture(blocks: blocks, directory: directory)
        defer { Task { await fixture.stop() } }
        let matches = MatchCollector()

        // The first 1,000-block batch commits. The extension then fails in
        // the second batch, or cancels the task before the next match applies.
        let task = Task { () -> Result<UInt32, any Error> in
            do {
                return .success(try await WalletSync.run(
                    wallet: wallet, filters: fixture.filters, broadcaster: fixture.broadcaster,
                    onMatch: { match in
                        // Compact filters may produce harmless false positives.
                        // Interrupt on the deliberate payment, not an earlier hit.
                        guard match.height == 1_002 else { return }
                        matches.add(match)
                        if cancel {
                            withUnsafeCurrentTask { $0?.cancel() }
                        } else {
                            throw HookError.failed
                        }
                    }))
            } catch {
                return .failure(error)
            }
        }
        switch await task.value {
        case .success:
            Issue.record("an interrupted pass must not report success")
        case let .failure(error):
            if cancel {
                #expect(error is CancellationError)
            } else {
                #expect(error as? HookError == .failed)
            }
        }
        #expect(matches.matches.map(\.height) == [1_002])
        #expect(await fixture.filters.nextScanHeight == 1_001)
        #expect(await wallet.nextScanHeight == 1_001)
        #expect(await wallet.balance == 10_000, "the next match must not be applied after cancellation")
        let reopened = try Wallet.open(storageURL: walletURL, keyStore: keyStore)
        #expect(await reopened.nextScanHeight == 1_001)
        #expect(await reopened.balance == 10_000)

        let resumed = try await WalletSync.run(
            wallet: reopened, filters: fixture.filters, broadcaster: fixture.broadcaster)
        #expect(resumed == 1_004)
        #expect(await reopened.balance == 30_000, "replaying the partially applied batch is idempotent")
        #expect(await reopened.history.filter { $0.txid == firstPayment.txid }.count == 1)
    }

    @Test("cancelling in the final match keeps the batch and relay retryable")
    func cancelledInFinalMatch() async throws {
        let directory = TempDir()
        let keyStore = InMemoryKeyStore()
        let walletURL = directory.fileURL("wallet.json")
        let wallet = try makeTestWallet(storageURL: walletURL, keyStore: keyStore,
                                        creationHeight: 1)
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let transaction = payment(to: script, amount: 10_000, tag: 1)
        let fixture = try await Fixture(blocks: chain(length: 2, transactions: [2: transaction]),
                                        directory: directory)
        defer { Task { await fixture.stop() } }
        try await fixture.broadcaster.broadcast(transaction.serialized(includeWitness: true))
        let task = Task {
            try await WalletSync.run(
                wallet: wallet, filters: fixture.filters, broadcaster: fixture.broadcaster,
                onMatch: { match in
                    if match.height == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.filters.nextScanHeight == 1)
        #expect(await fixture.broadcaster.pendingTxids == [transaction.txid],
                "cancellation in the extension must not confirm the relay entry")
        let reopened = try Wallet.open(storageURL: walletURL, keyStore: keyStore)
        #expect(await reopened.nextScanHeight == 1)
        #expect(await reopened.balance == 10_000)
        #expect(try await WalletSync.run(
            wallet: reopened, filters: fixture.filters, broadcaster: fixture.broadcaster) == 3)
        #expect(await reopened.balance == 10_000, "retrying the interrupted match is idempotent")
        #expect(await fixture.broadcaster.pendingTxids.isEmpty)
    }

    @Test("cancellation during rollback finishes all rewinds without reporting success")
    func cancelledDuringRollback() async throws {
        let directory = TempDir()
        let wallet = try makeTestWallet(creationHeight: 1)
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let transaction = payment(to: script, amount: 10_000, tag: 1)
        let oldBlocks = chain(length: 4, transactions: [3: transaction])
        let fixture = try await Fixture(blocks: chain(length: 6), directory: directory,
                                        startHeight: 5)
        defer { Task { await fixture.stop() } }
        try await fixture.headers.connect(oldBlocks.dropFirst().map(\.header))
        try await wallet.apply(match: BlockMatch(height: 3, blockHash: oldBlocks[3].hash,
                                                 block: oldBlocks[3]))
        try await wallet.recordScanHeight(5)
        try await fixture.broadcaster.broadcast(transaction.serialized(includeWitness: true))
        try await fixture.broadcaster.markConfirmed(transaction.txid, atHeight: 3)
        let order = EventCollector<String>()
        let task = Task {
            try await WalletSync.run(
                wallet: wallet, filters: fixture.filters, broadcaster: fixture.broadcaster,
                maxBlocks: 0, beforeReorg: { height in
                    #expect(height == 2)
                    order.add("intent")
                    withUnsafeCurrentTask { $0?.cancel() }
                }, onReorg: { _ in
                    #expect(await wallet.nextScanHeight == 3)
                    order.add("additional-store")
                }, onMatch: { _ in
                    Issue.record("a zero-block pass must not deliver matches")
                })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(order.events == ["intent", "additional-store"])
        #expect(await wallet.balance == 0)
        #expect(await wallet.nextScanHeight == 3)
        #expect(await fixture.filters.nextScanHeight == 3)
        #expect(await fixture.broadcaster.pendingTxids == [transaction.txid])
        let savedFilters = try JSONDecoder().decode(
            FilterSync.Progress.self, from: Data(contentsOf: directory.fileURL("filters.json")))
        #expect(savedFilters.nextScanHeight == 3, "cancellation must not interrupt the durable rewind")
    }

    @Test("a task already cancelled does not scan or rewrite wallet progress")
    func cancelledBeforeStart() async throws {
        let directory = TempDir()
        let walletURL = directory.fileURL("wallet.json")
        let wallet = try makeTestWallet(storageURL: walletURL, creationHeight: 1)
        let fixture = try await Fixture(blocks: chain(length: 3), directory: directory)
        defer { Task { await fixture.stop() } }
        let before = try Data(contentsOf: walletURL)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WalletSync.run(
                wallet: wallet, filters: fixture.filters, broadcaster: fixture.broadcaster)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.filters.nextScanHeight == 1)
        #expect(await fixture.node.receivedMessages.contains { $0.command == "getheaders" } == false)
        #expect(try Data(contentsOf: walletURL) == before)
    }

    @Test("a failed best-effort wallet save does not replace the original sync error")
    func failedRecoverySavePreservesError() async throws {
        let directory = TempDir()
        defer { withExtendedLifetime(directory) {} }
        let walletURL = directory.fileURL("wallet.json")
        let wallet = try makeTestWallet(storageURL: walletURL, creationHeight: 1)
        let pool = PeerPool(params: .signet, peerCount: 1, manualPeers: [],
                            peersFileURL: directory.fileURL("peers.json"))
        let headers = try HeaderChain(params: .signet)
        let filters = try FilterSync(pool: pool, chain: headers, startHeight: 1,
                                     requiredCheckpointPeers: 1)
        let broadcaster = try TxBroadcaster(pool: pool)
        defer { Task { await broadcaster.shutdown() } }
        try FileManager.default.removeItem(at: walletURL)
        try FileManager.default.createDirectory(at: walletURL, withIntermediateDirectories: false)

        await #expect(throws: FilterSyncError.noPeers) {
            try await WalletSync.run(wallet: wallet, filters: filters, broadcaster: broadcaster)
        }
        #expect(await filters.nextScanHeight == 1)
    }

    @Test("a refused concurrent pass leaves its wallet untouched")
    func concurrentPassDoesNotSave() async throws {
        let directory = TempDir()
        let wallet = try makeTestWallet(creationHeight: 1)
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let fixture = try await Fixture(
            blocks: chain(length: 4, transactions: [2: payment(to: script, amount: 10_000, tag: 1)]),
            directory: directory)
        defer { Task { await fixture.stop() } }
        let otherURL = directory.fileURL("other-wallet.json")
        let otherWallet = try makeTestWallet(storageURL: otherURL, creationHeight: 1)
        try await otherWallet.recordScanHeight(20)
        let otherBefore = try Data(contentsOf: otherURL)
        let gate = MatchGate()
        let first = Task { () -> Result<UInt32, any Error> in
            let result: Result<UInt32, any Error>
            do {
                result = .success(try await WalletSync.run(
                    wallet: wallet, filters: fixture.filters, broadcaster: fixture.broadcaster,
                    onMatch: { _ in
                        await gate.reached()
                        await gate.waitForRelease()
                    }))
            } catch {
                result = .failure(error)
            }
            await gate.reached() // A failed first pass must not strand the test.
            return result
        }
        await gate.waitUntilReached()
        await #expect(throws: FilterSyncError.busy) {
            try await WalletSync.run(wallet: otherWallet, filters: fixture.filters,
                                     broadcaster: fixture.broadcaster)
        }
        #expect(await otherWallet.nextScanHeight == 20)
        #expect(try Data(contentsOf: otherURL) == otherBefore)
        await gate.release()
        #expect(try await first.value.get() == 5)
        #expect(await wallet.nextScanHeight == 5)
    }

    @Test("reorg hooks bracket wallet rollback before relay resumes and matches reconfirm")
    func reorgOrderingAndRelay() async throws {
        let directory = TempDir()
        let keyStore = InMemoryKeyStore()
        let walletURL = directory.fileURL("wallet.json")
        let wallet = try makeTestWallet(storageURL: walletURL, keyStore: keyStore,
                                        creationHeight: 1)
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let transaction = payment(to: script, amount: 10_000, tag: 1)
        let oldBlocks = chain(length: 4, transactions: [3: transaction])
        let newBlocks = chain(length: 6, transactions: [5: transaction])
        let fixture = try await Fixture(blocks: newBlocks, directory: directory, startHeight: 5)
        defer { Task { await fixture.stop() } }
        try await fixture.headers.connect(oldBlocks.dropFirst().map(\.header))
        try await wallet.apply(match: BlockMatch(height: 3, blockHash: oldBlocks[3].hash,
                                                 block: oldBlocks[3]))
        try await wallet.recordScanHeight(5)
        try await fixture.broadcaster.broadcast(transaction.serialized(includeWitness: true))
        try await fixture.broadcaster.markConfirmed(transaction.txid, atHeight: 3)
        let order = EventCollector<String>()

        let frontier = try await WalletSync.run(
            wallet: wallet, filters: fixture.filters, broadcaster: fixture.broadcaster,
            beforeReorg: { height in
                order.add("before")
                #expect(height == 2)
                #expect(await wallet.balance == 10_000)
                #expect(await wallet.nextScanHeight == 5)
                #expect(await fixture.broadcaster.pendingTxids.isEmpty)
            }, onReorg: { height in
                order.add("additional-store")
                #expect(height == 2)
                #expect(await wallet.balance == 0)
                #expect(await wallet.nextScanHeight == 3)
                #expect(await fixture.broadcaster.pendingTxids.isEmpty,
                        "the additional store rolls back before relay is reactivated")
            }, onMatch: { match in
                order.add("match")
                #expect(match.height == 5)
                #expect(await wallet.balance == 10_000)
                #expect(await fixture.broadcaster.pendingTxids == [transaction.txid],
                        "the orphaned confirmation must have been reactivated before scanning")
            })
        #expect(order.events == ["before", "additional-store", "match"])
        #expect(frontier == 7)
        #expect(await fixture.broadcaster.pendingTxids.isEmpty)
        #expect(await wallet.history.first { $0.txid == transaction.txid }?.height == 5)
        let reopened = try Wallet.open(storageURL: walletURL, keyStore: keyStore)
        #expect(await reopened.nextScanHeight == frontier)
        #expect(await reopened.balance == 10_000)
    }

    @Test("rollback failures preserve the original error and never undo the wallet rewind",
          arguments: ReorgFailureStage.allCases)
    func failedReorgPreservesWalletState(stage: ReorgFailureStage) async throws {
        let directory = TempDir()
        let keyStore = InMemoryKeyStore()
        let walletURL = directory.fileURL("wallet.json")
        let wallet = try makeTestWallet(storageURL: walletURL, keyStore: keyStore,
                                        creationHeight: 1)
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let transaction = payment(to: script, amount: 10_000, tag: 1)
        let oldBlocks = chain(length: 4, transactions: [3: transaction])
        let fixture = try await Fixture(blocks: chain(length: 6), directory: directory,
                                        startHeight: 5)
        defer { Task { await fixture.stop() } }
        try await fixture.headers.connect(oldBlocks.dropFirst().map(\.header))
        try await wallet.apply(match: BlockMatch(height: 3, blockHash: oldBlocks[3].hash,
                                                 block: oldBlocks[3]))
        try await wallet.recordScanHeight(5)
        try await fixture.broadcaster.broadcast(transaction.serialized(includeWitness: true))
        try await fixture.broadcaster.markConfirmed(transaction.txid, atHeight: 3)

        var failure: (any Error)?
        do {
            try await WalletSync.run(
                wallet: wallet, filters: fixture.filters, broadcaster: fixture.broadcaster,
                beforeReorg: { height in
                    #expect(height == 2)
                    if stage == .beforeWallet { throw HookError.failed }
                },
                onReorg: { height in
                    #expect(stage != .beforeWallet)
                    #expect(height == 2)
                    #expect(await wallet.nextScanHeight == 3)
                    if stage == .additionalStore { throw HookError.failed }
                    // The fixture has not saved a filter file yet. A directory
                    // at its destination makes the actual atomic write fail.
                    try FileManager.default.createDirectory(
                        at: directory.fileURL("filters.json"), withIntermediateDirectories: false)
                }, onMatch: { _ in
                    Issue.record("scanning cannot resume after a failed rollback")
                })
            Issue.record("the failed rollback must abort the pass")
        } catch {
            failure = error
        }
        if stage == .filterStorage {
            #expect(failure as? FilterSyncStorageError == .writeFailed)
        } else {
            #expect(failure as? HookError == .failed)
        }
        // FilterSync calls the coordinator before rewinding its own frontier.
        // Copying that old frontier in the catch path would silently undo the
        // wallet rollback even though its orphaned coins have been removed.
        #expect(await fixture.filters.nextScanHeight == 5)
        let expectedFrontier: UInt32 = stage == .beforeWallet ? 5 : 3
        let expectedBalance: Int64 = stage == .beforeWallet ? 10_000 : 0
        #expect(await wallet.nextScanHeight == expectedFrontier)
        #expect(await wallet.balance == expectedBalance)
        let expectedPending = stage == .filterStorage ? [transaction.txid] : []
        #expect(await fixture.broadcaster.pendingTxids == expectedPending,
                "relay rollback follows successful wallet and extension rollback")
        #expect(await fixture.node.receivedMessages.contains { $0.command == "getcfilters" } == false)
        let reopened = try Wallet.open(storageURL: walletURL, keyStore: keyStore)
        #expect(await reopened.nextScanHeight == expectedFrontier)
        #expect(await reopened.balance == expectedBalance)
    }

    @Test("confirmation cancels a losing fee replacement before the extension hook")
    func discardedReplacementStopsRelaying() async throws {
        let directory = TempDir()
        let wallet = try makeTestWallet(creationHeight: 1)
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let funding = payment(to: script, amount: 150_000, tag: 1)
        try await wallet.apply(match: fakeMatch(height: 1, transactions: [funding]))
        let destination = Data([0x51, 0x20] + repeatElement(0x77, count: 32))
        let original = try await wallet.buildSend(
            payments: [Payment(amount: 100_000, scriptPubKey: destination)],
            feeRateSatPerVByte: 2, chainTip: 2, randomness: { 0.5 })
        try await wallet.commit(original)
        let replacement = try await wallet.buildFeeBump(
            txid: original.built.transaction.txid, feeRateSatPerVByte: 5)
        try await wallet.commitFeeBump(replacement)
        let fixture = try await Fixture(
            blocks: chain(length: 4, transactions: [1: funding, 3: original.built.transaction]),
            directory: directory, startHeight: 2)
        defer { Task { await fixture.stop() } }
        let originalID = try await fixture.broadcaster.broadcast(
            original.built.transaction.serialized(includeWitness: true))
        let replacementID = try await fixture.broadcaster.broadcast(
            replacement.built.transaction.serialized(includeWitness: true))

        try await WalletSync.run(
            wallet: wallet, filters: fixture.filters, broadcaster: fixture.broadcaster,
            onMatch: { match in
                #expect(match.height == 3)
                #expect(await fixture.broadcaster.pendingTxids == [originalID])
                #expect(await fixture.broadcaster.rawTransaction(replacementID) == nil)
                #expect(await wallet.history.contains { $0.txid == replacementID } == false)
            })
        #expect(await fixture.broadcaster.pendingTxids.isEmpty)
        #expect(await wallet.balance == original.built.changeAmount)
        // A discarded replacement is removed, not retained as a confirmation
        // tombstone that a future reorg would accidentally relay again.
        try await fixture.broadcaster.rollBack(to: 2)
        #expect(await fixture.broadcaster.pendingTxids == [originalID])
    }

    @Test("a completed pass prunes relay confirmations beyond the retained horizon")
    func completedPassPrunesRelay() async throws {
        let directory = TempDir()
        let wallet = try makeTestWallet(creationHeight: 1)
        let fixture = try await Fixture(blocks: chain(length: 110), directory: directory)
        defer { Task { await fixture.stop() } }
        let old = try await fixture.broadcaster.broadcast(makeFakeSegwitTx().serialized(includeWitness: true))
        var recentTransaction = makeFakeSegwitTx()
        recentTransaction.outputs[0].value = 60_000
        let recent = try await fixture.broadcaster.broadcast(
            recentTransaction.serialized(includeWitness: true))
        try await fixture.broadcaster.markConfirmed(old, atHeight: 1)
        try await fixture.broadcaster.markConfirmed(recent, atHeight: 105)

        #expect(try await WalletSync.run(
            wallet: wallet, filters: fixture.filters, broadcaster: fixture.broadcaster) == 111)
        try await fixture.broadcaster.rollBack(to: 0)
        #expect(await fixture.broadcaster.pendingTxids == [recent],
                "only the recent confirmation remains available for reorg recovery")
    }

    private enum HookError: Error, Equatable { case failed }
    enum ReorgFailureStage: CaseIterable { case beforeWallet, additionalStore, filterStorage }

    private func payment(to script: Data, amount: Int64, tag: UInt8) -> Transaction {
        Transaction(version: 2, inputs: [Transaction.Input(
            previousOutput: .init(txid: Data(repeating: tag, count: 32), vout: 0),
            scriptSig: Data(), sequence: 0xFFFF_FFFD)],
            outputs: [.init(value: amount, scriptPubKey: script)], locktime: 0)
    }

    /// Rebuild the single-transaction synthetic chain with chosen payments.
    /// Unchanged prefixes have identical hashes, so the same helper also
    /// builds competing branches for the real HeaderChain fork-choice path.
    private func chain(length: Int, transactions: [Int: Transaction] = [:]) -> [Block] {
        let synthetic = makeSyntheticChain(length: length, watchHeight: .max)
        var blocks = [synthetic.blocks[0]]
        for height in 1 ... length {
            let transaction = transactions[height] ?? synthetic.blocks[height].transactions[0]
            let header = minedHeader(previousHash: blocks[height - 1].hash,
                                     merkleRoot: transaction.txid,
                                     time: synthetic.blocks[height].header.time)
            blocks.append(Block(header: header, transactions: [transaction]))
        }
        return blocks
    }

    private struct Fixture: Sendable {
        let directory: TempDir
        let node: LoopbackNode
        let pool: PeerPool
        let headers: HeaderChain
        let filters: FilterSync
        let broadcaster: TxBroadcaster

        init(blocks: [Block], directory: TempDir, startHeight: UInt32 = 1) async throws {
            self.directory = directory
            let params = makeTestParams(genesis: blocks[0].header)
            node = LoopbackNode(params: params, chain: blocks)
            try await node.start()
            pool = PeerPool(params: params, peerCount: 1, manualPeers: [await node.endpoint],
                            peersFileURL: directory.fileURL("peers.json"))
            await pool.start()
            headers = try HeaderChain(params: params)
            filters = try FilterSync(pool: pool, chain: headers, startHeight: startHeight,
                                     storageURL: directory.fileURL("filters.json"),
                                     requiredCheckpointPeers: 1)
            broadcaster = try TxBroadcaster(pool: pool, storageURL: directory.fileURL("pending.json"),
                                            rebroadcastBaseInterval: .seconds(3_600))
        }

        func stop() async {
            await broadcaster.shutdown()
            await pool.stop()
            await node.stop()
            withExtendedLifetime(directory) {}
        }
    }

    private actor MatchGate {
        private var didReach = false
        private var reachWaiter: CheckedContinuation<Void, Never>?
        private var didRelease = false
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func reached() {
            didReach = true
            reachWaiter?.resume()
            reachWaiter = nil
        }

        func waitUntilReached() async {
            guard !didReach else { return }
            await withCheckedContinuation { reachWaiter = $0 }
        }

        func release() {
            didRelease = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }

        func waitForRelease() async {
            guard !didRelease else { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }
    }
}
