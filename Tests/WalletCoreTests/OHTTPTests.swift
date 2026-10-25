import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// Oblivious HTTP against RFC 9458's worked example (Appendix A, reproduced
/// byte for byte on both halves), BHTTP framing round trips, and the sizes
/// BIP 77 fixes.
@Suite("OHTTP (RFC 9458) and BHTTP (RFC 9292)")
struct OHTTPTests {
    private typealias Curve = HPKE.X25519
    private typealias Cipher = HPKE.AESGCM128AEAD

    // RFC 9458 Appendix A.
    private let gatewaySecret = Data(hex: "3c168975674b2fa8e465970b79c8dcf09f1c741626480bd4c6162fc5b6a98e1a")!
    private let keyConfigBytes = Data(hex: "01002031e1f05a740102115220e9af918f738674aec95f54db6e04eb705aae8e79815500080001000100010003")!
    private let requestBytes = Data(hex: "00034745540568747470730b6578616d706c652e636f6d012f")!
    private let clientSecret = Data(hex: "bc51d5e930bda26589890ac7032f70ad12e4ecb37abb1b65b1256c9c48999c73")!
    private let encapsulatedRequest = Data(hex: "010020000100014b28f881333e7c164ffc499ad9796f877f4e1051ee6d31bad19dec96c208b4726374e469135906992e1268c594d2a10c695d858c40a026e7965e7d86b83dd440b2c0185204b4d63525")!
    private let responseBytes = Data(hex: "0140c8")!
    private let responseNonce = Data(hex: "c789e7151fcba46158ca84b04464910d")!
    private let encapsulatedResponse = Data(hex: "c789e7151fcba46158ca84b04464910d86f9013e404feea014e7be4a441f234f857fbd")!

    @Test("the key configuration decodes and re-encodes")
    func keyConfig() throws {
        let config = try OHTTP.KeyConfig(encoded: keyConfigBytes)
        #expect(config.keyID == 1)
        #expect(config.kemID == 0x0020)
        #expect(config.publicKey.hex == "31e1f05a740102115220e9af918f738674aec95f54db6e04eb705aae8e798155")
        #expect(config.symmetricAlgorithms == [.init(kdfID: 1, aeadID: 1), .init(kdfID: 1, aeadID: 3)])
        #expect(config.encoded == keyConfigBytes)
        #expect(throws: OHTTP.Failure.unsupportedAlgorithm) { try OHTTP.KeyConfig(encoded: Data([1, 0x7F, 0xFF])) }
        #expect(throws: OHTTP.Failure.self) { try OHTTP.KeyConfig(encoded: keyConfigBytes.dropLast()) }
    }

    @Test("the client's encapsulated request matches Appendix A byte for byte")
    func clientRequest() throws {
        let config = try OHTTP.KeyConfig(encoded: keyConfigBytes)
        let request = OHTTP.Request(method: "GET", scheme: "https", authority: "example.com", path: "/")
        // The RFC's example is the truncated form (no header, content or
        // trailer sections); our encoder always writes them.
        #expect(try OHTTP.Request(decoding: requestBytes) == request)
        #expect(request.encoded == requestBytes + Data([0, 0, 0]))
        let ephemeral = try Curve.privateKey(clientSecret)
        let (encapsulated, context) = try OHTTP.encapsulateRequest(requestBytes, config: config, Curve.self,
                                                                   Cipher.self, ephemeral: ephemeral)
        #expect(encapsulated == encapsulatedRequest)
        #expect(try context.decapsulate(encapsulatedResponse) == responseBytes)
        #expect(try OHTTP.Response(decoding: responseBytes) == OHTTP.Response(status: 200))
    }

    @Test("the gateway's decapsulation and encapsulated response match Appendix A")
    func gatewayResponse() throws {
        let config = try OHTTP.KeyConfig(encoded: keyConfigBytes)
        let secret = try Curve.privateKey(gatewaySecret)
        #expect(Curve.serialize(secret.publicKey) == config.publicKey)
        let (request, context) = try OHTTP.decapsulateRequest(encapsulatedRequest, config: config, privateKey: secret,
                                                              Curve.self, Cipher.self)
        #expect(request == requestBytes)
        #expect(try context.encapsulate(responseBytes, nonce: responseNonce) == encapsulatedResponse)
    }

