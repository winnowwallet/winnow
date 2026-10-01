import Foundation
import XCTest
@testable import LightningCore

/// bLIP-52 (LSPS2) client terms. The menu below is Megalith LSP 2's answer
/// to lsps2.get_info on 2026-10-01, with its timestamps moved.
final class JITTests: XCTestCase {
    private let now: UInt64 = 1_790_870_000 // 2026-10-01T15:53:20Z
    private func entry(minFee: String = "3514000", ppm: UInt32 = 14_000, validUntil: String = "2026-10-01T16:53:20.486Z",
                       delay: UInt32 = 512, min: String? = "3515000", max: String? = "16000000000",
                       promise: String = "5f3b9c2a0d1e") -> [String: Any] {
        var entry: [String: Any] = ["min_fee_msat": minFee, "proportional": ppm, "valid_until": validUntil,
                                    "min_lifetime": 13_140, "max_client_to_self_delay": delay, "promise": promise]
        if let min { entry["min_payment_size_msat"] = min }
        if let max { entry["max_payment_size_msat"] = max }
        return entry
    }
    private func menu(_ entries: [[String: Any]], extra: [String: Any] = [:]) throws -> LightningJIT.Menu {
        let object = extra.merging(["opening_fee_params_menu": entries]) { $1 }
        return try LightningJIT.Menu.decode(JSONSerialization.data(withJSONObject: object), now: now)
    }

    func testOpeningFeeRoundsUpHonoursTheFloorAndRefusesOverflow() {
        XCTAssertEqual(LightningJIT.openingFee(paymentMsat: 30_000_000, minFeeMsat: 3_514_000, proportional: 14_000), 3_514_000)
        XCTAssertEqual(LightningJIT.openingFee(paymentMsat: 1_000_000_000, minFeeMsat: 3_514_000, proportional: 14_000), 14_000_000)
        XCTAssertEqual(LightningJIT.openingFee(paymentMsat: 1, minFeeMsat: 0, proportional: 1), 1, "ceil, not floor")
        XCTAssertEqual(LightningJIT.openingFee(paymentMsat: 2_000_000, minFeeMsat: 0, proportional: 500_000), 1_000_000)
        XCTAssertNil(LightningJIT.openingFee(paymentMsat: .max, minFeeMsat: 0, proportional: 2), "multiplication overflow")
        XCTAssertNil(LightningJIT.openingFee(paymentMsat: .max, minFeeMsat: 0, proportional: 1), "rounding overflow")
    }

    func testMegalithMenuQuotesTheCheapestEntryThatLeavesAChannel() throws {
        let menu = try menu([entry(), entry(minFee: "4392500", validUntil: "2026-10-02T15:53:20.530Z", min: "4393500")])
        XCTAssertEqual(menu.offers.count, 2)
        XCTAssertEqual(menu.paymentRange, 3_515_000...16_000_000_000)
        let quote = try menu.cheapest(paymentMsat: 30_000_000, now: now)
        XCTAssertEqual(quote.feeMsat, 3_514_000)
        XCTAssertEqual(quote.offer.minFeeMsat, 3_514_000)
        // Within 90 seconds of expiry the first entry can no longer be paid.
        XCTAssertEqual(try menu.cheapest(paymentMsat: 30_000_000, now: now + 3_550).feeMsat, 4_392_500)
        XCTAssertThrowsError(try menu.cheapest(paymentMsat: 3_514_999, now: now), "below every minimum")
        XCTAssertThrowsError(try menu.cheapest(paymentMsat: 16_000_000_001, now: now), "above every maximum")
        XCTAssertThrowsError(try menu.cheapest(paymentMsat: 3_515_000, now: now), "fee would leave too little to open a channel")
    }

    func testFeeMustLeaveAWholeChannel() throws {
        let offer = try XCTUnwrap(menu([entry()]).offers.first)
        XCTAssertEqual(LightningJIT.minimumDelivered, 20_000_000)
        XCTAssertThrowsError(try offer.fee(paymentMsat: 23_513_999))
        XCTAssertEqual(try offer.fee(paymentMsat: 23_514_000), 3_514_000)
        let zeroFloor = try XCTUnwrap(menu([entry(minFee: "0", ppm: 1_000_000, min: "1")]).offers.first)
        XCTAssertThrowsError(try zeroFloor.fee(paymentMsat: 50_000_000), "a fee equal to the payment delivers nothing")
    }

    func testUnusableEntriesAreLeftOffTheMenu() throws {
        let bad: [[String: Any]] = [
            entry(validUntil: "2026-10-01T15:53:19Z"), entry(validUntil: "tomorrow"), entry(minFee: "-1"),
            entry(delay: 143), entry(min: "20000000", max: "10000000"), entry(min: "lots"),
            entry(promise: String(repeating: "a", count: 513)), entry(promise: "é"), entry(promise: "\n"),
            entry(min: nil), ["min_fee_msat": "1"]
        ]
        XCTAssertTrue(try menu(bad).offers.isEmpty)
        XCTAssertNil(try menu(bad).paymentRange)
        XCTAssertEqual(try menu([entry(promise: String(repeating: "~", count: 512))]).offers.count, 1)
        XCTAssertThrowsError(try LightningJIT.Menu.decode(Data("{}".utf8), now: now))
        XCTAssertThrowsError(try LightningJIT.Menu.decode(Data("[]".utf8), now: now))
    }

    func testEarlierDraftBoundsBesideTheMenuStillApply() throws {
        let menu = try menu([entry(min: nil, max: nil)],
                            extra: ["min_payment_size_msat": "25000000", "max_payment_size_msat": "90000000"])
        XCTAssertEqual(menu.paymentRange, 25_000_000...90_000_000)
    }

