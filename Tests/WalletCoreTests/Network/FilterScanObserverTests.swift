import Foundation
import Testing
import TestSupport
@testable import WalletCore

@Suite("Additional compact-filter consumers")
struct FilterScanObserverTests {
    private enum Failure: Error { case consumerWrite }
    private actor Consumer {
        let script: Data
        var scripts: [Data] = []
        var revision: UInt64 = 0
        var blocks: [FilterScannedBlock] = []
        let addAt: UInt32?
        var failAt: UInt32?
        init(script: Data, addAt: UInt32? = nil, failAt: UInt32? = nil) {
            self.script = script; self.addAt = addAt; self.failAt = failAt
        }
        func watch() -> FilterWatchSet { FilterWatchSet(scripts: scripts, revision: revision) }
        func addWatch() { scripts = [script]; revision += 1 }
        func receive(_ block: FilterScannedBlock) throws {
            if block.height == failAt { throw Failure.consumerWrite }
            blocks.append(block)
            if block.height == addAt { addWatch() }
        }
        var observer: FilterScanObserver {
            FilterScanObserver(watches: { await self.watch() }, scanned: { try await self.receive($0) })
        }
    }

    @Test("Refresh watches between blocks and deliver every verified height in chain order")
    func dynamicWatches() async throws {
        let fixture = makeSyntheticChain(length: 6, watchHeight: 3)
        let node = LoopbackNode(params: fixture.params, chain: fixture.blocks, reverseFilters: true)
        try await node.start()
        let pool = PeerPool(params: fixture.params, peerCount: 1, manualPeers: [await node.endpoint])
        defer { Task { await pool.stop(); await node.stop() } }
        await pool.start()
        let headers = try HeaderChain(params: fixture.params)
        let filters = try FilterSync(pool: pool, chain: headers, startHeight: 1, requiredCheckpointPeers: 1)
        let consumer = Consumer(script: fixture.watchScript, addAt: 2)
        let matches = MatchCollector()
        try await filters.sync(watchScripts: [], observer: consumer.observer) { matches.add($0) }
        let blocks = await consumer.blocks
        #expect(blocks.map(\.height) == [1, 2, 3, 4, 5, 6])
        #expect(blocks.map(\.watchRevision) == [0, 0, 1, 1, 1, 1])
        #expect(blocks.compactMap { $0.block == nil ? nil : $0.height } == [3])
        #expect(matches.matches.map(\.height) == [3])
        #expect(blocks[2].block == fixture.blocks[3])
        #expect(await filters.nextScanHeight == 7)
    }

    @Test("Consumer persistence failure prevents the shared batch frontier advancing")
    func failedConsumer() async throws {
        let fixture = makeSyntheticChain(length: 6, watchHeight: 3)
        let node = LoopbackNode(params: fixture.params, chain: fixture.blocks)
        try await node.start()
        let pool = PeerPool(params: fixture.params, peerCount: 1, manualPeers: [await node.endpoint])
        defer { Task { await pool.stop(); await node.stop() } }
        await pool.start()
        let headers = try HeaderChain(params: fixture.params)
        let filters = try FilterSync(pool: pool, chain: headers, startHeight: 1, requiredCheckpointPeers: 1)
        let consumer = Consumer(script: fixture.watchScript, failAt: 4)
        await #expect(throws: Failure.consumerWrite) {
            try await filters.sync(watchScripts: [], observer: consumer.observer) { _ in }
        }
        #expect(await headers.height == 6)
        #expect(await consumer.blocks.map(\.height) == [1, 2, 3])
        #expect(await filters.nextScanHeight == 1)
    }

    @Test("Late watches catch up through the same scanner after an explicit rewind")
    func lateWatch() async throws {
        let fixture = makeSyntheticChain(length: 6, watchHeight: 3)
        let node = LoopbackNode(params: fixture.params, chain: fixture.blocks)
        try await node.start()
        let pool = PeerPool(params: fixture.params, peerCount: 1, manualPeers: [await node.endpoint])
        defer { Task { await pool.stop(); await node.stop() } }
        await pool.start()
        let headers = try HeaderChain(params: fixture.params)
        let filters = try FilterSync(pool: pool, chain: headers, startHeight: 1, requiredCheckpointPeers: 1)
        let consumer = Consumer(script: fixture.watchScript)
        try await filters.sync(watchScripts: [], observer: consumer.observer) { _ in }
        #expect(await consumer.blocks.allSatisfy { $0.block == nil })
        await consumer.addWatch()
        try await filters.rollBack(to: 0)
        try await filters.sync(watchScripts: [], observer: consumer.observer) { _ in }
        #expect(await consumer.blocks.compactMap { $0.block == nil ? nil : $0.height } == [3])
        #expect(await filters.nextScanHeight == 7)
    }
}
