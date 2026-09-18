import CryptoKit
import Foundation
import Testing
@testable import WalletCore

/// The publisher's signature over `peers.json`: what it covers, which keys it
/// is accepted under, and the requirement enforced in production.
struct CensusSignatureTests {
    @Test func signsAndVerifiesTheExactBytesUnderATrustedKey() throws {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data(#"{"date":"2026-09-14"}"#.utf8)
        let signature = try CensusSignature.sign(payload, with: key)
        let encoded = try signature.encoded()
        #expect(encoded.count <= CensusSignature.maximumBytes)
        let decoded = try CensusSignature.decode(encoded)
        #expect(decoded == signature)
        try decoded.verify(payload, trusting: [key.publicKey])
        #expect(throws: CensusSignature.Invalid.signature) {
            try decoded.verify(payload + Data([0x0a]), trusting: [key.publicKey])
        }
        #expect(throws: CensusSignature.Invalid.unknownKey) {
            try decoded.verify(payload, trusting: [Curve25519.Signing.PrivateKey().publicKey])
        }
        #expect(throws: CensusSignature.Invalid.unknownKey) { try decoded.verify(payload, trusting: []) }
        // A rotation: the new key signs, and the old one is accepted for as
        // long as it is still listed.
        let rotated = Curve25519.Signing.PrivateKey()
        try CensusSignature.sign(payload, with: rotated).verify(payload, trusting: [key.publicKey, rotated.publicKey])
    }

    /// The census tool signs with its own copy of this format. CryptoKit's
    /// Ed25519 signatures are randomised, so the shared vector is a signature
    /// file rather than an expected signing output: the census's contract
    /// tests (`tests/test_contract.py`, `KAT_SIGNATURE`) verify this same
    /// file, so the tag and the bytes covered cannot drift apart unnoticed.
    @Test func knownAnswerSharedWithTheCensusTool() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x01, count: 32))
        let payload = Data(#"{"date":"2026-09-14"}"#.utf8)
        let publicKey = "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
        #expect(key.publicKey.rawRepresentation.hex == publicKey)
        let fixture = CensusSignature(
            algorithm: "ed25519", publicKey: publicKey,
            signature: "bdaac83b679535934fb1337a5bf40bc6e666cb040c0f8d83dbdbf7b88b7c187b"
                + "b8a344182895dab82b646cd88e4236e4096f0a6fca6fefe661ba972fbbd78209")
        try fixture.verify(payload, trusting: [key.publicKey])
        #expect(throws: CensusSignature.Invalid.signature) {
            try fixture.verify(Data(#"{"date":"2026-09-15"}"#.utf8), trusting: [key.publicKey])
        }
        try CensusSignature.sign(payload, with: key).verify(payload, trusting: [key.publicKey])
    }

    @Test func refusesMalformedSignatureFiles() {
        for text in ["{}", "[]", "not json",
                     #"{"algorithm":"rsa","publicKey":"00","signature":"00"}"#,
                     #"{"algorithm":"ed25519","publicKey":"zz","signature":"00"}"#] {
            #expect(throws: CensusSignature.Invalid.malformed) { try CensusSignature.decode(Data(text.utf8)) }
        }
        #expect(throws: CensusSignature.Invalid.malformed) {
            try CensusSignature.decode(Data(repeating: 0x20, count: CensusSignature.maximumBytes + 1))
        }
    }

    @Test func thePublisherRequiresASignatureAndATrustedKey() throws {
        let payload = Data("x".utf8)
        #expect(throws: CensusSignature.Invalid.unknownKey) {
            try CensusPublisher.verify(payload, signature: nil, trusting: [])
        }
        let key = Curve25519.Signing.PrivateKey()
        #expect(throws: CensusSignature.Invalid.missing) {
            try CensusPublisher.verify(payload, signature: nil, trusting: [key.publicKey])
        }
        try CensusPublisher.verify(payload, signature: try CensusSignature.sign(payload, with: key).encoded(),
                                   trusting: [key.publicKey])
        #expect(!CensusPublisher.trustedKeys.isEmpty, "production must trust a publisher")
        #expect(throws: CensusSignature.Invalid.missing) {
            try CensusPublisher.verify(payload, signature: nil, trusting: CensusPublisher.trustedKeys)
        }
        #expect(throws: CensusSignature.Invalid.unknownKey) {
            try CensusPublisher.verify(payload, signature: try CensusSignature.sign(payload, with: key).encoded(),
                                       trusting: CensusPublisher.trustedKeys)
        }
        #expect(CensusPublisher.trustedKeys.count == CensusPublisher.trustedKeysHex.count,
                "every compiled-in key parses")
        #expect(CensusSignature.endpoint(for: CensusCatalog.endpoint).absoluteString
            == CensusCatalog.endpoint.absoluteString + ".sig")
    }
}
