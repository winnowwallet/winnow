import Foundation
import Testing
import TestSupport
@testable import WalletCore

@Suite("Explicit fee resolution")
struct FeeResolutionTests {
    @Test("an explicit cap reports a higher peer floor instead of silently pricing below it")
    func cappedFloor() {
        let quote = FeePolicy.resolution(estimated: 10, observed: [5],
                                         floorSatPerVByte: 200, peerFloorCap: 120)
        #expect(quote.rate == 120)
        #expect(quote.clampedFloor == 200)
        let override = FeePolicy.resolution(override: 250, floorSatPerVByte: 200, peerFloorCap: 120)
        #expect(override.rate == 250)
        #expect(override.clampedFloor == nil)
        let observed = FeePolicy.resolution(observed: [300], floorSatPerVByte: 200, peerFloorCap: 120)
        #expect(observed.rate == 300)
        #expect(observed.clampedFloor == nil)
    }

    @Test("estimates cannot undercut our observed median and overrides remain explicit")
    func estimateOrder() {
        #expect(FeePolicy.resolution(estimated: 1, observed: [10, 30]).rate == 20)
        #expect(FeePolicy.resolution(estimated: 40, observed: [10, 30]).rate == 40)
        #expect(FeePolicy.resolution(override: 1, estimated: 40, observed: [30]).rate == 1)
        #expect(FeePolicy.resolution(priority: .high).rate == 12)
    }

    @Test("invalid inputs fall through rather than reaching coin selection",
          arguments: [Double.nan, .infinity, -.infinity, -1, 0, 10_001])
    func invalidRates(_ rate: Double) {
        let quote = FeePolicy.resolution(override: rate, estimated: rate, observed: [rate, 7],
                                         floorSatPerVByte: rate, peerFloorCap: 120)
        #expect(quote.rate == 7)
        #expect(quote.clampedFloor == nil)
    }

    @Test("the shared default caps automatic peer-driven fees and reports a required decision")
    func defaultUnchanged() {
        #expect(FeePolicy.resolve(floorSatPerVByte: 200) == 120)
        #expect(FeePolicy.resolution(floorSatPerVByte: 200).rate == 120)
        #expect(FeePolicy.resolution(floorSatPerVByte: 200).clampedFloor == 200)
        #expect(FeePolicy.resolution(floorSatPerVByte: 200, peerFloorCap: nil).rate == 200)
    }

    @Test("the live pool uses configured-seat majority rather than the first or highest report")
    func livePoolMajority() async throws {
        let synthetic = makeSyntheticChain()
        let nodes = (0 ..< 3).map { _ in LoopbackNode(params: synthetic.params, chain: synthetic.blocks) }
        for node in nodes { try await node.start() }
        var endpoints: [PeerEndpoint] = []
        for node in nodes { endpoints.append(await node.endpoint) }
        let pool = PeerPool(params: synthetic.params, peerCount: 3, manualPeers: endpoints)
        await pool.start()
        defer { Task { await pool.stop(); for node in nodes { await node.stop() } } }
        #expect(await pool.connectedPeers().count == 3)
        try await nodes[0].send(.feefilter(200_000))
        #expect(try await Self.eventually { await pool.feeFilterFloorSatPerVByte(aggregation: .strictest) == 200 })
        #expect(await pool.feeFilterFloorSatPerVByte() == nil)
        try await nodes[1].send(.feefilter(2_000))
        #expect(try await Self.eventually { await pool.feeFilterFloorSatPerVByte() == 2 })
        try await nodes[2].send(.feefilter(3_000))
        #expect(try await Self.eventually { await pool.feeFilterFloorSatPerVByte() == 3 })
        #expect(await pool.feeFilterFloorSatPerVByte(aggregation: .strictest) == 200)
    }

    private static func eventually(_ condition: () async -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("a lone reporting peer cannot impose a floor on a three-seat pool")
    func seatMajority() {
        #expect(FeePolicy.seatMajorityFloor(reported: [200], seats: 3) == nil)
        #expect(FeePolicy.seatMajorityFloor(reported: [2, 200], seats: 3) == 2)
        #expect(FeePolicy.seatMajorityFloor(reported: [2, 3, 200], seats: 3) == 3)
        #expect(FeePolicy.seatMajorityFloor(reported: [200], seats: 1) == 200)
        #expect(FeePolicy.seatMajorityFloor(reported: [], seats: 0) == nil)
        #expect(FeePolicy.seatMajorityFloor(reported: [.nan, 200], seats: 3) == nil)
    }
}
