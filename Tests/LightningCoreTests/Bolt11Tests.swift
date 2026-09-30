import Foundation
import WalletCore
import XCTest
@testable import LightningCore

final class Bolt11Tests: XCTestCase {
    private let secret = Data(repeating: 1, count: 32)
    private func encoded(network: BitcoinNetwork = .mainnet, amount: UInt64 = 21_000) throws -> String {
        try Bolt11Invoice.encode(network: network, amountMsat: amount, hash: Data(repeating: 2, count: 32),
            secret: Data(repeating: 3, count: 32), nodeSecret: secret,
            route: .init(peer: ChannelKeys.publicKey(secret: Data(repeating: 4, count: 32)), shortChannelID: 123,
                         baseMsat: 1000, proportionalMillionths: 100, expiryDelta: 40), timestamp: 1_790_000_000)
    }
    func testPublishedBolt11InvoiceVector() throws {
        // BOLT 11's published coffee example, independent of our encoder.
        let vector = "lnbc2500u1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpu9qrsgquk0rl77nj30yxdy8j9vdx85fkpmdla2087ne0xh8nhedh8w27kyke0lp53ut353s06fv3qfegext0eh0ymjpf39tuven09sam30g4vgpfna3rh"
        let value = try Bolt11Invoice.decode(vector, network: .mainnet)
        XCTAssertEqual(value.amountMsat, 250_000_000)
        XCTAssertEqual(value.timestamp, 1_496_314_658)
        XCTAssertEqual(value.expirySeconds, 60)
        XCTAssertEqual(value.paymentHash.hex, "0001020304050607080900010203040506070809000102030405060708090102")
        XCTAssertEqual(value.payee.hex, "03e7156ae33b0a208d0744199163177e909e80176e55d97a2f221ede0f934dd9ad")
    }
    func testInvoicesBindNetworkAmountSecretAndNodeAndHavePrivateRoute() throws {
        for network in [BitcoinNetwork.mainnet, .signet, .regtest] {
            let text = try encoded(network: network), decoded = try Bolt11Invoice.decode(text.uppercased(), network: network)
            XCTAssertEqual(decoded.amountMsat, 21_000)
            XCTAssertEqual(decoded.paymentHash, Data(repeating: 2, count: 32))
            XCTAssertEqual(decoded.paymentSecret, Data(repeating: 3, count: 32))
            XCTAssertEqual(decoded.payee, try ChannelKeys.publicKey(secret: secret))
            let words = try Bech32.decode(text, maxLength: 4096).data
            var offset = 7, route: Data?
            while offset < words.count - 104 {
                let length = Int(words[offset + 1]) * 32 + Int(words[offset + 2])
                if words[offset] == 3 { route = Data(try SegwitAddress.convertBits(Array(words[(offset + 3)..<(offset + 3 + length)]), from: 5, to: 8, pad: false)) }
                offset += length + 3
            }
            XCTAssertEqual(route?.count, 51)
            var reader = LightningWire.Reader(try XCTUnwrap(route))
            XCTAssertEqual(try reader.take(33), try ChannelKeys.publicKey(secret: Data(repeating: 4, count: 32)))
            XCTAssertEqual(try reader.u64(), 123)
            XCTAssertEqual(try reader.u32(), 1000)
            XCTAssertEqual(try reader.u32(), 100)
            XCTAssertEqual(try reader.u16(), 40)
            for other in [BitcoinNetwork.mainnet, .signet, .regtest] where other != network {
                XCTAssertThrowsError(try Bolt11Invoice.decode(text, network: other))
            }
        }
    }
    func testCorruptSignatureFailsWithoutCrashingEvenWithValidChecksum() throws {
        let (hrp, original, _) = try Bech32.decode(encoded(), maxLength: 4096)
        for signature in [Data(repeating: 0, count: 65), Data(repeating: 255, count: 65)] {
            let words = Array(original.dropLast(104)) + (try SegwitAddress.convertBits(Array(signature), from: 8, to: 5, pad: true))
            let malicious = try Bech32.encode(hrp: hrp, data: words, encoding: .bech32, maxLength: 4096)
            XCTAssertThrowsError(try Bolt11Invoice.decode(malicious, network: .mainnet))
        }
        let valid = try encoded()
        XCTAssertThrowsError(try Bolt11Invoice.decode(String(valid.dropLast()) + "q", network: .mainnet))
        XCTAssertThrowsError(try encoded(amount: .max))
        XCTAssertThrowsError(try encoded(amount: 0))
    }
}
