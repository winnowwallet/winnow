import Foundation
import XCTest
import WalletCore
@testable import LightningCore

final class Bolt12Tests: XCTestCase {
    private func vectors(_ name: String) throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Vectors/BOLT12"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    }
    func testPublishedOfferAndFormattingVectors() throws {
        for vector in try vectors("offers-test") {
            let encoded = try XCTUnwrap(vector["bolt12"] as? String)
            let message = vector["description"] as? String ?? ""
            if vector["valid"] as? Bool == true {
                let parsed = try LightningOffer(string: encoded)
                XCTAssertEqual(try LightningOffer(string: parsed.string), parsed, message)
            } else {
                XCTAssertThrowsError(try LightningOffer(string: encoded), message)
            }
        }
        for vector in try vectors("format-string-test") {
            let encoded = try XCTUnwrap(vector["string"] as? String), message = vector["comment"] as? String ?? ""
            if vector["valid"] as? Bool == true { XCTAssertNoThrow(try LightningOffer(string: encoded), message) }
            else { XCTAssertThrowsError(try LightningOffer(string: encoded), message) }
        }
    }
    func testPublishedMerkleRootsAndInvoiceRequestSignature() throws {
        for vector in try vectors("signature-test") {
            let leaves = try XCTUnwrap(vector["leaves"] as? [[String: String]])
            let records = try leaves.map { leaf -> Data in
                let key = try XCTUnwrap(leaf.keys.first(where: { $0.hasPrefix("H(`LnLeaf`,") }))
                let hex = key.dropFirst("H(`LnLeaf`,".count).dropLast()
                return try XCTUnwrap(Data(hex: String(hex)))
            }.reduce(Data(), +)
            XCTAssertEqual(try Bolt12Encoding.merkleRoot(records).hex, vector["merkle"] as? String)
            if let encoded = vector["bolt12"] as? String {
                let bytes = try Bolt12Encoding.decode(encoded, prefix: "lnr")
                let fields = try Bolt12Encoding.records(bytes)
                let key = try XCTUnwrap(fields.first(where: { $0.type == 88 })?.value)
                try Bolt12Encoding.verify(bytes, message: "invoice_request", publicKey: key)
                let changed = fields.map { $0.type == 10 ? LightningWire.TLV(type: 10, value: Data("changed".utf8)) : $0 }
                XCTAssertThrowsError(try Bolt12Encoding.verify(Bolt12Encoding.serialize(changed), message: "invoice_request", publicKey: key))
                XCTAssertThrowsError(try Bolt12Encoding.verify(bytes, message: "invoice", publicKey: key))
            }
        }
    }
    func testPaymentReviewRejectsWrongChainExpiryAndUnacceptedCurrency() throws {
        let offers = try vectors("offers-test").filter { $0["valid"] as? Bool == true }
        let currency = try XCTUnwrap(offers.first { $0["description"] as? String == "with currency" }?["bolt12"] as? String)
        let offer = try LightningOffer(string: currency)
        XCTAssertThrowsError(try offer.validatePayment(chain: offer.chains[0], now: 0, amountMsat: 100_000))
        let minimal = try LightningOffer(string: XCTUnwrap(offers.first?["bolt12"] as? String))
        XCTAssertThrowsError(try minimal.validatePayment(chain: Data(repeating: 42, count: 32), now: 0, amountMsat: 100))
        XCTAssertNoThrow(try minimal.validatePayment(chain: minimal.chains[0], now: 0, amountMsat: 100))
    }
    func testUpstreamStaticInvoiceRejectsSubstitutionExpiryAndSignatureDamage() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ldk-static-invoice", withExtension: "json", subdirectory: "Vectors/BOLT12"))
        let vector = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let offer = try LightningOffer(string: XCTUnwrap(vector["offer"]))
        let bytes = try XCTUnwrap(Data(hex: XCTUnwrap(vector["static_invoice"])))
        let invoice = try StaticInvoice(bytes: bytes)
        XCTAssertEqual(invoice.offer, offer)
        XCTAssertEqual(invoice.paymentPaths.count, 1); XCTAssertEqual(invoice.notificationPaths.count, 1)
        XCTAssertEqual(invoice.signingKey.hex, vector["signing_key"])
        try invoice.validatePayment(for: offer, chain: offer.chains[0], now: invoice.createdAt + 1, amountMsat: 5000)
        XCTAssertThrowsError(try invoice.validatePayment(for: offer, chain: offer.chains[0], now: invoice.createdAt + 3601, amountMsat: 5000))
        let changed = try Bolt12Encoding.records(bytes).map { $0.type == 166 ? LightningWire.TLV(type: 166, value: Data([1])) : $0 }
        XCTAssertThrowsError(try StaticInvoice(bytes: Bolt12Encoding.serialize(changed)))
        let request = try InvoiceRequest(offer: offer, chain: offer.chains[0], amountMsat: 5000, now: invoice.createdAt,
            metadata: Data(repeating: 4, count: 32), payerSecret: Data(repeating: 5, count: 32))
        XCTAssertEqual(try InvoiceRequest(bytes: request.bytes).amountMsat, 5000)
        XCTAssertEqual(try InvoiceRequest(bytes: request.bytes).offer.bytes, offer.bytes)
    }
    func testUpstreamAsyncMessagesMatchExactlyAndRejectMalformedFraming() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ldk-static-invoice", withExtension: "json", subdirectory: "Vectors/BOLT12"))
        let vector = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        let types: [(String, UInt64)] = [("offer_paths_request", 75540), ("offer_paths", 75542), ("serve_static_invoice", 75544),
                                        ("persisted", 75546), ("held", 72), ("release", 74)]
        for (key, type) in types {
            let bytes = try XCTUnwrap(Data(hex: XCTUnwrap(vector[key])))
            let record = LightningWire.TLV(type: type, value: bytes)
            XCTAssertEqual(try AsyncPaymentMessage(record: record).record(), record)
            XCTAssertThrowsError(try AsyncPaymentMessage(record: .init(type: type, value: bytes + Data([0]))))
        }
        XCTAssertThrowsError(try AsyncPaymentMessage(record: .init(type: 74, value: Data([2, 0, 0]))))
        XCTAssertThrowsError(try SegwitAddress.convertBits([1], from: 0, to: 5, pad: true))
        XCTAssertThrowsError(try SegwitAddress.convertBits([1], from: 8, to: 64, pad: true))
    }
}
