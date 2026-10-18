import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// Bitcoin Core's key_io vectors (`src/test/data` at v31.0): every private key
/// row decodes to its secret, flag and chain and re-encodes byte for byte, and
/// every string in the invalid file is refused.
@Suite("WIF")
struct WIFTests {
    struct Row {
        let string: String
        let secret: Data
        let compressed: Bool
        let chain: String

        var network: HDKey.Network { chain == "main" ? .mainnet : .testnet }
    }

    static func privateKeyRows() throws -> [Row] {
        let json = try Vectors.json("key_io_valid.json", in: .module) as! [[Any]]
        return try json.compactMap { row in
            let meta = row[2] as! [String: Any]
            guard meta["isPrivkey"] as? Bool == true else { return nil }
            guard let secret = Data(hex: row[1] as! String) else { throw VectorError.badHex(row[0] as! String) }
            return Row(string: row[0] as! String, secret: secret,
                       compressed: meta["isCompressed"] as! Bool, chain: meta["chain"] as! String)
        }
    }

    static func invalidStrings() throws -> [String] {
        (try Vectors.json("key_io_invalid.json", in: .module) as! [[String]]).map { $0[0] }
    }

    @Test("16 private key rows over four chains")
    func rowsParsed() throws {
        let rows = try Self.privateKeyRows()
        #expect(rows.count == 16)
        #expect(Set(rows.map(\.chain)) == ["main", "testnet4", "signet", "regtest"])
        #expect(rows.filter(\.compressed).count == 8)
    }

    @Test("every key decodes to Core's secret, flag and chain, and re-encodes")
    func decodeAndEncode() throws {
        for row in try Self.privateKeyRows() {
            let key = try WIF(row.string)
            #expect(key.secret == row.secret, "\(row.string)")
            #expect(key.compressed == row.compressed, "\(row.string)")
            #expect(key.network == row.network, "\(row.string)")
            #expect(key.serialized == row.string, "\(row.string)")
            #expect(try WIF(row.string, network: row.network) == key, "\(row.string)")
            #expect(try WIF(secret: row.secret, compressed: row.compressed, network: row.network) == key, "\(row.string)")
        }
    }

    @Test("the public key follows the compression flag")
    func publicKeyForm() throws {
        for row in try Self.privateKeyRows() {
            let key = try WIF(row.string)
            let compressedForm = try HDKey.publicKey(for: row.secret)
            if row.compressed {
                #expect(key.publicKey == compressedForm, "\(row.string)")
            } else {
                #expect(key.publicKey.count == 65 && key.publicKey.first == 0x04, "\(row.string)")
                // The same point: the compressed form's x coordinate.
                #expect(key.publicKey.dropFirst().prefix(32) == compressedForm.dropFirst(), "\(row.string)")
            }
        }
    }

    @Test("a key from the other network is refused by name")
    func wrongNetwork() throws {
        for row in try Self.privateKeyRows() {
            let other: HDKey.Network = row.network == .mainnet ? .testnet : .mainnet
            #expect(throws: WIFError.wrongNetwork(expected: other, found: row.network), "\(row.string)") {
                try WIF(row.string, network: other)
            }
        }
    }

    @Test("every key_io invalid string is refused")
    func invalidRefused() throws {
        let strings = try Self.invalidStrings()
        #expect(strings.count == 70)
        for string in strings {
            #expect(throws: (any Error).self, "\(string)") { try WIF(string) }
        }
    }

    @Test("version byte, compression marker, secret range and length are each checked")
    func malformed() throws {
        let secret = try Self.privateKeyRows()[0].secret
        #expect(throws: WIFError.invalidVersion(0x81)) {
            try WIF(Base58Check.encode(Data([0x81]) + secret))
        }
        #expect(throws: WIFError.invalidCompressionMarker) {
            try WIF(Base58Check.encode(Data([0x80]) + secret + Data([0x02])))
        }
        #expect(throws: WIFError.invalidSecret) {
            try WIF(Base58Check.encode(Data([0x80]) + Data(repeating: 0, count: 32)))
        }
        // The group order n is the first value outside [1, n-1].
        let order = Data(hex: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")!
        #expect(throws: WIFError.invalidSecret) { try WIF(secret: order, compressed: true, network: .mainnet) }
        #expect(throws: WIFError.invalidEncoding) {
            try WIF(Base58Check.encode(Data([0x80]) + secret.prefix(31)))
        }
        #expect(throws: WIFError.invalidEncoding) { try WIF("0OIl") }
        #expect(throws: WIFError.invalidEncoding) { try WIF("") }
    }
}