    func testBuyReturnsTheProvidersParamsVerbatim() throws {
        let offer = try XCTUnwrap(menu([entry().merging(["future_field": ["nested": true]]) { $1 }]).offers.first)
        let params = try LightningJIT.buyParams(offer, paymentSizeMsat: 30_000_000)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: Any])
        XCTAssertEqual(object["payment_size_msat"] as? String, "30000000")
        let echoed = try XCTUnwrap(object["opening_fee_params"] as? [String: Any])
        XCTAssertEqual(echoed["promise"] as? String, "5f3b9c2a0d1e")
        XCTAssertEqual((echoed["future_field"] as? [String: Bool])?["nested"], true, "unknown fields survive")
        let message = try LightningLiquidity.message(method: "lsps2.buy", params: params, id: "x")
        XCTAssertEqual(message.type, 37913)
    }

    func testMegalithPurchaseAnswerParses() throws {
        let purchase = try LightningLiquidity.decode(LightningJIT.Purchase.self, from: Data("""
        {"jit_channel_scid":"16048321x13490576x41890","lsp_cltv_expiry_delta":144,"client_trusts_lsp":true}
        """.utf8))
        let validated = try purchase.validated()
        XCTAssertEqual(validated.scid, 16_048_321 << 40 | 13_490_576 << 16 | 41_890)
        XCTAssertEqual(validated.delta, 144)
        XCTAssertEqual(purchase.clientTrustsLsp, true)
        let plain = try LightningLiquidity.decode(LightningJIT.Purchase.self, from: Data("""
        {"jit_channel_scid":"1x2x3","lsp_cltv_expiry_delta":40}
        """.utf8))
        XCTAssertNil(plain.clientTrustsLsp)
        for (scid, delta) in [("0x0x0", 144), ("16777216x0x0", 144), ("1x16777216x0", 144), ("1x1x65536", 144),
                              ("1x1", 144), ("1x1x1x1", 144), ("ax1x1", 144), ("1xx1", 144), ("1x1x1", 0), ("1x1x1", 2017)] {
            let candidate = LightningJIT.Purchase(jitChannelScid: scid, lspCltvExpiryDelta: UInt32(delta), clientTrustsLsp: nil)
            XCTAssertThrowsError(try candidate.validated(), "\(scid) \(delta)")
        }
    }

    func testChannelTypeOptionsSitBesideTheCommitmentFormat() throws {
        for bits: Set<Int> in [[12], [12, 22], [12, 46], [12, 22, 46], [12, 46, 50], [12, 50]] {
            let negotiated = try ChannelFormat.negotiated(LightningFeatures(bits: bits))
            XCTAssertEqual(negotiated.format, bits.contains(22) ? .anchors : .staticRemoteKey, "\(bits)")
            XCTAssertEqual(negotiated.options.bits, bits.intersection([46, 50]), "\(bits)")
        }
        for bits: Set<Int> in [[12, 48], [22], [], [46], [12, 22, 47]] {
            XCTAssertThrowsError(try ChannelFormat.negotiated(LightningFeatures(bits: bits)), "\(bits)")
        }
    }

    func testAcceptAtDepthZeroRoundTripsWithItsOptions() throws {
        let terms = try ChannelSecrets().terms(capacity: 100_000, format: .anchors, options: [.scidAlias, .zeroConf])
        let accept = ChannelNegotiation.Accept(temporaryID: Data(repeating: 1, count: 32), minimumDepth: 0, terms: terms)
        let decoded = try ChannelNegotiation.Accept(message: accept.message())
        XCTAssertEqual(decoded.minimumDepth, 0)
        XCTAssertEqual(decoded.terms.options, [.scidAlias, .zeroConf])
        XCTAssertEqual(decoded.terms.format, .anchors)
        let deep = ChannelNegotiation.Accept(temporaryID: Data(repeating: 1, count: 32), minimumDepth: 145, terms: terms)
        XCTAssertThrowsError(try deep.message())
    }

    func testJustInTimeProvidersMayRequireAliasAndZeroConf() async throws {
        let engine = try LightningEngine(chain: Data(repeating: 7, count: 32), journal: JITJournal())
        try await engine.chainCaughtUp()
        let peer = try ChannelKeys.publicKey(secret: Data(repeating: 5, count: 32))
        try await engine.peerInitialized(peer, features: LightningFeatures(bits: [12, 14, 44, 46, 50]))
        do { try await engine.peerInitialized(peer, features: LightningFeatures(bits: [12, 14, 44, 52])); XCTFail("unknown required bit") }
        catch {}
        XCTAssertTrue(LightningFeatures.jitClient.bits.isSuperset(of: [47, 51]))
        XCTAssertFalse(LightningFeatures.jitClient.bits.contains(729), "bLIP-50: clients never set the provider bit")
        XCTAssertFalse(LightningFeatures.asyncClient.bits.contains(51))
    }

    func testInvoiceCarriesTheFinalDeltaItWasGiven() throws {
        let invoice = try Bolt11Invoice.encode(network: .regtest, amountMsat: 1_000_000, hash: Data(repeating: 1, count: 32),
            secret: Data(repeating: 2, count: 32), nodeSecret: Data(repeating: 3, count: 32), route: nil, timestamp: 1_790_000_000,
            minimumFinalDelta: 20)
        XCTAssertEqual(try Bolt11Invoice.decode(invoice, network: .regtest).minimumFinalDelta, 20)
    }
}

private final class JITJournal: LightningJournal {
    private var bytes: Data?
    func load() -> Data? { bytes }
    func store(_ snapshot: Data) throws { bytes = snapshot }
}
