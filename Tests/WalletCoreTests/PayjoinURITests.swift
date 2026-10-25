import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// BIP 21 parsing with BIP 77's `pj` parameter, on the BIP's own example URI.
@Suite("Payjoin URI (BIP 21 + BIP 77)")
struct PayjoinURITests {
    static let example = "bitcoin:tb1q6q6de88mj8qkg0q5lupmpfexwnqjsr4d2gvx2p?amount=0.00666666&pjos=0&pj=HTTPS://PAYJO.IN/TXJCGKTKXLUUZ%23EX1WKV8CEC-OH1QYPM59NK2LXXS4890SUAXXYT25Z2VAPHP0X7YEYCJXGWAG6UG9ZU6NQ-RK1Q0DJS3VVDXWQQTLQ8022QGXSX7ML9PHZ6EDSF6AKEWQG758JPS2EV"

    @Test("the BIP 77 example URI parses into its session parameters")
    func example() throws {
        let uri = try PaymentURI(Self.example)
        #expect(uri.address == "tb1q6q6de88mj8qkg0q5lupmpfexwnqjsr4d2gvx2p")
        #expect(uri.amountSats == 666_666)
        #expect(uri.outputSubstitutionAllowed == false)
        #expect(uri.payjoinRequired == false)
        let payjoin = try #require(uri.payjoin)
        #expect(payjoin.directory.absoluteString == "https://payjo.in/")
        #expect(payjoin.mailboxID == "TXJCGKTKXLUUZ")
        #expect(payjoin.mailboxURL.absoluteString == "https://payjo.in/TXJCGKTKXLUUZ")
        #expect(payjoin.receiverKey.hex == "03db28458c699c002fe03bd4a020d037b7f286e2d65b04ebb6cb808f50f20c1596")
        #expect(payjoin.ohttpKeyConfig.keyID == 1)
        #expect(payjoin.ohttpKeyConfig.kemID == 0x0016)
        #expect(payjoin.ohttpKeyConfig.publicKey.prefix(33).hex.hasPrefix("04"))
        #expect(payjoin.ohttpKeyConfig.symmetricAlgorithms == [.init(kdfID: 1, aeadID: 3)])
        #expect(payjoin.expiry == Date(timeIntervalSince1970: 1_736_218_741))
        // The mailbox id is the receiver key's short id.
        #expect(PayjoinShortID.derive(compressedKey: payjoin.receiverKey) == "TXJCGKTKXLUUZ")
        // Re-encoding gives the same endpoint, `-`-separated, in order.
        #expect(payjoin.endpoint == "HTTPS://PAYJO.IN/TXJCGKTKXLUUZ#EX1WKV8CEC-OH1QYPM59NK2LXXS4890SUAXXYT25Z2VAPHP0X7YEYCJXGWAG6UG9ZU6NQ-RK1Q0DJS3VVDXWQQTLQ8022QGXSX7ML9PHZ6EDSF6AKEWQG758JPS2EV")
        #expect(try PaymentURI("bitcoin:\(uri.address)?pj=\(payjoin.queryValue)").payjoin == payjoin)
    }

    @Test("the earlier `+` separator and any parameter order are accepted; mixed separators are not")
    func separators() throws {
        let plus = Self.example.replacingOccurrences(of: "-OH1", with: "+OH1").replacingOccurrences(of: "-RK1", with: "+RK1")
        #expect(try PaymentURI(plus).payjoin == (try PaymentURI(Self.example).payjoin))
        let reordered = "bitcoin:tb1q6q6de88mj8qkg0q5lupmpfexwnqjsr4d2gvx2p?pj=HTTPS://PAYJO.IN/TXJCGKTKXLUUZ%23RK1Q0DJS3VVDXWQQTLQ8022QGXSX7ML9PHZ6EDSF6AKEWQG758JPS2EV-EX1WKV8CEC-OH1QYPM59NK2LXXS4890SUAXXYT25Z2VAPHP0X7YEYCJXGWAG6UG9ZU6NQ"
        #expect(try PaymentURI(reordered).payjoin == (try PaymentURI(Self.example).payjoin))
        let mixed = Self.example.replacingOccurrences(of: "-RK1", with: "+RK1")
        #expect(throws: PaymentURIError.invalidPayjoinEndpoint("fragment separators")) { try PaymentURI(mixed) }
    }

