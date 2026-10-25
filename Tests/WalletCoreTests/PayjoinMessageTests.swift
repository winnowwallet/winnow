import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// BIP 77 Message A and Message B: fixed sizes, the reply key inside A,
/// receiver authentication on B, and refusals.
@Suite("Payjoin messages (BIP 77)")
struct PayjoinMessageTests {
    @Test("Message A is 7,168 bytes and the receiver recovers the body and reply key")
    func messageA() throws {
        let receiver = try HPKE.Secp256k1.generatePrivateKey()
        let reply = try HPKE.Secp256k1.generatePrivateKey()
        let body = Data("cHNidP8BAH...\nmaxadditionalfeecontribution=182".utf8)
        let message = try PayjoinMessage.encryptA(body: body, replyKey: reply.publicKey, receiverKey: receiver.publicKey)
        #expect(message.count == 7_168)
        let (padded, replyKey) = try PayjoinMessage.decryptA(message, receiverKey: receiver)
        #expect(padded.count == PayjoinMessage.plaintextABytes)
        #expect(PayjoinMessage.unpadded(padded) == body)
        #expect(HPKE.Secp256k1.compressed(replyKey) == HPKE.Secp256k1.compressed(reply.publicKey))
        // Two encryptions of one body differ (fresh ephemeral key, random ellswift).
        #expect(try PayjoinMessage.encryptA(body: body, replyKey: reply.publicKey, receiverKey: receiver.publicKey) != message)
        // The empty poll body is fine; an oversized one is not.
        #expect(try PayjoinMessage.encryptA(body: Data(), replyKey: reply.publicKey, receiverKey: receiver.publicKey).count == 7_168)
        #expect(throws: PayjoinMessage.Failure.payloadTooLarge(actual: 7_056, max: 7_055)) {
            try PayjoinMessage.encryptA(body: Data(count: 7_056), replyKey: reply.publicKey, receiverKey: receiver.publicKey)
        }
        // Another receiver cannot open it; a truncated or flipped message fails.
        let other = try HPKE.Secp256k1.generatePrivateKey()
        #expect(throws: HPKE.Failure.openFailed) { try PayjoinMessage.decryptA(message, receiverKey: other) }
        #expect(throws: PayjoinMessage.Failure.wrongLength) { try PayjoinMessage.decryptA(message.dropLast(), receiverKey: receiver) }
        var flipped = message
        flipped[flipped.startIndex + 100] ^= 1
        #expect(throws: HPKE.Failure.openFailed) { try PayjoinMessage.decryptA(flipped, receiverKey: receiver) }
    }

    @Test("Message B is 7,168 bytes, opens only for the reply key, and only when sealed by the receiver key")
    func messageB() throws {
        let receiver = try HPKE.Secp256k1.generatePrivateKey()
        let reply = try HPKE.Secp256k1.generatePrivateKey()
        let body = Data("cHNidP8BAJwCAAAAAo8nutGgJdyYG".utf8)
        let message = try PayjoinMessage.encryptB(body: body, receiverKey: receiver, replyKey: reply.publicKey)
        #expect(message.count == 7_168)
        let opened = try PayjoinMessage.decryptB(message, receiverKey: receiver.publicKey, replyKey: reply)
        #expect(opened.count == PayjoinMessage.plaintextBBytes)
        #expect(PayjoinMessage.unpadded(opened) == body)
        let impostor = try HPKE.Secp256k1.generatePrivateKey()
        let forged = try PayjoinMessage.encryptB(body: body, receiverKey: impostor, replyKey: reply.publicKey)
        #expect(throws: HPKE.Failure.openFailed) {
            try PayjoinMessage.decryptB(forged, receiverKey: receiver.publicKey, replyKey: reply)
        }
        #expect(throws: HPKE.Failure.openFailed) {
            try PayjoinMessage.decryptB(message, receiverKey: receiver.publicKey, replyKey: impostor)
        }
        #expect(throws: PayjoinMessage.Failure.payloadTooLarge(actual: 7_089, max: 7_088)) {
            try PayjoinMessage.encryptB(body: Data(count: 7_089), receiverKey: receiver, replyKey: reply.publicKey)
        }
    }

    @Test("unpadded strips trailing zeros only")
    func unpadding() {
        #expect(PayjoinMessage.unpadded(Data([1, 0, 2, 0, 0])) == Data([1, 0, 2]))
        #expect(PayjoinMessage.unpadded(Data(count: 5)).isEmpty)
        #expect(PayjoinMessage.unpadded(Data()).isEmpty)
    }
}
