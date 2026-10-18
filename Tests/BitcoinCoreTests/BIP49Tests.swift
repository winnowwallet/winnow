import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// BIP49 test vectors parsed from bip-0049.mediawiki: the testnet account under
/// `uprv`/`upub`, its first receiving key as a WIF, and the nested-segwit
/// address built from the published intermediate hashes.
@Suite("BIP49")
struct BIP49Tests {
    /// Every `name = value` line of the vector block, keyed by name. A line
    /// with two `=` keeps the last value; a `(testnet)` suffix and a `0x`
    /// prefix are stripped.
    static func fields() throws -> [String: String] {
        let text = try Vectors.string("bip-0049.mediawiki", in: .module)
        guard let start = text.range(of: "==Test vectors=="),
              let open = text.range(of: "<pre>", range: start.upperBound ..< text.endIndex),
              let close = text.range(of: "</pre>", range: open.upperBound ..< text.endIndex)
        else { throw VectorError.malformed("no vector block") }
        var fields: [String: String] = [:]
        for line in text[open.upperBound ..< close.lowerBound].components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
            let parts = trimmed.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }
            var value = parts[parts.count - 1].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix("(testnet)") { value = String(value.dropLast("(testnet)".count)) }
            if value.hasPrefix("0x") { value = String(value.dropFirst(2)) }
            fields[parts[0].trimmingCharacters(in: .whitespaces)] = value.trimmingCharacters(in: .whitespaces)
        }
        return fields
    }

    @Test("master and account keys serialize as uprv and upub")
    func accountKeys() throws {
        let fields = try Self.fields()
        let master = try HDKey(seed: BIP39.seed(mnemonic: fields["masterseedWords"]!))
        #expect(master.serialized(version: .upub) == fields["masterseed"])
        let account = try AccountPurpose.bip49.accountKey(from: master, coinType: 1)
        let version = AccountPurpose.bip49.extendedKeyVersion(network: .testnet)
        #expect(version == .upub && version.publicPrefix == "upub")
        #expect(account.serialized(version: version) == fields["account0Xpriv"])
        #expect(account.neutered.serialized(version: version) == fields["account0Xpub"])
        let decoded = try ExtendedKeyVersion.decode(fields["account0Xpub"]!)
        #expect(decoded.version == .upub && decoded.key == account.neutered)
    }

    @Test("first receiving key, its WIF, and the published hashes to the address")
    func firstAddress() throws {
        let fields = try Self.fields()
        let master = try HDKey(seed: BIP39.seed(mnemonic: fields["masterseedWords"]!))
        let key = try master.derived(path: "m/49'/1'/0'/0/0")
        #expect(key.privateKey == Data(hex: fields["account0recvPrivateKeyHex"]!))
        #expect(key.publicKey == Data(hex: fields["account0recvPublicKeyHex"]!))
        let wif = try WIF(secret: key.privateKey!, compressed: true, network: .testnet)
        #expect(wif.serialized == fields["account0recvPrivateKey"])
        #expect(try WIF(fields["account0recvPrivateKey"]!).secret == key.privateKey)

        let keyhash = Hash160.hash(key.publicKey)
        #expect(keyhash == Data(hex: fields["keyhash"]!))
        let redeemScript = Data([0x00, 0x14]) + keyhash
        #expect(redeemScript == Data(hex: fields["scriptSig"]!))
        let addressBytes = Hash160.hash(redeemScript)
        #expect(addressBytes == Data(hex: fields["addressBytes"]!))
        #expect(Base58Check.encode(Data([0xC4]) + addressBytes) == fields["address"])
    }
}
