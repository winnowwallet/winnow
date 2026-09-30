import Foundation
import XCTest
@testable import LightningCore

final class AsyncPaymentTests: XCTestCase {
    private let auth = Data(repeating: 99, count: 32), id = Data(repeating: 77, count: 32)
    private func key(_ byte: UInt8) throws -> Data { try ChannelKeys.publicKey(secret: Data(repeating: byte, count: 32)) }
    private func fixture() throws -> (StaticInvoice, InvoiceRequest, AsyncPaymentRoute) {
        let server = try OnionMessage.path(nodes: [key(9)], context: Data([1]), authenticationKey: auth)
        let chain = Data(repeating: 7, count: 32)
        let offer = try LightningOffer(bytes: Bolt12Encoding.serialize([.init(type: 2, value: chain),
            .init(type: 16, value: server.encoded()), .init(type: 22, value: key(11))]))
        let path = try BlindedPayment.path(provider: key(9), recipient: key(2), shortChannelID: 456, offerID: id,
            maximumExpiry: 300, minimumMsat: 10, baseMsat: 1000, proportionalMillionths: 0, delta: 18, authenticationKey: auth)
        let invoice = try StaticInvoice(offer: offer, paymentPaths: [path],
            payInfo: [.init(baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 36,
                           minimumMsat: 10, maximumMsat: 100_000_000, features: .init(bytes: Data()))],
            notificationPaths: [server], createdAt: 100, relativeExpiry: 3600, signingSecret: Data(repeating: 11, count: 32))
        let request = try InvoiceRequest(offer: offer, chain: chain, amountMsat: 5_000_000, now: 100, metadata: Data([1]), payerSecret: Data(repeating: 12, count: 32))
        let route = try AsyncPaymentRoute(holdingPeer: key(8), introduction: key(9), shortChannelID: 123,
                                         baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 18)
        return (invoice, request, route)
    }
    func testBlindedRouteBindsRequestPreimageAndReceiverConstraints() throws {
        let (invoice, request, route) = try fixture(), preimage = Data(repeating: 88, count: 32)
        let quote = try route.quote(invoice: invoice, amountMsat: request.amountMsat, feeLimitMsat: 2000, height: 100, maximumDelta: 54)
        XCTAssertEqual(quote.feeMsat, 2000); XCTAssertEqual(quote.amountMsat, 5_002_000)
        XCTAssertEqual(quote.firstExpiry, 154); XCTAssertEqual(quote.finalExpiry, 118)
        let packet = try route.onion(invoice: invoice, request: request, preimage: preimage, quote: quote)
        let hash = ChannelKeys.hash(preimage)
        let first = try OnionPacket.peel(packet, secret: Data(repeating: 8, count: 32), associatedData: hash)
        let intro = try OnionPacket.peel(XCTUnwrap(first.next), secret: Data(repeating: 9, count: 32), associatedData: hash)
        let fields = try Bolt12Encoding.records(intro.payload), point = try XCTUnwrap(fields.first(where: { $0.type == 12 })?.value)
        let shared = try NoiseCrypto.ecdh(secret: Data(repeating: 9, count: 32), point: point)
        let nextBlinding = try ChannelKeys.point(point).multiply(Array(ChannelKeys.hash(point + shared))).dataRepresentation
        let final = try BlindedPayment.peel(onion: XCTUnwrap(intro.next), blinding: nextBlinding, nodeSecret: Data(repeating: 2, count: 32), hash: hash)
        let htlc = ChannelTransactions.HTLC(id: 0, offered: false, amountMsat: request.amountMsat, paymentHash: hash, expiry: quote.finalExpiry)
        let received = try BlindedPayment.receive(final, blinding: nextBlinding, nodeSecret: Data(repeating: 2, count: 32),
                                                 authenticationKey: auth, htlc: htlc, height: 100)
        XCTAssertEqual(received.offerID, id); XCTAssertEqual(received.request.bytes, request.bytes); XCTAssertEqual(received.preimage, preimage)
        // BOLT4 final blinded payloads use the sender's block-height baseline.
        // Actual HTLCs may have additional privacy padding, as stock LDK does.
        let padded = ChannelTransactions.HTLC(id: 0, offered: false, amountMsat: request.amountMsat,
                                             paymentHash: hash, expiry: quote.finalExpiry + 18)
        XCTAssertNoThrow(try BlindedPayment.receive(final, blinding: nextBlinding, nodeSecret: Data(repeating: 2, count: 32),
            authenticationKey: auth, htlc: padded, height: 100))
        for expiry: UInt32 in [99, 117, 301] {
            let invalid = ChannelTransactions.HTLC(id: 0, offered: false, amountMsat: request.amountMsat, paymentHash: hash, expiry: expiry)
            XCTAssertThrowsError(try BlindedPayment.receive(final, blinding: nextBlinding, nodeSecret: Data(repeating: 2, count: 32),
                authenticationKey: auth, htlc: invalid, height: 100))
        }
        XCTAssertThrowsError(try BlindedPayment.receive(final, blinding: nextBlinding, nodeSecret: Data(repeating: 2, count: 32),
            authenticationKey: Data(repeating: 98, count: 32), htlc: htlc, height: 100))
        XCTAssertThrowsError(try BlindedPayment.receive(final, blinding: nextBlinding, nodeSecret: Data(repeating: 2, count: 32),
            authenticationKey: auth, htlc: htlc, height: 101))
    }
    func testFeeAndCLTVCeilingsCannotChangeWithAnInvoice() throws {
        let (invoice, request, route) = try fixture()
        XCTAssertThrowsError(try route.quote(invoice: invoice, amountMsat: request.amountMsat, feeLimitMsat: 1999, height: 100, maximumDelta: 54))
        XCTAssertThrowsError(try route.quote(invoice: invoice, amountMsat: request.amountMsat, feeLimitMsat: 2000, height: 100, maximumDelta: 53))
        XCTAssertThrowsError(try route.quote(invoice: invoice, amountMsat: .max, feeLimitMsat: .max, height: 100, maximumDelta: 100))
        XCTAssertThrowsError(try route.quote(invoice: invoice, amountMsat: 10, feeLimitMsat: .max, height: .max, maximumDelta: 100))
        XCTAssertEqual(try AsyncPaymentRoute.fee(1, base: 0, proportional: 1), 1)
        XCTAssertEqual(try AsyncPaymentRoute.fee(1_000_000, base: 1, proportional: 1), 2)
        XCTAssertThrowsError(try AsyncPaymentRoute.fee(.max, base: .max, proportional: .max))
        XCTAssertTrue(LightningFeatures.asyncClient.supports(24)); XCTAssertTrue(LightningFeatures.asyncClient.supports(38))
        XCTAssertFalse(LightningFeatures.asyncClient.supports(152))
    }
    func testReleasePathFramingRejectsDuplicateIDsAndTruncatedPaths() throws {
        let path = try OnionMessage.path(nodes: [key(2)], context: id, authenticationKey: auth)
        var writer = LightningWire.Writer(); writer.u64(42); writer.append(try path.encoded())
        let decoded = try HTLCReleasePath.decode(writer.data)
        XCTAssertEqual(decoded.count, 1); XCTAssertEqual(decoded.first?.id, 42); XCTAssertEqual(decoded.first?.path, path)
        XCTAssertThrowsError(try HTLCReleasePath.decode(writer.data + writer.data))
        XCTAssertThrowsError(try HTLCReleasePath.decode(Data(writer.data.dropLast())))
        XCTAssertTrue(try HTLCReleasePath.decode(Data()).isEmpty)
    }

}
