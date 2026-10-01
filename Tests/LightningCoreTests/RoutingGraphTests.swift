import Foundation
import XCTest
@testable import LightningCore

final class RoutingGraphTests: XCTestCase {
    private let chain = Data(repeating: 7, count: 32)
    private func key(_ n: UInt8) throws -> Data { try ChannelKeys.publicKey(secret: Data(repeating: n, count: 32)) }
    private func signed(_ payload: Data, seeds: [UInt8]) throws -> Data {
        let hash = ChannelKeys.hash(ChannelKeys.hash(payload))
        return try seeds.reduce(Data()) { try $0 + ChannelKeys.compactSignature(ChannelKeys.sign(digest: hash, secret: Data(repeating: $1, count: 32))) } + payload
    }
    private func announcement(_ id: UInt64, a: UInt8, b: UInt8, chain: Data? = nil) throws -> LightningWire.Message {
        let nodes = try [a, b].sorted { try key($0).lexicographicallyPrecedes(key($1)) }
        var w = LightningWire.Writer(); w.u16(0); w.append(chain ?? self.chain); w.u64(id)
        for seed in nodes + [11, 12] { w.append(try key(seed)) }
        return try .init(type: 256, payload: signed(w.data, seeds: nodes + [11, 12]))
    }
    private func policy(_ id: UInt64, a: UInt8, b: UInt8, timestamp: UInt32, fee: UInt32 = 1000, disabled: Bool = false) throws -> LightningWire.Message {
        var w = LightningWire.Writer(); w.append(chain); w.u64(id); w.u32(timestamp); w.u8(1)
        w.u8((try key(a).lexicographicallyPrecedes(key(b)) ? 0 : 1) | (disabled ? 2 : 0))
        w.u16(40); w.u64(1000); w.u32(fee); w.u32(0); w.u64(10_000_000)
        return try .init(type: 258, payload: signed(w.data, seeds: [a]))
    }
    func testAllAnnouncementSignaturesAndPolicyDirectionAreValidated() throws {
        var graph = LightningRoutingGraph(chain: chain)
        let valid = try announcement(123, a: 1, b: 2)
        for index in [0, 64, 128, 192] {
            var corrupt = valid.payload; corrupt[index] ^= 1
            try graph.receive(.init(type: 256, payload: corrupt), now: 100)
            XCTAssertTrue(graph.channels.isEmpty)
        }
        try graph.receive(announcement(123, a: 1, b: 2, chain: Data(repeating: 8, count: 32)), now: 100)
        XCTAssertTrue(graph.channels.isEmpty)
        try graph.receive(valid, now: 100)
        try graph.receive(policy(123, a: 1, b: 2, timestamp: 100), now: 100)
        XCTAssertEqual(graph.channels[123]?.policies.values.first?.hop.peer, try key(1))
        try graph.receive(policy(123, a: 1, b: 2, timestamp: 99, fee: 9000), now: 100)
        XCTAssertEqual(graph.channels[123]?.policies.values.first?.hop.baseMsat, 1000)
        var corrupt = try policy(123, a: 1, b: 2, timestamp: 101).payload; corrupt[0] ^= 1
        try graph.receive(.init(type: 258, payload: corrupt), now: 101)
        XCTAssertEqual(graph.channels[123]?.policies.values.first?.timestamp, 100)
        try graph.receive(policy(123, a: 1, b: 2, timestamp: 101, disabled: true), now: 101)
        XCTAssertEqual(graph.channels[123]?.policies.values.first?.disabled, true)
    }
    func testReverseSearchHonorsFeesAndDisabledEdges() throws {
        var graph = LightningRoutingGraph(chain: chain)
        for (id, a, b, fee) in [(UInt64(123), UInt8(1), UInt8(3), UInt32(3000)), (456, 1, 2, 1000), (789, 2, 3, 500)] {
            try graph.receive(announcement(id, a: a, b: b), now: 100)
            try graph.receive(policy(id, a: a, b: b, timestamp: 100, fee: fee), now: 100)
        }
        let invoice = Bolt11Invoice.Decoded(amountMsat: 5000, paymentHash: Data(repeating: 1, count: 32), paymentSecret: Data(repeating: 2, count: 32),
            payee: try key(3), timestamp: 100, expirySeconds: 3600, description: nil, descriptionHash: nil, metadata: nil,
            minimumFinalDelta: 18, features: .init(bytes: Data()), routes: [])
        let cheapest = try graph.route(from: key(1), invoice: invoice, amountMsat: 5000, feeLimitMsat: 3000, maximumDelta: 144)
        XCTAssertEqual(cheapest.hops.map(\.shortChannelID), [456, 789])
        try graph.receive(policy(456, a: 1, b: 2, timestamp: 101, fee: 1000, disabled: true), now: 101)
        XCTAssertEqual(try graph.route(from: key(1), invoice: invoice, amountMsat: 5000, feeLimitMsat: 3000, maximumDelta: 144).hops.map(\.shortChannelID), [123])
        XCTAssertThrowsError(try graph.route(from: key(1), invoice: invoice, amountMsat: 5000, feeLimitMsat: 2999, maximumDelta: 144))
        XCTAssertThrowsError(try graph.route(from: key(1), invoice: invoice, amountMsat: 500, feeLimitMsat: 3000, maximumDelta: 144))
    }
    func testNodeRequiredFeaturesRequireAuthenticNewerAnnouncement() throws {
        func node(timestamp: UInt32, bits: Set<Int>) throws -> LightningWire.Message {
            var writer = LightningWire.Writer(); let features = try LightningFeatures(bits: bits)
            writer.u16(UInt16(features.bytes.count)); writer.append(features.bytes); writer.u32(timestamp); writer.append(try key(1))
            writer.append(Data(repeating: 0, count: 35)); writer.u16(0)
            return try .init(type: 257, payload: signed(writer.data, seeds: [1]))
        }
        var graph = LightningRoutingGraph(chain: chain)
        try graph.receive(node(timestamp: 100, bits: [100]), now: 100)
        XCTAssertTrue(graph.blockedNodes.contains(try key(1)))
        try graph.receive(node(timestamp: 99, bits: []), now: 100)
        XCTAssertTrue(graph.blockedNodes.contains(try key(1)), "Older announcement cannot reenable an incompatible node")
        var corrupt = try node(timestamp: 101, bits: []).payload; corrupt[0] ^= 1
        try graph.receive(.init(type: 257, payload: corrupt), now: 101)
        XCTAssertTrue(graph.blockedNodes.contains(try key(1)))
        try graph.receive(node(timestamp: 101, bits: [101]), now: 101)
        XCTAssertFalse(graph.blockedNodes.contains(try key(1)))
        try graph.receive(node(timestamp: 500, bits: [100]), now: 101)
        XCTAssertFalse(graph.blockedNodes.contains(try key(1)), "Future timestamps cannot replace validated state")
    }
    func testOrdinaryRoutesUseSignedPoliciesAndResolveChannelIntroductions() throws {
        var graph = LightningRoutingGraph(chain: chain)
        try graph.receive(announcement(456, a: 1, b: 2), now: 100)
        try graph.receive(policy(456, a: 1, b: 2, timestamp: 100), now: 100)
        try graph.receive(announcement(789, a: 2, b: 3), now: 100)
        try graph.receive(policy(789, a: 2, b: 3, timestamp: 100, fee: 500), now: 100)
        let path = try OrdinaryBlindedPayment.path(provider: key(3), recipient: key(4),
            route: .init(peer: key(3), shortChannelID: 999, baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 40),
            token: Data(repeating: 5, count: 32), maximumExpiry: 1000, minimumMsat: 1000)
        let offer = try LightningOffer(bytes: Bolt12Encoding.serialize([.init(type: 2, value: chain), .init(type: 10, value: Data("Signed route".utf8)),
            .init(type: 16, value: path.encoded()), .init(type: 22, value: key(4))]))
        let request = try InvoiceRequest(offer: offer, chain: chain, amountMsat: 5000, now: 100,
            metadata: Data(repeating: 6, count: 32), payerSecret: Data(repeating: 7, count: 32))
        let direction = UInt8(try XCTUnwrap(graph.channels[789]?.nodes.firstIndex(of: key(3))))
        let channelPath = try BlindedPath(introduction: .channel(direction: direction, shortChannelID: 789), blinding: path.blinding, hops: path.hops)
        let unreachable = try BlindedPath(introduction: .node(key(11)), blinding: path.blinding, hops: path.hops)
        let info = try StaticInvoice.PayInfo(baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 58, minimumMsat: 1000, maximumMsat: 100_000, features: .init(bytes: Data()))
        let invoice = try Bolt12Invoice(request: request, paths: [unreachable, channelPath], payInfo: [info, info], paymentHash: Data(repeating: 8, count: 32), createdAt: 100, signingSecret: Data(repeating: 4, count: 32))
        let route = try graph.ordinaryRoute(from: key(1), invoice: invoice, feeLimitMsat: 2500, maximumDelta: 144)
        XCTAssertEqual(route.pathIndex, 1); XCTAssertEqual(route.introduction, try key(3)); XCTAssertEqual(route.hops.map(\.shortChannelID), [456, 789])
        XCTAssertEqual(try route.quote(invoice: invoice, feeLimitMsat: 2500, height: 100, maximumDelta: 144).feeMsat, 2500)
        XCTAssertEqual(try graph.offerPath(from: key(1), offer: offer), try [key(1), key(2)])
        XCTAssertThrowsError(try graph.ordinaryRoute(from: key(1), invoice: invoice, feeLimitMsat: 2499, maximumDelta: 144))
        try graph.receive(policy(456, a: 1, b: 2, timestamp: 101, disabled: true), now: 101)
        XCTAssertThrowsError(try graph.ordinaryRoute(from: key(1), invoice: invoice, feeLimitMsat: 2500, maximumDelta: 144))
    }

}
