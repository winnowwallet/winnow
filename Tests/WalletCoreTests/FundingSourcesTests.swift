import CryptoKit
import Foundation
import Testing
@testable import WalletCore

@Suite("Funding source reconstruction from transaction inputs")
struct FundingSourcesTests {
    @Test("Every PUSHDATA width reconstructs the same redeem script, including a Data slice")
    func pushDataWidths() {
        let redeem = Data([0, 20]) + Self.generatorHash160
        for length in [Data([0x4c, 22]), Data([0x4d, 22, 0]), Data([0x4e, 22, 0, 0, 0])] {
            let prefixed = Data([0xff]) + length + redeem
            let tx = Self.transaction([Self.input(scriptSig: prefixed.dropFirst())])
            #expect(FundingSources.sources(of: tx).first?.scriptPubKey == Data([0xa9, 20]) + Hash160.hash(redeem) + Data([0x87]))
        }
    }
    @Test("Truncated lengths, impossible payloads, and non-push scriptSigs reveal no funder")
    func pushDataTruncation() {
        for script in [Data([0x4c]), Data([0x4c, 1]), Data([0x4d, 1]), Data([0x4d, 1, 0]),
                       Data([0x4e, 1, 0, 0]), Data([0x4e, 0xff, 0xff, 0xff, 0xff]), Data([0x76])] {
            let tx = Self.transaction([Self.input(scriptSig: script)])
            #expect(FundingSources.sources(of: tx).first?.revelation == .unrecognized)
            #expect(FundingSources.fundingScripts(of: tx).isEmpty)
        }
    }
    /// The secp256k1 generator in compressed form; its hash160 is the BIP173
    /// reference value reused as ground truth throughout.
    static let generator = Data(hex: "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")!
    static let generatorHash160 = Data(hex: "751e76e8199196d454941c45d1b3a323f1433bd6")!

    /// DER-shaped ECDSA signature + sighash byte (shape only — the
    /// reconstruction never verifies signatures).
    static let derSignature = Data([0x30, 0x44]) + Data(repeating: 0x42, count: 68) + Data([0x01])
    static let schnorrSignature = Data(repeating: 0x5A, count: 64)

    private static func input(txid: Data = Data(repeating: 0x11, count: 32), vout: UInt32 = 0,
                              scriptSig: Data = Data(), witness: [Data] = []) -> Transaction.Input {
        Transaction.Input(previousOutput: .init(txid: txid, vout: vout),
                          scriptSig: scriptSig, sequence: 0xFFFF_FFFE, witness: witness)
    }

    private static func transaction(_ inputs: [Transaction.Input]) -> Transaction {
        Transaction(version: 2, inputs: inputs,
                    outputs: [.init(value: 1_000,
                                    scriptPubKey: Data([0x51, 0x20]) + Data(repeating: 0x22, count: 32))],
                    locktime: 0)
    }

    private static func push(_ data: Data) -> Data {
        precondition(data.count < 0x4C)
        return Data([UInt8(data.count)]) + data
    }

    private static func scriptSig(_ items: [Data]) -> Data {
        items.reduce(Data()) { $0 + push($1) }
    }

    @Test("Coinbase input has no funder")
    func coinbase() {
        let tx = Self.transaction([Self.input(txid: Data(repeating: 0, count: 32), vout: 0xFFFF_FFFF)])
        let sources = FundingSources.sources(of: tx)
        #expect(sources == [.init(inputIndex: 0, revelation: .coinbase, scriptPubKey: nil)])
        #expect(FundingSources.fundingScripts(of: tx).isEmpty)
    }

