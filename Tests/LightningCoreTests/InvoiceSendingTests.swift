import Foundation
import P256K
import WalletCore
import XCTest
@testable import LightningCore

final class InvoiceSendingTests: XCTestCase {
    private func key(_ seed: UInt8) throws -> Data { try ChannelKeys.publicKey(secret: Data(repeating: seed, count: 32)) }
    private func invoice(amount: UInt64? = 5_000_001, features: Set<Int> = [9, 14], routes: [[Bolt11Invoice.Route]] = [], explicitKey: Bool = false) throws -> String {
        let hrp = "lnbc" + (amount.map { "\($0 * 10)p" } ?? "")
        var words = Bolt11Invoice.integer(100, count: 7)
        words += try Bolt11Invoice.field(1, bytes: Data(repeating: 8, count: 32)) + Bolt11Invoice.field(16, bytes: Data(repeating: 9, count: 32))
        words += try Bolt11Invoice.field(13, bytes: Data("Payment test".utf8))
        var bits: UInt64 = 0; for bit in features { bits |= 1 << bit }
        words += Bolt11Invoice.field(5, words: Bolt11Invoice.integer(bits))
        if explicitKey { words += try Bolt11Invoice.field(19, bytes: key(3)) }
        for route in routes { words += try Bolt11Invoice.field(3, bytes: route.reduce(Data(), { $0 + $1.bytes })) }
        let digest = HashDigest(Array(ChannelKeys.hash(Data(hrp.utf8) + Data(try SegwitAddress.convertBits(words, from: 5, to: 8, pad: true)))))
        let signature = try P256K.Recovery.PrivateKey(dataRepresentation: Data(repeating: 3, count: 32)).signature(for: digest).compactRepresentation
        words += try SegwitAddress.convertBits(Array(signature.signature) + [UInt8(signature.recoveryId)], from: 8, to: 5, pad: true)
        return try Bech32.encode(hrp: hrp, data: words, encoding: .bech32, maxLength: 8192)
    }
    func testAmountlessFeaturesNetworkAndExpiryValidation() throws {
        let value = try Bolt11Invoice.decode("  LIGHTNING:" + invoice(amount: nil, explicitKey: true) + "\n", network: .mainnet)
        XCTAssertNil(value.amountMsat); XCTAssertEqual(value.payee, try key(3)); XCTAssertEqual(value.description, "Payment test")
        XCTAssertEqual(value.minimumFinalDelta, 18); XCTAssertEqual(value.features.bits, [9, 14])
        try value.validatePayment(amountMsat: 1001, now: 3699)
        XCTAssertThrowsError(try value.validatePayment(amountMsat: 1001, now: 3700))
        XCTAssertThrowsError(try Bolt11Invoice.decode(invoice(), network: .regtest))
        let fixed = try Bolt11Invoice.decode(invoice(), network: .mainnet)
        XCTAssertThrowsError(try fixed.validatePayment(amountMsat: 5_000_002, now: 101))
        for unsupported in [Set([9, 14, 30]), Set([14]), Set([9, 14, 48]), Set([8, 9, 14])] {
            let value = try Bolt11Invoice.decode(invoice(features: unsupported), network: .mainnet)
            XCTAssertThrowsError(try value.validatePayment(amountMsat: 5_000_001, now: 101))
        }
        let optional = try Bolt11Invoice.decode(invoice(features: [9, 14, 31]), network: .mainnet)
        try optional.validatePayment(amountMsat: 5_000_001, now: 101)
    }
    func testPreciseSatsConversionHasNoRoundingOrOverflow() throws {
        for text in ["0.001", "1.01", "5000", "16777215"] {
            XCTAssertEqual(Bolt11Invoice.sats(try Bolt11Invoice.millisatoshis(text)), text)
        }
        for text in ["0", "-1", "1e3", "0.0001", "1.", ".1", "16777215.001", "18446744073709551616", "1,000"] {
            XCTAssertThrowsError(try Bolt11Invoice.millisatoshis(text), text)
        }
    }
    func testHintFeesCLTVAndEveryOnionHop() throws {
        let first = try Bolt11Invoice.Route(peer: key(1), shortChannelID: 123, baseMsat: 1000, proportionalMillionths: 100, expiryDelta: 40)
        let second = try Bolt11Invoice.Route(peer: key(2), shortChannelID: 456, baseMsat: 2000, proportionalMillionths: 200, expiryDelta: 50)
        let value = try Bolt11Invoice.decode(invoice(routes: [[first, second]]), network: .mainnet)
        XCTAssertEqual(value.routes, [[first, second]])
        let route = try LightningRoutingGraph(chain: Data(repeating: 7, count: 32)).route(from: key(1), invoice: value, amountMsat: 5_000_001, feeLimitMsat: 10_000, maximumDelta: 144)
        XCTAssertEqual(route.hops, [first, second])
        let quote = try route.quote(invoice: value, amountMsat: 5_000_001, feeLimitMsat: 10_000, height: 800_000, maximumDelta: 144)
        XCTAssertEqual(quote.amountMsat, 5_004_503); XCTAssertEqual(quote.feeMsat, 4502); XCTAssertEqual(quote.firstExpiry, 800_108)
        XCTAssertThrowsError(try route.quote(invoice: value, amountMsat: 5_000_001, feeLimitMsat: 4501, height: 1, maximumDelta: 144))
        XCTAssertThrowsError(try route.quote(invoice: value, amountMsat: 5_000_001, feeLimitMsat: 10_000, height: 1, maximumDelta: 107))
        var packet = try route.onion(invoice: value, quote: quote)
        for index in 0..<3 {
            let peeled = try OnionPacket.peel(packet, secret: Data(repeating: UInt8(index + 1), count: 32), associatedData: value.paymentHash)
            XCTAssertEqual(peeled.payload, quote.payloads[index])
            if index < 2 { packet = try XCTUnwrap(peeled.next) } else { XCTAssertNil(peeled.next) }
        }
    }
    func testGossipRangeCoverageAndBoundedBatching() throws {
        let chain = Data(repeating: 7, count: 32)
        func reply(first: UInt32, count: UInt32, complete: UInt8, ids: [UInt64]) throws -> LightningWire.Message {
            var w = LightningWire.Writer(), encoded = LightningWire.Writer(); encoded.u8(0)
            for id in ids { encoded.u64(id) }
            w.append(chain); w.u32(first); w.u32(count); w.u8(complete); w.u16(UInt16(encoded.data.count)); w.append(encoded.data)
            return try .init(type: 264, payload: w.data)
        }
        var query = try LightningGossipQuery(chain: chain, height: 100, now: 100)
        XCTAssertFalse(try query.receiveRange(reply(first: 0, count: 50, complete: 0, ids: [UInt64(1) << 40]), now: 101))
        XCTAssertThrowsError(try query.receiveRange(reply(first: 70, count: 31, complete: 1, ids: []), now: 102))
        XCTAssertTrue(try query.receiveRange(reply(first: 50, count: 51, complete: 1, ids: []), now: 103))
        XCTAssertEqual(try query.next()?.type, 261); XCTAssertNil(try query.next())
        XCTAssertThrowsError(try query.receiveRange(reply(first: 0, count: 101, complete: 1, ids: []), now: 104))
        var empty = try LightningGossipQuery(chain: chain, height: 0, now: 100)
        XCTAssertTrue(try empty.receiveRange(reply(first: 0, count: 1, complete: 1, ids: []), now: 101)); XCTAssertNil(try empty.next())
    }
}
