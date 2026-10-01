@testable import WinnowApp
import Foundation
import LightningCore
import WalletCore
import XCTest

@MainActor
final class LightningReceivingTests: XCTestCase {
    private final class Denied: DeviceAuthenticating {
        func authenticate(reason: String) async throws { throw CancellationError() }
    }
    private func directory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "receiving-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testFreshMainnetDefaultsToInstantReceivingWithoutOpeningChannels() async throws {
        let controller = LightningAppController(network: .mainnet, keys: InMemoryStoreKeyVault())
        try await controller.prepare(directory: directory(), headers: HeaderChain(params: .mainnet))
        XCTAssertEqual(LightningProviders.available(network: .mainnet).map(\.id), ["megalith-lsps2", "olympus", "megalith", "lnserver"])
        XCTAssertEqual(controller.profile, LightningProviders.mainnet[0].profile)
        XCTAssertEqual(controller.profile?.liquidityProvider, "megalith-lsps2")
        XCTAssertTrue(controller.supportsJIT)
        XCTAssertEqual(LightningProviders.mainnet.filter(\.jit).count, 1, "only the LSPS2 node is instant")
        for provider in LightningProviders.mainnet { try provider.profile.validate(network: .mainnet) }
        XCTAssertTrue(controller.channels.isEmpty)
        XCTAssertTrue(controller.payments.isEmpty)
        XCTAssertEqual(controller.maximumReceivableSat, 0)
        XCTAssertTrue(LightningProviders.available(network: .signet).isEmpty)
        XCTAssertTrue(LightningProviders.available(network: .regtest).isEmpty)
        XCTAssertNil(LightningProviders.recommended(network: .regtest))
        do {
            _ = try await controller.createReceiveInvoice(amountSat: 21, model: makeModel(network: .mainnet))
            XCTFail("fresh wallet invented receiving capacity")
        } catch LightningError.invalidState {}
        do {
            try await controller.prepareLiquidity(model: makeModel(network: .mainnet))
            XCTFail("provider setup ran before the first verified chain scan")
        } catch let LightningLiquidityError.provider(reason) {
            XCTAssertTrue(reason.contains("Bitcoin is still syncing"), reason)
        }
        XCTAssertNil(controller.liquidityInfo)
        XCTAssertNil(controller.liquidityQuote)
        XCTAssertTrue(controller.channels.isEmpty)
    }
    func testBuiltinProviderIdentityAndNetworkCannotBeReplacedInImportedProfile() throws {
        let recommended = LightningProviders.mainnet[0].profile
        let bytes = try JSONEncoder().encode(recommended)
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertThrowsError(try LightningProfile.parse(text, network: .signet))
        XCTAssertThrowsError(try LightningProfile.parse(text.replacingOccurrences(of: recommended.host, with: "127.0.0.1"), network: .mainnet))
    }
    /// A wallet that already used a provider is never moved by a new default.
    func testStoredSetupOrderKeepsItsProviderWhenTheDefaultChanges() async throws {
        let root = directory(), keys = InMemoryStoreKeyVault()
        let olympus = try XCTUnwrap(LightningProviders.mainnet.first { $0.id == "olympus" }).profile
        var controller: LightningAppController! = LightningAppController(network: .mainnet, keys: keys)
        try await controller.prepare(directory: root, headers: HeaderChain(params: .mainnet))
        try controller.storeLiquidityQuote(quote(profile: olympus))
        await controller.stop(); controller = nil
        let reopened = LightningAppController(network: .mainnet, keys: keys)
        try await reopened.prepare(directory: root, headers: HeaderChain(params: .mainnet))
        XCTAssertEqual(reopened.profile, olympus)
        XCTAssertEqual(reopened.liquidityQuote?.profile, olympus)
        XCTAssertFalse(reopened.supportsJIT)
    }
    private func megalithMenu(validFor seconds: UInt64 = 3600) throws -> LightningJIT.Menu {
        let validUntil = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(LightningAppController.now + seconds)))
        return try LightningJIT.Menu.decode(Data("""
        {"opening_fee_params_menu":[{"min_fee_msat":"3514000","proportional":14000,"valid_until":"\(validUntil)",
         "min_lifetime":13140,"max_client_to_self_delay":512,"min_payment_size_msat":"3515000",
         "max_payment_size_msat":"16000000000","promise":"p"}]}
        """.utf8), now: LightningAppController.now)
    }
    func testInstantReceiveShowsTheFeeBeforeAnythingIsBought() async throws {
        let controller = LightningAppController(network: .mainnet, keys: InMemoryStoreKeyVault())
        try await controller.prepare(directory: directory(), headers: HeaderChain(params: .mainnet))
        XCTAssertThrowsError(try controller.quoteJIT(amountSat: 30_000), "no terms fetched yet")
        do {
            try await controller.prepareJIT(model: makeModel(network: .mainnet))
            XCTFail("terms were requested before the first verified chain scan")
        } catch let LightningLiquidityError.provider(reason) { XCTAssertTrue(reason.contains("Bitcoin is still syncing"), reason) }
        XCTAssertNil(controller.jitMenu)
        controller.jitMenu = try megalithMenu()
        XCTAssertEqual(controller.smallestJITPaymentSat, 23_514)
        let quote = try controller.quoteJIT(amountSat: 30_000)
        XCTAssertEqual(quote.feeSat, 3_514)
        XCTAssertEqual(quote.receivedSat, 26_486)
        XCTAssertEqual(quote.lifetimeDays, 91)
        XCTAssertThrowsError(try controller.quoteJIT(amountSat: 23_513), "would leave less than a channel")
        XCTAssertThrowsError(try controller.quoteJIT(amountSat: .max), "overflow")
        do { _ = try await controller.approveJIT(quote, model: makeModel(network: .mainnet, deviceAuthenticator: Denied())); XCTFail() }
        catch LightningError.invalidState {} // not connected: nothing is bought and nothing is asked
    }
    private func quote(profile: LightningProfile) throws -> LightningAppController.LiquidityQuote {
        let info = try LightningLiquidity.decode(LightningLiquidity.Info.self, from: Data("""
        {"min_required_channel_confirmations":3,"min_funding_confirms_within_blocks":6,"max_channel_expiry_blocks":13140,
         "min_initial_client_balance_sat":"0","max_initial_client_balance_sat":"0","min_initial_lsp_balance_sat":"100000",
         "max_initial_lsp_balance_sat":"10000000","min_channel_balance_sat":"100000","max_channel_balance_sat":"10000000"}
        """.utf8))
        let request = try info.request(capacitySat: 100_000)
        let invoice = try Bolt11Invoice.encode(network: .regtest, amountMsat: 5_000_000,
            hash: Data(repeating: 2, count: 32), secret: Data(repeating: 3, count: 32), nodeSecret: Data(repeating: 1, count: 32),
            route: nil, timestamp: LightningAppController.now)
        let object: [String: Any] = ["order_id": "test-order", "order_state": "CREATED", "lsp_balance_sat": "100000",
            "client_balance_sat": "0", "required_channel_confirmations": 3, "funding_confirms_within_blocks": 6,
            "channel_expiry_blocks": 13140, "announce_channel": false,
            "payment": ["bolt11": ["state": "EXPECT_PAYMENT", "expires_at": "2099-01-01T00:00:00Z",
                        "fee_total_sat": "5000", "order_total_sat": "5000", "invoice": invoice]]]
        let order = try LightningLiquidity.decode(LightningLiquidity.Order.self, from: JSONSerialization.data(withJSONObject: object))
        return .init(profile: profile, request: request, order: order, feeSat: 5000)
    }
    func testCancelledSetupApprovalKeepsInvoiceUnapprovedAndAcceptedOrderSurvivesRelaunch() async throws {
        let root = directory(), keys = InMemoryStoreKeyVault()
        var controller: LightningAppController! = LightningAppController(network: .regtest, keys: keys)
        try await controller.prepare(directory: root, headers: HeaderChain(params: .regtest))
        let profile = LightningProfile(network: "regtest", name: "Test", peer: try ChannelKeys.publicKey(secret: Data(repeating: 1, count: 32)).hex,
            host: "127.0.0.1", port: 1, route: nil, receive: nil)
        try await controller.saveProfile(profile, model: makeModel(network: .regtest))
        let quote = try quote(profile: profile)
        controller.liquidityQuote = quote; try controller.storeLiquidityQuote(quote)
        let path = root.appending(path: "lightning/liquidity.json"), before = try Data(contentsOf: path)
        do {
            try await controller.acceptLiquidityQuote(model: makeModel(network: .regtest, deviceAuthenticator: Denied()))
            XCTFail("canceled approval exposed a setup invoice")
        } catch is CancellationError {}
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertFalse(try XCTUnwrap(controller.liquidityQuote).accepted)
        try await controller.acceptLiquidityQuote(model: makeModel(network: .regtest))
        XCTAssertTrue(try XCTUnwrap(controller.liquidityQuote).accepted)
        await controller.stop()
        controller = nil // release the journal's exclusive writer lock before reopening
        let reopened = LightningAppController(network: .regtest, keys: keys)
        try await reopened.prepare(directory: root, headers: HeaderChain(params: .regtest))
        let restored = try XCTUnwrap(reopened.liquidityQuote)
        XCTAssertTrue(restored.accepted)
        XCTAssertEqual(restored.order.orderId, quote.order.orderId)
        XCTAssertEqual(restored.invoice, quote.invoice)
        XCTAssertTrue(reopened.payments.isEmpty, "approving a fee must not automatically pay it")
        let other = LightningProfile(network: "regtest", name: "Other", peer: try ChannelKeys.publicKey(secret: Data(repeating: 4, count: 32)).hex,
            host: "127.0.0.1", port: 2, route: nil, receive: nil)
        do { try await reopened.saveProfile(other, model: makeModel(network: .regtest)); XCTFail("switched provider with approved order") }
        catch LightningError.invalidState {}
    }

    func testPausedUnpaidOrderRetainsExpiryAndCannotSendPaymentAcrossRestart() async throws {
        let root = directory(), keys = InMemoryStoreKeyVault(), model = makeModel(network: .regtest)
        var controller: LightningAppController? = LightningAppController(network: .regtest, keys: keys)
        try await controller!.prepare(directory: root, headers: HeaderChain(params: .regtest))
        let profile = LightningProfile(network: "regtest", name: "Test", peer: try ChannelKeys.publicKey(secret: Data(repeating: 1, count: 32)).hex,
            host: "127.0.0.1", port: 1, route: nil, receive: nil)
        try await controller!.saveProfile(profile, model: model)
        let unpaid = try quote(profile: profile)
        controller!.liquidityQuote = unpaid; try controller!.storeLiquidityQuote(unpaid)
        try await controller!.acceptLiquidityQuote(model: model)
        try controller!.cancelLiquiditySetup(model: model)
        XCTAssertFalse(controller!.liquidityQuote!.accepted)
        XCTAssertNotNil(controller!.liquidityQuote!.cancelledAt)
        XCTAssertEqual(controller!.liquidityQuote!.order.orderId, unpaid.order.orderId)
        XCTAssertEqual(controller!.liquidityQuote!.order.payment.bolt11?.expiresAt, unpaid.order.payment.bolt11?.expiresAt)
        XCTAssertTrue(controller!.payments.isEmpty)
        XCTAssertTrue(controller!.channels.isEmpty)
        await controller!.stop(); controller = nil
        let reopened = LightningAppController(network: .regtest, keys: keys)
        try await reopened.prepare(directory: root, headers: HeaderChain(params: .regtest))
        let saved = try XCTUnwrap(reopened.liquidityQuote)
        XCTAssertFalse(saved.isPayable(network: .regtest, now: LightningAppController.now))
        XCTAssertTrue(saved.isActive(network: .regtest, now: LightningAppController.now))
        XCTAssertEqual(saved.order.orderId, unpaid.order.orderId)
        XCTAssertEqual(saved.invoice, unpaid.invoice)
        try await reopened.acceptLiquidityQuote(model: model)
        XCTAssertNil(reopened.liquidityQuote?.cancelledAt)
        XCTAssertTrue(reopened.payments.isEmpty)
    }
}