    @Test("P2PKH: scriptSig reveals the public key and its hash160 address")
    func p2pkh() {
        let tx = Self.transaction([Self.input(scriptSig: Self.scriptSig([Self.derSignature, Self.generator]))])
        let expected = Data([0x76, 0xA9, 0x14]) + Self.generatorHash160 + Data([0x88, 0xAC])
        let sources = FundingSources.sources(of: tx)
        #expect(sources.first?.revelation == .publicKeyHash)
        #expect(sources.first?.scriptPubKey == expected)
        // Ground truth: the same hash160 as the BIP173 reference address.
        #expect(AddressDecoder.address(for: expected, network: .mainnet)
            == "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH")
    }

    @Test("P2SH: the last scriptSig push is the redeem script")
    func p2sh() throws {
        let redeem = Data([0x00, 0x14]) + Self.generatorHash160 // wrapped P2WPKH
        let tx = Self.transaction([Self.input(scriptSig: Self.scriptSig([Data(), Self.derSignature, redeem]))])
        let expected = Data([0xA9, 0x14]) + Hash160.hash(redeem) + Data([0x87])
        let sources = FundingSources.sources(of: tx)
        #expect(sources.first?.revelation == .scriptHash)
        #expect(sources.first?.scriptPubKey == expected)
        // The funding address is the P2SH wrapper, and it round-trips.
        let address = AddressDecoder.address(for: expected, network: .mainnet)
        #expect(address != nil)
        #expect(try AddressDecoder.scriptPubKey(for: address!, network: .mainnet) == expected)
    }

    @Test("P2SH-wrapped segwit: the wrapper, not the inner script, is the funding address")
    func p2shWrappedSegwit() {
        let redeem = Data([0x00, 0x14]) + Self.generatorHash160
        let tx = Self.transaction([Self.input(scriptSig: Self.scriptSig([redeem]),
                                    witness: [Self.derSignature, Self.generator])])
        let sources = FundingSources.sources(of: tx)
        #expect(sources.first?.revelation == .scriptHash)
        #expect(sources.first?.scriptPubKey == Data([0xA9, 0x14]) + Hash160.hash(redeem) + Data([0x87]))
    }

    @Test("P2WPKH: witness reveals the public key")
    func p2wpkh() {
        let tx = Self.transaction([Self.input(witness: [Self.derSignature, Self.generator])])
        let expected = Data([0x00, 0x14]) + Self.generatorHash160
        let sources = FundingSources.sources(of: tx)
        #expect(sources.first?.revelation == .witnessKeyHash)
        #expect(sources.first?.scriptPubKey == expected)
        #expect(AddressDecoder.address(for: expected, network: .mainnet)
            == "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
    }

    @Test("P2WSH: the last witness item is the witness script")
    func p2wsh() throws {
        let key2 = Data([0x03]) + Data(repeating: 0x02, count: 32)
        let key3 = Data([0x02]) + Data(repeating: 0x03, count: 32)
        let witnessScript = Script.build { script in
            script.appendOpcode(Script.Op.n(2))
            script.appendPush(Self.generator)
            script.appendPush(key2)
            script.appendPush(key3)
            script.appendOpcode(Script.Op.n(3))
            script.appendOpcode(0xAE) // OP_CHECKMULTISIG
        }
        let tx = Self.transaction([Self.input(witness: [Data(), Self.derSignature, Self.derSignature,
                                              witnessScript.bytes])])
        let expected = Data([0x00, 0x20]) + Data(SHA256.hash(data: witnessScript.bytes))
        let sources = FundingSources.sources(of: tx)
        #expect(sources.first?.revelation == .witnessScriptHash)
        #expect(sources.first?.scriptPubKey == expected)
        let address = AddressDecoder.address(for: expected, network: .mainnet)
        #expect(address != nil)
        #expect(try AddressDecoder.scriptPubKey(for: address!, network: .mainnet) == expected)
    }

    @Test("A v0 witness script starting with 0x50 is not eaten as an annex")
    func witnessScriptWithAnnexPrefix() {
        let witnessScript = Data([0x50]) + Data(repeating: 0x07, count: 25)
        let tx = Self.transaction([Self.input(witness: [Self.derSignature, witnessScript])])
        let sources = FundingSources.sources(of: tx)
        #expect(sources.first?.revelation == .witnessScriptHash)
        #expect(sources.first?.scriptPubKey == Data([0x00, 0x20]) + Data(SHA256.hash(data: witnessScript)))
    }

    @Test("Taproot key-path: nothing is revealed, with or without an annex")
    func taprootKeyPath() {
        for witness in [[Self.schnorrSignature],
                        [Self.schnorrSignature + Data([0x01])],
                        [Self.schnorrSignature, Data([0x50, 0x01])]] {
            let tx = Self.transaction([Self.input(witness: witness)])
            let sources = FundingSources.sources(of: tx)
            #expect(sources.first?.revelation == .taprootKeyPath)
            #expect(sources.first?.scriptPubKey == nil)
        }
    }

    @Test("Taproot script-path: the output key is recomputed from the control block")
    func taprootScriptPath() throws {
        let leaf = Script.build { script in
            script.appendPush(Self.generator)
            script.appendOpcode(Script.Op.checkSig)
        }
        let internalKey = Taproot.unspendableInternalKey
        // Single-leaf tree: witness = <tapscript> <control block>.
        let single = Taproot.Tree.leaf(script: leaf)
        let control = try Taproot.controlBlock(internalKey: internalKey, tree: single, leafIndex: 0)
        let singleRoot = try Taproot.scriptPubKey(internalKey: internalKey,
                                                  merkleRoot: Taproot.merkleRoot(of: single))
        let tx = Self.transaction([Self.input(witness: [leaf.bytes, control.serialized])])
        let sources = FundingSources.sources(of: tx)
        #expect(sources.first?.revelation == .taprootScriptPath)
        #expect(sources.first?.scriptPubKey == singleRoot)

        // Two-leaf tree with a merkle path, plus a trailing BIP341 annex.
        let other = Script.build { script in
            script.appendOpcode(Script.Op.n(1))
            script.appendOpcode(0xBA) // OP_CHECKSIGADD over a key is irrelevant here
        }
        let tree = Taproot.Tree.branch(.leaf(script: leaf), .leaf(script: other))
        let branchedControl = try Taproot.controlBlock(internalKey: internalKey, tree: tree, leafIndex: 0)
        let branchedRoot = try Taproot.scriptPubKey(internalKey: internalKey,
                                                    merkleRoot: Taproot.merkleRoot(of: tree))
        let annexTx = Self.transaction([Self.input(witness: [leaf.bytes, branchedControl.serialized,
                                                   Data([0x50, 0x99])])])
        let annexSources = FundingSources.sources(of: annexTx)
        #expect(annexSources.first?.revelation == .taprootScriptPath)
        #expect(annexSources.first?.scriptPubKey == branchedRoot)
    }

    @Test("Bare legacy pubkey and multisig spends reveal no address")
    func bareLegacy() {
        let p2pk = Self.transaction([Self.input(scriptSig: Self.scriptSig([Self.derSignature]))])
        #expect(FundingSources.sources(of: p2pk).first?.revelation == .unrecognized)
        let bareMultisig = Self.transaction([Self.input(scriptSig: Self.scriptSig([Data(), Self.derSignature,
                                                                    Self.derSignature]))])
        #expect(FundingSources.sources(of: bareMultisig).first?.revelation == .unrecognized)
        let empty = Self.transaction([Self.input()])
        #expect(FundingSources.sources(of: empty).first?.revelation == .unrecognized)
    }

    @Test("Funding scripts deduplicate repeated inputs in first-seen order")
    func dedup() {
        let otherKey = Data([0x03]) + Data(repeating: 0x09, count: 32)
        let tx = Self.transaction([
            Self.input(witness: [Self.derSignature, Self.generator]),
            Self.input(witness: [Self.derSignature, Self.generator]),
            Self.input(witness: [Self.schnorrSignature]), // reveals nothing
            Self.input(witness: [Self.derSignature, otherKey]),
        ])
        #expect(FundingSources.fundingScripts(of: tx) == [
            Data([0x00, 0x14]) + Self.generatorHash160,
            Data([0x00, 0x14]) + Hash160.hash(otherKey),
        ])
    }

    @Test("History entries from before funding scripts still decode, empty")
    func historyEntryBackwardsCompatibleDecode() throws {
        let legacy = """
            {"txid":"\(String(repeating: "ab", count: 32))","height":12,\
            "received":1000,"spent":0}
            """
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(legacy.utf8))
        #expect(entry.fundingScripts.isEmpty)
        let reencoded = try JSONEncoder().encode(entry)
        #expect(!String(decoding: reencoded, as: UTF8.self).contains("fundingScripts"))
    }
}
