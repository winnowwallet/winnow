import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// BIP84 test vectors parsed from bip-0084.mediawiki: root and account keys
/// under `zprv`/`zpub`, and three addresses with their keys as WIFs.
@Suite("BIP84")
struct BIP84Tests {
    struct AddressVector {
        let path: String
        let privkey: String
        let pubkey: Data
        let address: String
    }

    struct Vectors {
        var mnemonic = ""
        var rootpriv = ""
        var rootpub = ""
        var accountXpriv = ""
        var accountXpub = ""
        var addresses: [AddressVector] = []
    }

    static func vectors() throws -> Vectors {
        let text = try TestSupport.Vectors.string("bip-0084.mediawiki", in: .module)
        guard let start = text.range(of: "==Test vectors=="),
              let open = text.range(of: "<pre>", range: start.upperBound ..< text.endIndex),
              let close = text.range(of: "</pre>", range: open.upperBound ..< text.endIndex)
        else { throw VectorError.malformed("no vector block") }
        var vectors = Vectors()
        var path: String?
        var fields: [String: String] = [:]

        func flush() {
            if let path, path.split(separator: "/").count == 6, let privkey = fields["privkey"],
               let pubkey = fields["pubkey"].flatMap(Data.init(hex:)), let address = fields["address"]
            {
                vectors.addresses.append(AddressVector(path: path, privkey: privkey, pubkey: pubkey, address: address))
            }
            fields = [:]
        }

        for line in text[open.upperBound ..< close.lowerBound].components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") {
                flush()
                path = trimmed.components(separatedBy: "= ").last
            } else if let eq = trimmed.firstIndex(of: "=") {
                let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
                let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                switch (key, path) {
                case ("mnemonic", _): vectors.mnemonic = value
                case ("rootpriv", _): vectors.rootpriv = value
                case ("rootpub", _): vectors.rootpub = value
                case ("xpriv", "m/84'/0'/0'"?): vectors.accountXpriv = value
                case ("xpub", "m/84'/0'/0'"?): vectors.accountXpub = value
                default: fields[key] = value
                }
            }
        }
        flush()
        return vectors
    }

    @Test("vector block parsed")
    func parsed() throws {
        let vectors = try Self.vectors()
        #expect(vectors.mnemonic.hasPrefix("abandon abandon"))
        #expect(vectors.addresses.map(\.path) == ["m/84'/0'/0'/0/0", "m/84'/0'/0'/0/1", "m/84'/0'/0'/1/0"])
        #expect(vectors.rootpriv.hasPrefix("zprv") && vectors.accountXpub.hasPrefix("zpub"))
    }

    @Test("root and account keys serialize as zprv and zpub")
    func accountKeys() throws {
        let vectors = try Self.vectors()
        let master = try HDKey(seed: BIP39.seed(mnemonic: vectors.mnemonic))
        #expect(master.serialized(version: .zpub) == vectors.rootpriv)
        #expect(master.neutered.serialized(version: .zpub) == vectors.rootpub)
        let account = try AccountPurpose.bip84.accountKey(from: master)
        let version = AccountPurpose.bip84.extendedKeyVersion(network: .mainnet)
        #expect(version == .zpub)
        #expect(account.serialized(version: version) == vectors.accountXpriv)
        #expect(account.neutered.serialized(version: version) == vectors.accountXpub)
        let decoded = try ExtendedKeyVersion.decode(vectors.accountXpriv)
        #expect(decoded.version == .zpub && decoded.key == account)
        // The BIP32 parser keeps refusing the registry's other prefixes.
        #expect(throws: BIP32Error.invalidVersion) { try HDKey.deserialize(vectors.accountXpub) }
    }

    @Test("each address: the key as a WIF, the public key, the P2WPKH address")
    func addresses() throws {
        let vectors = try Self.vectors()
        let master = try HDKey(seed: BIP39.seed(mnemonic: vectors.mnemonic))
        for vector in vectors.addresses {
            let key = try master.derived(path: vector.path)
            #expect(key.publicKey == vector.pubkey, "\(vector.path)")
            let wif = try WIF(secret: key.privateKey!, compressed: true, network: .mainnet)
            #expect(wif.serialized == vector.privkey, "\(vector.path)")
            #expect(try WIF(vector.privkey).publicKey == vector.pubkey, "\(vector.path)")
            let address = try SegwitAddress.encode(hrp: "bc", version: 0, program: Hash160.hash(key.publicKey))
            #expect(address == vector.address, "\(vector.path)")
        }
    }
}