    @Test("a wrong key id, a tampered request and a tampered response are refused")
    func refusals() throws {
        let config = try OHTTP.KeyConfig(encoded: keyConfigBytes)
        let secret = try Curve.privateKey(gatewaySecret)
        var wrongKeyID = encapsulatedRequest
        wrongKeyID[wrongKeyID.startIndex] = 2
        #expect(throws: OHTTP.Failure.unsupportedAlgorithm) {
            try OHTTP.decapsulateRequest(wrongKeyID, config: config, privateKey: secret, Curve.self, Cipher.self)
        }
        var tampered = encapsulatedRequest
        tampered[tampered.endIndex - 1] ^= 1
        #expect(throws: HPKE.Failure.openFailed) {
            try OHTTP.decapsulateRequest(tampered, config: config, privateKey: secret, Curve.self, Cipher.self)
        }
        let (_, context) = try OHTTP.encapsulateRequest(requestBytes, config: config, Curve.self, Cipher.self,
                                                        ephemeral: try Curve.privateKey(clientSecret))
        var badResponse = encapsulatedResponse
        badResponse[badResponse.endIndex - 1] ^= 1
        #expect(throws: HPKE.Failure.openFailed) { try context.decapsulate(badResponse) }
        // A config without ChaCha cannot be used with ChaCha.
        #expect(throws: OHTTP.Failure.unsupportedAlgorithm) {
            try OHTTP.encapsulateRequest(requestBytes, config: .init(keyID: 1, kemID: 0x20, publicKey: config.publicKey,
                                                                     symmetricAlgorithms: [.init(kdfID: 1, aeadID: 1)]),
                                         Curve.self, HPKE.ChaChaPolyAEAD.self)
        }
    }

    @Test("BHTTP requests and responses round trip with headers, bodies, informational responses and padding")
    func bhttpRoundTrips() throws {
        let request = OHTTP.Request(method: "POST", scheme: "https", authority: "payjo.in:443", path: "/ABCDEFGHIJKLM",
                                    headers: [("content-type", "application/octet-stream")],
                                    body: Data(repeating: 0xAB, count: 7_168))
        let padded = request.encoded + ElligatorSwift.random(count: 500)
        #expect(try OHTTP.Request(decoding: padded) == request)
        let response = OHTTP.Response(status: 202, headers: [("x", "y"), ("cache-control", "no-store")],
                                      body: Data("hello".utf8))
        #expect(try OHTTP.Response(decoding: response.encoded + Data(count: 40)) == response)
        // An informational response precedes the final one.
        var informational = Data([1])
        OHTTP.appendVarint(100, to: &informational)
        OHTTP.appendFieldSection([("link", "x")], to: &informational)
        informational += response.encoded.dropFirst()
        #expect(try OHTTP.Response(decoding: informational) == response)
        #expect(throws: OHTTP.Failure.self) { try OHTTP.Response(decoding: Data([2, 0x40, 0xC8])) }
        #expect(throws: OHTTP.Failure.self) { try OHTTP.Request(decoding: Data([0, 3, 0x47])) }
    }

    @Test("QUIC varints encode on 1, 2, 4 and 8 bytes")
    func varints() throws {
        for (value, hex) in [(UInt64(0), "00"), (63, "3f"), (64, "4040"), (200, "40c8"), (16_383, "7fff"),
                             (16_384, "80004000"), (1_073_741_823, "bfffffff"), (1_073_741_824, "c000000040000000")] {
            var data = Data()
            OHTTP.appendVarint(value, to: &data)
            #expect(data.hex == hex, "\(value)")
            var reader = ByteReader(data)
            #expect(try OHTTP.readVarint(&reader) == value)
        }
    }

    @Test("BIP 77 sizes: a 7,168-byte payload in an 8,104-byte padded request yields 8,192 bytes with secp256k1")
    func bip77Sizes() throws {
        typealias PJCurve = HPKE.Secp256k1
        typealias PJCipher = HPKE.ChaChaPolyAEAD
        let gateway = try PJCurve.generatePrivateKey()
        let config = OHTTP.KeyConfig(keyID: 7, kemID: PJCurve.id, publicKey: PJCurve.serialize(gateway.publicKey),
                                     symmetricAlgorithms: [.init(kdfID: 1, aeadID: 3)])
        let request = OHTTP.Request(method: "POST", scheme: "https", authority: "payjo.in", path: "/TXJCGKTKXLUUZ",
                                    body: Data(repeating: 1, count: 7_168))
        let padded = request.encoded + ElligatorSwift.random(count: 8_104 - request.encoded.count)
        let (encapsulated, client) = try OHTTP.encapsulateRequest(padded, config: config, PJCurve.self, PJCipher.self)
        #expect(encapsulated.count == 8_192)
        let (decapsulated, context) = try OHTTP.decapsulateRequest(encapsulated, config: config, privateKey: gateway,
                                                                   PJCurve.self, PJCipher.self)
        #expect(try OHTTP.Request(decoding: decapsulated) == request)
        let response = OHTTP.Response(status: 200, body: Data(repeating: 2, count: 7_168)).encoded
        let encapsulatedResponse = try context.encapsulate(response + Data(count: 8_144 - response.count))
        #expect(encapsulatedResponse.count == 8_192)
        #expect(try OHTTP.Response(decoding: client.decapsulate(encapsulatedResponse)).body.count == 7_168)
    }
}
