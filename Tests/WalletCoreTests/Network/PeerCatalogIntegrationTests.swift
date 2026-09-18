import Foundation
import Testing
import TestSupport
@testable import WalletCore

private final class CatalogClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CensusCatalogTests().now
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); defer { lock.unlock() }; value += 8 * 86400 }
}

struct PeerCatalogIntegrationTests {
    @Test func refreshPreservesTheActiveConnectionAndResetPreservesCatalogAndManualPeers() async throws {
        let chain = makeSyntheticChain(length: 4, watchHeight: 2)
        let node = LoopbackNode(params: chain.params, chain: chain.blocks)
        try await node.start()
        let manual = await node.endpoint
        let pool = PeerPool(params: chain.params, peerCount: 1, manualPeers: [manual],
                            catalogNow: { CensusCatalogTests().now })
        await pool.start()
        let before = try #require(await pool.connectedPeers().first)
        try await pool.updateCensusCatalog(CensusCatalogTests().catalog())
        let after = try #require(await pool.connectedPeers().first)
        #expect(before === after)
        #expect(await before.isConnected)
        #expect(await pool.candidateSourcesForTest()[.init(host: "8.8.8.8", port: 8333)] == .census)
        await pool.stop()
        try await pool.forgetKnownGood()
        let candidates = await pool.candidateSourcesForTest()
        #expect(candidates[manual] == .manual)
        #expect(candidates[.init(host: "8.8.8.8", port: 8333)] == .census)
        await node.stop()
    }

    @Test func expirationDropsCatalogAndFailedRefreshKeepsGoodCatalog() async throws {
        let clock = CatalogClock()
        let downloaded = CensusCatalogTests().catalog()
        let pool = PeerPool(params: .mainnet, censusCatalog: downloaded, catalogNow: { clock.read() })
        let peer = PeerEndpoint(host: "8.8.8.8", port: 8333)
        #expect(await pool.candidateEndpointsForTest() == [peer])
        var invalid = downloaded; invalid.schemaVersion = 2
        await #expect(throws: CensusCatalog.Invalid.schema) { try await pool.updateCensusCatalog(invalid) }
        #expect(await pool.candidateEndpointsForTest() == [peer])
        clock.advance()
        #expect(await pool.candidateEndpointsForTest().isEmpty)
    }

    @Test func reshuffleAvoidsPreviousPeersAndCensusPeersAreOneSource() async {
        let fixture = CensusCatalogTests()
        var catalog = fixture.catalog()
        catalog.networks["clearnet"]!.append(.init(host: "9.9.9.9", port: 8333, userAgent: "", startHeight: 900_000))
        let previous = PeerEndpoint(host: "8.8.8.8", port: 8333)
        let pool = PeerPool(params: .mainnet, censusCatalog: catalog, catalogNow: { fixture.now }, avoidOnReset: [previous])
        #expect(await pool.candidateEndpointsForTest().first == .init(host: "9.9.9.9", port: 8333))
        let sources = await pool.candidateSourcesForTest()
        #expect(Set(sources.values) == [.census], "downloaded census peers are one trust source")
    }
}
