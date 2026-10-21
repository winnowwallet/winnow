import Foundation
import NativeSecp256k1
import Testing
import TestSupport
@testable import WalletCore

/// BIP340 tagged SHA-256 from the native module, checked against answers
/// computed elsewhere: Python hashlib, libsecp256k1's `secp256k1_tagged_sha256`
/// (the long-tag case), and the seven BIP341 wallet vectors.
@Suite("Native tagged SHA-256")
struct NativeSecp256k1TaggedHashTests {
    @Test("known answers for empty, binary, UTF-8 and long tags", arguments: [
        ("", "", "2dba5dbc339e7316aea2683faf839c1b7b1ee2313db792112588118df066aa35"),
        ("TapTweak", String(repeating: "00", count: 32),
         "38acfd2d72ad71541503bf9521485ed40eb70ad40dd562d29677a32c917d8e61"),
        ("tag\u{0000}é", "00ff0080", "993e2a8afb22675b3d03fc2de430ff2addd8757b0152b47e4de8d3fc9ceeb88f"),
        (String(repeating: "t", count: 129), (0...64).map { String(format: "%02x", $0) }.joined(),
         "e5306564af3895c9c1bdd3d68997eb88e3c3b7450c6fda40ae4340b3d53a1be8"),
    ])
    func knownAnswers(tag: String, messageHex: String, expected: String) throws {
        let message = try #require(messageHex.isEmpty ? Data() : Data(hex: messageHex))
        #expect(TaggedSHA256.hash(tag: tag, message: message).hex == expected)
        // Slices need not start at index zero.
        let slice = (Data([0xA5]) + message).dropFirst()
        #expect(TaggedSHA256.hash(tag: tag, message: slice).hex == expected)
    }

    @Test("BIP341 wallet vectors: TapTweak of internal key and merkle root")
    func tapTweakVectors() throws {
        let root = try Vectors.json("bip341-wallet-test-vectors.json", in: .module) as! [String: Any]
        let cases = root["scriptPubKey"] as! [[String: Any]]
        #expect(cases.count == 7)
        for testCase in cases {
            let given = testCase["given"] as! [String: Any]
            let intermediary = testCase["intermediary"] as! [String: Any]
            let internalKey = try #require(Data(hex: given["internalPubkey"] as! String))
            let merkleRoot = (intermediary["merkleRoot"] as? String).flatMap { Data(hex: $0) } ?? Data()
            let expected = try #require(Data(hex: intermediary["tweak"] as! String))
            #expect(TaggedSHA256.hash(tag: "TapTweak", message: internalKey + merkleRoot) == expected)
        }
    }
}
