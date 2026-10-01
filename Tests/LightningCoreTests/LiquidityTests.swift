import Foundation
import WalletCore
import XCTest
@testable import LightningCore

final class LiquidityTests: XCTestCase {
    private func info() throws -> LightningLiquidity.Info {
        try LightningLiquidity.decode(LightningLiquidity.Info.self, from: Data("""
        {"min_required_channel_confirmations":0,"min_funding_confirms_within_blocks":6,"max_channel_expiry_blocks":13140,
         "min_initial_client_balance_sat":"0","max_initial_client_balance_sat":"0","min_initial_lsp_balance_sat":"150000",
         "max_initial_lsp_balance_sat":"16000000","min_channel_balance_sat":"150000","max_channel_balance_sat":"16000000"}
        """.utf8))
    }
    func testProviderRequestsRequireConfirmedPrivateChannelWithinLimits() throws {
        let info = try info(), request = try info.request(capacitySat: 150_000)
        XCTAssertEqual(request.requiredChannelConfirmations, 3)
        XCTAssertEqual(request.clientBalanceSat, "0")
        XCTAssertFalse(request.announceChannel)
        XCTAssertEqual(request.channelExpiryBlocks, 13_140)
        XCTAssertThrowsError(try info.request(capacitySat: 149_999))
        XCTAssertThrowsError(try info.request(capacitySat: .max))
        let bytes = try LightningLiquidity.encoder().encode(request)
        let message = try LightningLiquidity.message(method: "lsps1.create_order", params: bytes, id: "test")
        XCTAssertEqual(message.type, 37913)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: message.payload) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "lsps1.create_order")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["lsp_balance_sat"] as? String, "150000")
    }
    func testResponseMatchesIdAndHandlesNullErrorAndExplicitRefusal() throws {
        let success = try LightningLiquidity.response(.init(type: 37913, payload: Data("""
        {"jsonrpc":"2.0","id":"a","error":null,"result":{"minimum":1}}
        """.utf8)))
        XCTAssertEqual(success.id, "a")
        XCTAssertEqual(try JSONDecoder().decode([String: Int].self, from: success.result.get()), ["minimum": 1])
        let refused = try LightningLiquidity.response(.init(type: 37913, payload: Data("""
        {"jsonrpc":"2.0","id":"b","result":null,"error":{"code":1,"message":"Unavailable"}}
        """.utf8)))
        XCTAssertThrowsError(try refused.result.get())
        XCTAssertThrowsError(try LightningLiquidity.response(.init(type: 37913, payload: Data("""
        {"jsonrpc":"2.0","id":"b","result":{},"error":{"message":"Refused"}}
        """.utf8))))
    }
    func testQuoteRejectsMismatchedAmountNetworkTermsAndExpiry() throws {
        let request = try info().request(capacitySat: 150_000)
        let invoice = try Bolt11Invoice.encode(network: .mainnet, amountMsat: 5_000_000,
            hash: Data(repeating: 2, count: 32), secret: Data(repeating: 3, count: 32), nodeSecret: Data(repeating: 1, count: 32),
            route: nil, timestamp: 1_790_000_000)
        var object: [String: Any] = ["order_id": "order-a", "order_state": "CREATED", "lsp_balance_sat": "150000",
            "client_balance_sat": "0", "required_channel_confirmations": 3, "funding_confirms_within_blocks": 6,
            "channel_expiry_blocks": 13140, "announce_channel": false,
            "payment": ["bolt11": ["state": "EXPECT_PAYMENT", "expires_at": "2026-09-27T12:00:00Z",
                        "fee_total_sat": "5000", "order_total_sat": "5000", "invoice": invoice]]]
        func decode() throws -> LightningLiquidity.Order {
            try LightningLiquidity.decode(LightningLiquidity.Order.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertEqual(try decode().validate(request: request, network: .mainnet, now: 1_790_000_001), 5000)
        XCTAssertThrowsError(try decode().validate(request: request, network: .signet, now: 1_790_000_001))
        XCTAssertThrowsError(try decode().validate(request: request, network: .mainnet, now: 1_790_003_600))
        object["lsp_balance_sat"] = "100000"
        XCTAssertThrowsError(try decode().validate(request: request, network: .mainnet, now: 1_790_000_001))
        object["lsp_balance_sat"] = "150000"; object["announce_channel"] = true
        XCTAssertThrowsError(try decode().validate(request: request, network: .mainnet, now: 1_790_000_001))
        object["announce_channel"] = false
        object["payment"] = ["bolt11": ["state": "EXPECT_PAYMENT", "expires_at": "2026-09-27T12:00:00Z",
            "fee_total_sat": "6000", "order_total_sat": "6000", "invoice": invoice]]
        XCTAssertThrowsError(try decode().validate(request: request, network: .mainnet, now: 1_790_000_001))
    }
}
