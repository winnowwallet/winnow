import Foundation
import P256K
import Testing
import WinnowPrimitives

/// WinnowPrimitives on its own: this target links neither WalletCore nor
/// TestSupport, so anything here that compiles and passes proves a caller can
/// derive, build and sign a Bitcoin send without the wallet actor or the
/// network. The derivation answers are BIP86's published vectors
/// (bip-0086.mediawiki, the "abandon … about" mnemonic).
@Suite("WinnowPrimitives alone")
struct StandaloneSendTests {
    static let mnemonic = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"

    static func account() throws -> HDKey {
        try BIP86.accountKey(from: HDKey(seed: BIP39.seed(mnemonic: mnemonic)))
    }

    static func internalKey(_ account: HDKey, chain: UInt32, index: UInt32) throws -> Data {
        BIP86.xonlyPublicKey(of: try account.child(at: chain).child(at: index))
    }

    @Test("BIP86 receive and change addresses match the published vectors")
    func derivesTheBIP86Vectors() throws {
        let account = try Self.account()
        #expect(try BIP86.address(internalKey: Self.internalKey(account, chain: 0, index: 0))
            == "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr")
        #expect(try BIP86.address(internalKey: Self.internalKey(account, chain: 0, index: 1))
            == "bc1p4qhjn9zdvkux4e44uhx8tc55attvtyu358kutcqkudyccelu0was9fqzwh")
        #expect(try BIP86.address(internalKey: Self.internalKey(account, chain: 1, index: 0))
            == "bc1p3qkhfews2uk44qtvauqyr2ttdsw7svhkl9nkm9s9c3x4ax5h60wqwruhk7")
    }

    @Test("select, build and sign a key-path send whose witness verifies")
    func buildsAndSignsASend() throws {
        let account = try Self.account()
        let receive = try account.child(at: 0).child(at: 0)
        let funding = try BIP86.scriptPubKey(internalKey: BIP86.xonlyPublicKey(of: receive))
        let change = try BIP86.scriptPubKey(internalKey: Self.internalKey(account, chain: 1, index: 0))
        let coin = WalletUTXO(txid: Data(repeating: 0x01, count: 32), vout: 0, amount: 100_000,
                              scriptPubKey: funding, chain: .receive, index: 0, height: 900_000)
        let payment = try Payment(amount: 40_000,
                                  address: "bc1p4qhjn9zdvkux4e44uhx8tc55attvtyu358kutcqkudyccelu0was9fqzwh",
                                  network: .mainnet)

        let selection = try CoinSelection.select(utxos: [coin], payments: [payment],
                                                 changeScriptPubKey: change, feeRateSatPerVByte: 2)
        let changeAmount = try #require(selection.changeAmount)
        #expect(40_000 + changeAmount + selection.fee == 100_000)

        var tx = try TransactionBuilder.build(inputs: selection.selected.map(\.outpoint),
                                              payments: [payment],
                                              change: Payment(amount: changeAmount, scriptPubKey: change))
        let spent = selection.selected.map(\.spentOutput)
        let tweaked = try BIP86.tweakedPrivateKey(#require(receive.privateKey))
        try Signer.sign(tx: &tx, spentOutputs: spent) { $0 == funding ? tweaked : nil }

        let witness = try #require(tx.inputs.first?.witness.first)
        #expect(witness.count == 64)
        var message = [UInt8](try SighashBIP341.sighash(tx: tx, inputIndex: 0, spentOutputs: spent))
        let outputKey = P256K.Schnorr.XonlyKey(dataRepresentation: funding.suffix(32))
        #expect(outputKey.isValid(try P256K.Schnorr.SchnorrSignature(dataRepresentation: witness),
                                  for: &message))
        #expect(TransactionBuilder.vsize(of: tx) <= TransactionBuilder.signedVSize(
            inputCount: 1, outputs: tx.outputs))
    }
}
