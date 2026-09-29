import Foundation
import XCTest
@testable import LightningCore

final class OnionTests: XCTestCase {
    func testIndependentCoreLightningPacket() throws {
        struct Vector: Decodable {
            let private_key: String, associated_data: String, onion: String
            let payloads: [String], shared_secrets: [String]
        }
        let vector: Vector = try loadVectors("cln-onion")
        var packet = try hex(vector.onion)
        let key = try ChannelKeys.publicKey(secret: hex(vector.private_key))
        let hops = try vector.payloads.map { try OnionPacket.Hop(publicKey: key, payload: hex($0)) }
        XCTAssertEqual(try OnionPacket.create(hops: hops, associatedData: hex(vector.associated_data), size: 1300,
            session: Data(repeating: 0x41, count: 32), padding: Data(repeating: 0x41, count: 32)), packet)
        for index in vector.payloads.indices {
            let peeled = try OnionPacket.peel(packet, secret: hex(vector.private_key), associatedData: hex(vector.associated_data))
            XCTAssertEqual(peeled.payload, try hex(vector.payloads[index]))
            XCTAssertEqual(peeled.sharedSecret, try hex(vector.shared_secrets[index]))
            if index == vector.payloads.count - 1 { XCTAssertNil(peeled.next) }
            else { packet = try XCTUnwrap(peeled.next) }
        }
    }
    func testChaCha20PublishedZeroKeyStream() throws {
        // RFC 8439 appendix A.1, test vector #1 (all-zero key/nonce/counter).
        let expected = try hex("76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7" +
                               "da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586")
        XCTAssertEqual(try OnionStream.bytes(key: Data(repeating: 0, count: 32), count: 64), expected)
    }
    func testVariableHopPayloadsAuthenticationAndForwarding() throws {
        let secrets = (1...5).map { Data(repeating: UInt8($0), count: 32) }
        let payloads = [Data([1, 0]), Data([3, 2, 42, 43]), Data(repeating: 45, count: 260), Data([7, 0]), Data([9, 0])]
        let hops = try zip(secrets, payloads).map { try OnionPacket.Hop(publicKey: ChannelKeys.publicKey(secret: $0), payload: $1) }
        let hash = Data(repeating: 99, count: 32)
        var packet = try OnionPacket.create(hops: hops, associatedData: hash)
        XCTAssertThrowsError(try OnionPacket.peel(packet, secret: secrets[0], associatedData: Data(repeating: 98, count: 32)))
        var altered = packet; altered[altered.endIndex - 1] ^= 1
        XCTAssertThrowsError(try OnionPacket.peel(altered, secret: secrets[0], associatedData: hash))
        for index in secrets.indices {
            let peeled = try OnionPacket.peel(packet, secret: secrets[index], associatedData: hash)
            XCTAssertEqual(peeled.payload, payloads[index])
            if index == secrets.count - 1 { XCTAssertNil(peeled.next) }
            else { packet = try XCTUnwrap(peeled.next) }
        }
    }
    func testPaymentSecretAmountAndExpiryAreBoundTogether() throws {
        let secret = Data(repeating: 3, count: 32)
        let payload = try PaymentPayload(amountMsat: 12_000, expiry: 200, secret: secret)
        XCTAssertEqual(try PaymentPayload(bytes: payload.bytes), payload)
        try payload.validate(expectedSecret: secret, expectedAmount: 12_000, receivedAmount: 12_000,
                             receivedExpiry: 200, height: 100, minimumDelta: 80)
        try payload.validate(expectedSecret: secret, expectedAmount: 12_000, receivedAmount: 12_000,
                             receivedExpiry: 218, height: 138, minimumDelta: 80)
        XCTAssertThrowsError(try payload.validate(expectedSecret: secret, expectedAmount: 12_000,
            receivedAmount: 12_000, receivedExpiry: 199, height: 100, minimumDelta: 80))
        XCTAssertThrowsError(try payload.validate(expectedSecret: Data(repeating: 4, count: 32), expectedAmount: 12_000,
            receivedAmount: 12_000, receivedExpiry: 200, height: 100, minimumDelta: 80))
        XCTAssertThrowsError(try payload.validate(expectedSecret: secret, expectedAmount: 12_000,
            receivedAmount: 11_999, receivedExpiry: 200, height: 100, minimumDelta: 80))
        XCTAssertThrowsError(try payload.validate(expectedSecret: secret, expectedAmount: 12_000,
            receivedAmount: 12_000, receivedExpiry: 200, height: 121, minimumDelta: 80))
        XCTAssertThrowsError(try PaymentPayload(bytes: Data([2, 1, 0]) + payload.bytes.dropFirst(4)))
    }
}
