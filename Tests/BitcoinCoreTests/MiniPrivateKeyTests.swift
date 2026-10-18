import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// The Bitcoin wiki's mini private keys: the 30-character sample on "Mini
/// private key format" and the 22-character key whose secret the wiki's
/// "Private key" page uses as its WIF example. Secrets, WIFs and addresses
/// were recomputed outside Winnow (hashlib and a plain secp256k1) before
/// being written here.
@Suite("Mini private keys")
struct MiniPrivateKeyTests {
    struct Vector {
        let text: String
        let secret: String
        let wif: String
        let address: String
    }

    static let vectors = [
        Vector(text: "S6c56bnXQiBjk9mqSYE7ykVQ7NzrRy",
               secret: "4c7a9640c72dc2099f23715d0c8a0d8a35f8906e3cab61dd3f78b67bf887c9ab",
               wif: "5JPy8Zg7z4P7RSLsiqcqyeAF1935zjNUdMxcDeVrtU1oarrgnB7",
               address: "1CciesT23BNionJeXrbxmjc7ywfiyM4oLW"),
        Vector(text: "SzavMBLoXU6kDrqtUVmffv",
               secret: "e9873d79c6d87dc0fb6a5778633389f4453213303da61f20bd67fc233aa33262",
               wif: "5Kb8kLf9zgWQnogidDA76MzPL6TsZZY36hWXMssSzNydYXYB9KF",
               address: "1CC3X2gu58d6wXUWMffpuzN9JAfTUWu4Kj"),
    ]

    @Test("both formats decode to the published secret, WIF and uncompressed address")
    func decode() throws {
        for vector in Self.vectors {
            #expect(try MiniPrivateKey.secret(vector.text) == Data(hex: vector.secret), "\(vector.text)")
            let key = try MiniPrivateKey.wif(vector.text)
            #expect(key.serialized == vector.wif, "\(vector.text)")
            #expect(!key.compressed && key.network == .mainnet, "\(vector.text)")
            // P2PKH over the uncompressed key, as the coins were printed.
            let address = Base58Check.encode(Data([0x00]) + Hash160.hash(key.publicKey))
            #expect(address == vector.address, "\(vector.text)")
        }
    }

    @Test("a compressed or test-network reading is a caller's choice")
    func otherForms() throws {
        let key = try MiniPrivateKey.wif(Self.vectors[0].text, compressed: true, network: .testnet)
        #expect(key.compressed && key.network == .testnet)
        #expect(try WIF(key.serialized) == key)
    }

    @Test("a one-character typo fails the check; shape errors are named")
    func refusals() throws {
        let text = Self.vectors[0].text
        #expect(throws: MiniPrivateKeyError.checkFailed) {
            try MiniPrivateKey.secret(String(text.dropLast()) + "z")
        }
        #expect(throws: MiniPrivateKeyError.invalidLength) { try MiniPrivateKey.secret(String(text.dropLast())) }
        #expect(throws: MiniPrivateKeyError.invalidLength) { try MiniPrivateKey.secret(text + "?") }
        #expect(throws: MiniPrivateKeyError.invalidLength) { try MiniPrivateKey.secret("s" + text.dropFirst()) }
        #expect(throws: MiniPrivateKeyError.invalidLength) { try MiniPrivateKey.secret("") }
        #expect(throws: MiniPrivateKeyError.invalidCharacter) {
            try MiniPrivateKey.secret(String(text.dropLast()) + "0")
        }
        #expect(throws: MiniPrivateKeyError.invalidCharacter) {
            try MiniPrivateKey.secret(String(text.dropLast()) + "I")
        }
    }

    @Test("Core's invalid key_io strings are not mini keys either")
    func keyIOInvalid() throws {
        for string in try WIFTests.invalidStrings() {
            #expect(throws: (any Error).self, "\(string)") { try MiniPrivateKey.secret(string) }
        }
    }
}
