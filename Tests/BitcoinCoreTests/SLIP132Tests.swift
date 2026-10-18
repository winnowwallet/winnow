import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// SLIP-0132 parsed from slip-0132.md: the registry's Bitcoin rows, byte for
/// byte and prefix for prefix, and its test vectors for the three purposes.
@Suite("SLIP-0132")
struct SLIP132Tests {
    struct Row {
        let coin: String
        let publicBytes: UInt32
        let publicPrefix: String
        let privateBytes: UInt32
        let privatePrefix: String
        let encoding: String
    }

    struct AccountVector {
        let path: String
        let xprv: String
        let xpub: String
        let address: String
    }

    /// `Bitcoin | `0x0488b21e` - `xpub` | `0x0488ade4` - `xprv` | P2PKH or P2SH | m/44'/0' |`
    static func bitcoinRows() throws -> [Row] {
        let text = try Vectors.string("slip-0132.md", in: .module)
        return try text.components(separatedBy: .newlines).compactMap { line in
            let columns = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 5, columns[0] == "Bitcoin" || columns[0] == "Bitcoin Testnet" else { return nil }
            func cell(_ text: String) throws -> (UInt32, String) {
                let parts = text.components(separatedBy: "`")
                guard parts.count >= 4, parts[1].hasPrefix("0x"), let bytes = UInt32(parts[1].dropFirst(2), radix: 16) else {
                    throw VectorError.malformed(line)
                }
                return (bytes, parts[3])
            }
            let (publicBytes, publicPrefix) = try cell(columns[1])
            let (privateBytes, privatePrefix) = try cell(columns[2])
            return Row(coin: columns[0], publicBytes: publicBytes, publicPrefix: publicPrefix,
                       privateBytes: privateBytes, privatePrefix: privatePrefix, encoding: columns[3])
        }
    }

    /// The fenced block under "## Bitcoin Test Vectors".
    static func testVectors() throws -> (mnemonic: String, accounts: [AccountVector]) {
        let text = try Vectors.string("slip-0132.md", in: .module)
        guard let heading = text.range(of: "## Bitcoin Test Vectors"),
              let open = text.range(of: "```", range: heading.upperBound ..< text.endIndex),
              let close = text.range(of: "```", range: open.upperBound ..< text.endIndex)
        else { throw VectorError.malformed("no test vector block") }
        var mnemonic = ""
        var accounts: [AccountVector] = []
        var pending: (path: String, keys: [String])?
        var addressPending = false
        for line in text[open.upperBound ..< close.lowerBound].components(separatedBy: .newlines) where !line.isEmpty {
            if line.hasPrefix("Mnemonic: ") {
                mnemonic = String(line.dropFirst("Mnemonic: ".count))
            } else if line.hasSuffix(" address:") {
                addressPending = true
            } else if line.hasPrefix("m/") {
                pending = (line, [])
            } else if addressPending, let account = pending, account.keys.count == 2 {
                accounts.append(AccountVector(path: account.path, xprv: account.keys[0], xpub: account.keys[1], address: line))
                pending = nil
                addressPending = false
            } else {
                pending?.keys.append(line)
            }
        }
        return (mnemonic, accounts)
    }

    static func script(for encoding: String) -> ExtendedKeyVersion.Script? {
        switch encoding {
        case "P2PKH or P2SH": .legacy
        case "P2WPKH in P2SH": .nestedSegwit
        case "P2WPKH": .nativeSegwit
        case "Multi-signature P2WSH in P2SH": .nestedSegwitMultisig
        case "Multi-signature P2WSH": .nativeSegwitMultisig
        default: nil
        }
    }

    @Test("the registry is the SLIP's ten Bitcoin rows, in order")
    func registry() throws {
        let rows = try Self.bitcoinRows()
        #expect(rows.count == 10)
        #expect(ExtendedKeyVersion.registry.count == rows.count)
        for (row, version) in zip(rows, ExtendedKeyVersion.registry) {
            #expect(version.publicBytes == row.publicBytes, "\(row.publicPrefix)")
            #expect(version.privateBytes == row.privateBytes, "\(row.privatePrefix)")
            #expect(version.publicPrefix == row.publicPrefix && version.privatePrefix == row.privatePrefix)
            #expect(version.network == (row.coin == "Bitcoin" ? .mainnet : .testnet), "\(row.publicPrefix)")
            #expect(version.script == Self.script(for: row.encoding), "\(row.encoding)")
            #expect(ExtendedKeyVersion.named(row.publicPrefix) == version)
            #expect(ExtendedKeyVersion.named(row.privatePrefix) == version)
            #expect(ExtendedKeyVersion.matching(bytes: row.publicBytes) == version)
            #expect(ExtendedKeyVersion.matching(bytes: row.privateBytes) == version)
            #expect(ExtendedKeyVersion.version(for: version.script, network: version.network) == version)
        }
        #expect(ExtendedKeyVersion.named("Zpub") != ExtendedKeyVersion.named("zpub"))
        #expect(ExtendedKeyVersion.named("qpub") == nil)
        #expect(ExtendedKeyVersion.xpub.publicBytes == HDKey.Network.mainnet.publicVersion)
        #expect(ExtendedKeyVersion.tpub.privateBytes == HDKey.Network.testnet.privateVersion)
    }

    @Test("the SLIP's three accounts: keys under their prefixes, first addresses")
    func accounts() throws {
        let (mnemonic, accounts) = try Self.testVectors()
        #expect(accounts.map(\.path) == ["m/44'/0'/0'", "m/49'/0'/0'", "m/84'/0'/0'"])
        let master = try HDKey(seed: BIP39.seed(mnemonic: mnemonic))
        for vector in accounts {
            let purpose = AccountPurpose(rawValue: UInt32(vector.path.split(separator: "/")[1].dropLast())!)!
            let account = try purpose.accountKey(from: master)
            let version = purpose.extendedKeyVersion(network: .mainnet)
            #expect(account.serialized(version: version) == vector.xprv, "\(vector.path)")
            #expect(account.neutered.serialized(version: version) == vector.xpub, "\(vector.path)")
            #expect(try ExtendedKeyVersion.decode(vector.xpub).version == version, "\(vector.path)")
            #expect(try ExtendedKeyVersion.decode(vector.xprv).key == account, "\(vector.path)")

            let publicKey = try account.derived(path: [0, 0]).publicKey
            let address: String
            switch purpose {
            case .bip44: address = Base58Check.encode(Data([0x00]) + Hash160.hash(publicKey))
            case .bip49: address = Base58Check.encode(Data([0x05]) + Hash160.hash(Data([0x00, 0x14]) + Hash160.hash(publicKey)))
            case .bip84: address = try SegwitAddress.encode(hrp: "bc", version: 0, program: Hash160.hash(publicKey))
            case .bip86: address = try BIP86.address(internalKey: BIP86.xonlyPublicKey(of: account.derived(path: [0, 0])))
            }
            #expect(address == vector.address, "\(vector.path)")
        }
    }

    @Test("bytes outside the Bitcoin rows are refused")
    func foreignVersion() throws {
        let (_, accounts) = try Self.testVectors()
        var payload = try Base58Check.decode(accounts[0].xpub)
        // Litecoin testnet's `ttub`, from the same table.
        payload.replaceSubrange(0 ..< 4, with: [0x04, 0x36, 0xF6, 0xE1])
        #expect(throws: BIP32Error.invalidVersion) { try ExtendedKeyVersion.decode(Base58Check.encode(payload)) }
        #expect(throws: BIP32Error.invalidVersion) { try HDKey.deserialize(Base58Check.encode(payload)) }
    }
}