    @Test("a lowercase fragment, a missing parameter, a bad key and a bad path are refused")
    func refusals() throws {
        let lowercase = Self.example.replacingOccurrences(of: "RK1Q0DJS", with: "RK1q0djs")
        #expect(throws: PaymentURIError.self) { try PaymentURI(lowercase) }
        let noExpiry = Self.example.replacingOccurrences(of: "EX1WKV8CEC-", with: "")
        #expect(throws: PaymentURIError.invalidPayjoinEndpoint("EX")) { try PaymentURI(noExpiry) }
        let badKey = Self.example.replacingOccurrences(of: "RK1Q0DJS3VVDXWQQTLQ8022QGXSX7ML9PHZ6EDSF6AKEWQG758JPS2EV",
                                                       with: "RK1Q0DJS3VVDXWQQTLQ8022QGXSX7ML9PHZ6EDSF6AKEWQG758JPS2EV00")
        #expect(throws: PaymentURIError.self) { try PaymentURI(badKey) }
        let deepPath = Self.example.replacingOccurrences(of: "PAYJO.IN/TXJCGKTKXLUUZ", with: "PAYJO.IN/A/TXJCGKTKXLUUZ")
        #expect(throws: PaymentURIError.invalidPayjoinEndpoint("mailbox path")) { try PaymentURI(deepPath) }
        let noFragment = "bitcoin:tb1q6q6de88mj8qkg0q5lupmpfexwnqjsr4d2gvx2p?pj=HTTPS://PAYJO.IN/TXJCGKTKXLUUZ"
        #expect(throws: PaymentURIError.invalidPayjoinEndpoint("no fragment")) { try PaymentURI(noFragment) }
        let ftp = Self.example.replacingOccurrences(of: "HTTPS://", with: "FTP://")
        #expect(throws: PaymentURIError.invalidPayjoinEndpoint("url")) { try PaymentURI(ftp) }
    }

    @Test("plain BIP 21: amounts, labels, unknown and required parameters")
    func bip21() throws {
        let plain = try PaymentURI("BITCOIN:bc1qexample?amount=1.5&label=Caf%C3%A9&message=hi%20there&foo=bar")
        #expect(plain.address == "bc1qexample")
        #expect(plain.amountSats == 150_000_000)
        #expect(plain.label == "Café")
        #expect(plain.message == "hi there")
        #expect(plain.payjoin == nil)
        #expect(try PaymentURI("bitcoin:bc1qexample").amountSats == nil)
        #expect(try PaymentURI("bitcoin:bc1qexample?amount=.5").amountSats == 50_000_000)
        #expect(try PaymentURI("bitcoin:bc1qexample?amount=1.").amountSats == 100_000_000)
        #expect(try PaymentURI("bitcoin:bc1qexample?amount=21000000").amountSats == 2_100_000_000_000_000)
        #expect(throws: PaymentURIError.unsupportedRequiredParameter("req-something")) {
            try PaymentURI("bitcoin:bc1qexample?req-something=1")
        }
        #expect(try PaymentURI(Self.example.replacingOccurrences(of: "&pj=", with: "&req-pj=")).payjoinRequired)
        #expect(throws: PaymentURIError.notABitcoinURI) { try PaymentURI("lightning:lnbc1") }
        #expect(throws: PaymentURIError.missingAddress) { try PaymentURI("bitcoin:?amount=1") }
        #expect(throws: PaymentURIError.duplicateParameter("amount")) { try PaymentURI("bitcoin:x?amount=1&amount=2") }
        for bad in ["1e5", "0.123456789", "-1", "21000001", "", "abc", "."] {
            #expect(throws: PaymentURIError.invalidAmount, "amount \(bad)") { try PaymentURI("bitcoin:x?amount=\(bad)") }
        }
        #expect(PaymentURI.looksLikeURI(" Bitcoin:abc") == false)
        #expect(PaymentURI.looksLikeURI("bitcoin:abc"))
    }

    @Test("bech32 without checksum round trips bytes and uppercases")
    func bech32NoChecksum() throws {
        let bytes: [UInt8] = [0, 1, 2, 3, 31, 32, 33, 95, 0, 96, 127, 128, 129, 254, 255, 0]
        let encoded = Bech32.encodeWithoutChecksum(hrp: "STUFF", data: bytes)
        #expect(encoded == encoded.uppercased())
        let decoded = try Bech32.decodeWithoutChecksum(encoded)
        #expect(decoded.hrp == "stuff")
        #expect(decoded.bytes == bytes)
        #expect(encoded.count == 6 + Int((Double(bytes.count) * 8 / 5).rounded(.up)))
    }
}
