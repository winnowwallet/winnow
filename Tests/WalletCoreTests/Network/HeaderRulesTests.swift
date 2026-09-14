import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// The header rules the independent review of 2026-09-14 added (IR-002,
/// IR-027): a retarget the checkpoint cannot verify exactly is still bounded
/// at four times easier, a header dated more than two hours ahead is
/// refused, and a primary that claims a taller tip and then withholds it is
/// condemned rather than trusted. Each was observed failing against the
/// code it guards before the guard was written.
@Suite("Header rules")
struct HeaderRulesTests {
    private static func header(time: UInt32, bits: UInt32) -> BlockHeader {
        BlockHeader(version: 1, previousHash: Data(repeating: 0, count: 32),
                    merkleRoot: Data(repeating: 0, count: 32), time: time, bits: bits, nonce: 0)
    }

    @Test("an unverifiable adjustment may ease at most four times, never to difficulty 1")
    func boundedAdjustment() throws {
        let params = NetworkParams.mainnet
        let previous = Self.header(time: 0, bits: 0x1703_1ABE)
        let previousTarget = try #require(UInt256.target(compact: previous.bits))
        func check(_ bits: UInt32) throws {
            try HeaderChain.requireBoundedAdjustment(Self.header(time: 0, bits: bits), previous: previous,
                                                     params: params, height: 901_152)
        }
        // Four times easier is Core's own clamp, and harder is always fine.
        #expect(throws: Never.self) { try check(previousTarget.multiplied(by: 4).compact) }
        #expect(throws: Never.self) { try check(previousTarget.shiftedRight(2).compact) }
        #expect(throws: Never.self) { try check(previous.bits) }
        // Eight times easier, and difficulty 1 — what the gap accepted — are not.
        #expect(throws: HeaderChainError.unexpectedDifficulty(height: 901_152)) {
            try check(previousTarget.multiplied(by: 8).compact)
        }
        #expect(throws: HeaderChainError.unexpectedDifficulty(height: 901_152)) { try check(0x1D00_FFFF) }
    }

    @Test("a header dated more than two hours ahead of the clock is refused; two hours is accepted")
    func futureDrift() async throws {
        let now: UInt32 = 1_700_000_000
        let genesis = minedHeader(previousHash: Data(repeating: 0, count: 32),
                                  merkleRoot: Data(repeating: 1, count: 32), time: now - 600)
        let params = makeTestParams(genesis: genesis)
        let chain = try HeaderChain(params: params, now: { now })

        let tooFar = minedHeader(previousHash: genesis.hash, merkleRoot: Data(repeating: 2, count: 32),
                                 time: now + HeaderChain.maximumFutureDrift + 1)
        await #expect(throws: HeaderChainError.timestampTooFarInFuture(height: 1)) {
            try await chain.connect([tooFar])
        }
        #expect(await chain.height == 0)

        let atLimit = minedHeader(previousHash: genesis.hash, merkleRoot: Data(repeating: 3, count: 32),
                                  time: now + HeaderChain.maximumFutureDrift)
        try await chain.connect([atLimit])
        #expect(await chain.height == 1)
    }

    @Test("a primary that claims a taller tip and delivers no headers is condemned, not trusted")
    func withholdingPrimaryCondemned() async throws {
        let synthetic = makeSyntheticChain(length: 6)
        let liar = LoopbackNode(params: synthetic.params, chain: synthetic.blocks,
                                claimedStartHeight: 5_000, emptyHeaders: true)
        try await liar.start()
        defer { Task { await liar.stop() } }
        let endpoint = await liar.endpoint
        let pool = PeerPool(params: synthetic.params, peerCount: 1, manualPeers: [endpoint])
        await pool.start()
        let chain = try HeaderChain(params: synthetic.params)

        var thrown: Error?
        do {
            try await pool.syncHeaders(chain, timeoutPerPeer: .seconds(2), maxAttempts: 1)
        } catch { thrown = error }
        guard case .exhausted? = thrown as? PeerPoolHeaderSyncError else {
            Issue.record("expected the sync to exhaust its one peer, got \(String(describing: thrown))")
            return
        }
        #expect(await pool.rejectionReason(endpoint)?.contains("delivered no headers") == true)
        #expect(await pool.connectedPeers().isEmpty)
        #expect(await chain.height == 0)
        await pool.stop()
    }

    @Test("a primary that is merely behind keeps its seat")
    func behindPrimaryKept() async throws {
        let synthetic = makeSyntheticChain(length: 6)
        let behind = LoopbackNode(params: synthetic.params, chain: synthetic.blocks,
                                  claimedStartHeight: 0, emptyHeaders: true)
        try await behind.start()
        defer { Task { await behind.stop() } }
        let endpoint = await behind.endpoint
        let pool = PeerPool(params: synthetic.params, peerCount: 1, manualPeers: [endpoint])
        await pool.start()
        let chain = try HeaderChain(params: synthetic.params)

        try await pool.syncHeaders(chain, timeoutPerPeer: .seconds(2), maxAttempts: 1)
        #expect(await pool.rejectionReason(endpoint) == nil)
        #expect(await pool.connectedPeers().count == 1)
        await pool.stop()
    }
}
