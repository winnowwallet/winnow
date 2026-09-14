import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// The filter-commitment vote weighed by source class (IR-001). The pool's
/// diversity rule lets one class hold two of three seats, so a strict
/// majority can be one acquisition channel outvoting the only independent
/// witness. Two peers reached as manual entries play that channel; a peer
/// reached from the persisted good-peers file plays the other. The register
/// itself noted that "two liars would agree and form a majority for the lie"
/// and that no test exercised it; these do, and each was observed failing
/// against the code it guards before the guard was written.
@Suite("Filter consensus across source classes")
struct FilterConsensusTests {
    private struct Fixture {
        let synthetic: SyntheticChain
        let nodes: [LoopbackNode]
        let endpoints: [PeerEndpoint]
        let peersFile: URL
        let pool: PeerPool
        let sync: FilterSync

        var manualA: PeerEndpoint { endpoints[0] }
        var manualB: PeerEndpoint { endpoints[1] }
        var persisted: PeerEndpoint { endpoints[2] }

        func stop() {
            for node in nodes { Task { await node.stop() } }
            let pool = pool
            Task { await pool.stop() }
        }
    }

    private final class Matches: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        var count: Int { lock.withLock { stored } }
        func add(_: BlockMatch) { lock.withLock { stored += 1 } }
    }

    /// Two manual peers seated first, one persisted peer seated last, all on
    /// one chain past the checkpoint interval so every cfcheckpt carries an
    /// entry to disagree about. A salt makes a node lie about its filter
    /// commitments; two nodes with the same salt tell the same lie.
    private static func fixture(manualLies: [UInt8?], persistedLie: UInt8? = nil,
                                chainLength: Int = 1_001) async throws -> Fixture {
        let synthetic = makeSyntheticChain(length: chainLength, watchHeight: 3)
        func node(_ salt: UInt8?, delay: Duration) -> LoopbackNode {
            guard let salt else {
                return LoopbackNode(params: synthetic.params, chain: synthetic.blocks, versionDelay: delay)
            }
            return LoopbackNode(params: synthetic.params, chain: synthetic.blocks,
                                lieAboutFilterCommitments: true, lieSalt: salt, versionDelay: delay)
        }
        let nodes = manualLies.enumerated().map { node($0.element, delay: .milliseconds(50 * $0.offset)) }
            + [node(persistedLie, delay: .milliseconds(300))]
        for node in nodes { try await node.start() }
        var endpoints: [PeerEndpoint] = []
        for node in nodes { endpoints.append(await node.endpoint) }

        let peersFile = tempFileURL("consensus-peers.json")
        let stored = PersistedPeers([PeerCandidate(endpoint: endpoints[2], source: .persisted)])
        try JSONEncoder().encode(stored).write(to: peersFile)
        let pool = PeerPool(params: synthetic.params, peerCount: 3,
                            manualPeers: Array(endpoints.prefix(2)), peersFileURL: peersFile)
        await pool.start()
        let sync = try FilterSync(pool: pool, chain: try HeaderChain(params: synthetic.params),
                                  startHeight: 1, storageURL: tempFileURL("consensus-progress.json"),
                                  requiredCheckpointPeers: 3)
        return Fixture(synthetic: synthetic, nodes: nodes, endpoints: endpoints,
                       peersFile: peersFile, pool: pool, sync: sync)
    }

    private static func persistedEndpoints(_ url: URL) throws -> Set<PeerEndpoint> {
        Set(PersistedPeers.decode(try Data(contentsOf: url))?.map(\.endpoint) ?? [])
    }

    @Test("two liars of one class outvoting an honest peer of another is no majority: nothing pinned, nobody banned")
    func singleClassMajorityIsNoMajority() async throws {
        let fixture = try await Self.fixture(manualLies: [7, 7])
        defer { fixture.stop() }
        #expect(await fixture.pool.connectedPeers().count == 3)
        let matches = Matches()

        await #expect(throws: FilterSyncError.self) {
            try await fixture.sync.sync(watchScripts: [fixture.synthetic.watchScript]) { matches.add($0) }
        }
        // The lie was not adopted: no filter was scanned and nothing was pinned.
        #expect(matches.count == 0)
        #expect(await fixture.sync.nextScanHeight == 1)
        #expect(await fixture.sync.pinnedFilterHeadersForTest.isEmpty)
        // The honest witness was cooled off with the others, not condemned: it
        // is still in the persisted good-peers file, and the reason recorded
        // is the dispute, not a "mismatch" that names it the liar.
        #expect(try Self.persistedEndpoints(fixture.peersFile).contains(fixture.persisted))
        #expect(await fixture.pool.rejectionReason(fixture.persisted)?.contains("outvotes") == true)
        #expect(await fixture.pool.rejectionReason(fixture.persisted)?.contains("mismatch") != true)
    }

    @Test("a majority that spans two classes still bans the liar and completes")
    func crossClassMajorityBansTheLiar() async throws {
        let fixture = try await Self.fixture(manualLies: [nil, 7])
        defer { fixture.stop() }
        let matches = Matches()

        try await fixture.sync.sync(watchScripts: [fixture.synthetic.watchScript]) { matches.add($0) }
        #expect(matches.count == 1)
        // `length` counts blocks after genesis: the tip is 1,001.
        #expect(await fixture.sync.nextScanHeight == 1_002)
        #expect(await fixture.pool.rejectionReason(fixture.manualB)?.contains("cfcheckpt mismatch") == true)
        var seated: [PeerEndpoint] = []
        for peer in await fixture.pool.connectedPeers() { seated.append(await peer.endpoint) }
        #expect(!seated.contains(fixture.manualB))
        #expect(try Self.persistedEndpoints(fixture.peersFile).contains(fixture.persisted))
    }

    @Test("a pinned boundary a cross-source reference contradicts is rewound and re-verified, not fatal")
    func crossSourceReferenceRewindsAWrongPin() async throws {
        // One block past the boundary, so the frontier sits at 1,001 with the
        // wrong pin below it and there is still a block to scan.
        let fixture = try await Self.fixture(manualLies: [nil, nil], chainLength: 1_002)
        defer { fixture.stop() }
        let wrong = String(repeating: "ab", count: 32)
        try await fixture.sync.recordProgressForTest(nextScanHeight: 1_001, filterHeaders: ["1000": wrong])
        let reorgs = EventCollector<UInt32>()
        let matches = Matches()

        try await fixture.sync.sync(watchScripts: [fixture.synthetic.watchScript],
                                    onReorg: { reorgs.add($0) }) { matches.add($0) }
        // Rewound to the boundary below the disputed one — here, genesis —
        // through the same callback a reorg uses, then rescanned to the tip.
        #expect(reorgs.events == [0])
        #expect(matches.count == 1)
        #expect(await fixture.sync.nextScanHeight == 1_003)
        let repinned = await fixture.sync.pinnedFilterHeadersForTest["1000"]
        #expect(repinned != nil && repinned != wrong)
    }

    @Test("a lone peer's reference never rewinds a pin; the sync stops as before")
    func loneReferenceDoesNotRewind() async throws {
        let synthetic = makeSyntheticChain(length: 1_002, watchHeight: 3)
        let node = LoopbackNode(params: synthetic.params, chain: synthetic.blocks)
        try await node.start()
        defer { Task { await node.stop() } }
        let pool = PeerPool(params: synthetic.params, peerCount: 1, manualPeers: [await node.endpoint])
        await pool.start()
        defer { Task { await pool.stop() } }
        let sync = try FilterSync(pool: pool, chain: try HeaderChain(params: synthetic.params),
                                  startHeight: 1, storageURL: tempFileURL("lone-progress.json"),
                                  requiredCheckpointPeers: 1)
        let wrong = String(repeating: "ab", count: 32)
        try await sync.recordProgressForTest(nextScanHeight: 1_001, filterHeaders: ["1000": wrong])
        let reorgs = EventCollector<UInt32>()

        await #expect(throws: FilterSyncError.checkpointMismatch("pinned header at 1000 disagrees with cfcheckpt")) {
            try await sync.sync(watchScripts: [], onReorg: { reorgs.add($0) }) { _ in }
        }
        #expect(reorgs.events.isEmpty)
        #expect(await sync.pinnedFilterHeadersForTest["1000"] == wrong)
        #expect(await sync.nextScanHeight == 1_001)
    }
}
