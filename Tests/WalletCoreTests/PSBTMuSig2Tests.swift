import Foundation
import NativeSecp256k1
import Testing
import TestSupport
@testable import WalletCore

/// BIP373 MuSig2 fields and roles on a key-path PSBT: two signers exchange
/// nonces and partial signatures through serialized PSBTs, the aggregate is a
/// BIP340 signature for the Taproot output key, and finalization leaves a
/// plain 64-byte key-path witness.
@Suite("PSBT MuSig2")
struct PSBTMuSig2Tests {
    struct Signer {
        let secret: Data
        let publicKey: Data
    }

    struct Fixture {
        let signers: [Signer]
        let participants: [Data]
        let aggregate: Data
        let internalKey: Data
        let tweaks: [Data]
        let isXOnly: [Bool]
        let signingKey: Data
        var psbt: PSBT

        init() throws {
            signers = try [UInt8(0x31), 0x32].map { byte in
                let account = try TestKeys.master(entropyByte: byte).derived(path: "m/86'/1'/0'")
                let secret = try #require(account.privateKey)
                return Signer(secret: secret, publicKey: account.publicKey)
            }
            participants = MuSig.keySort(signers.map(\.publicKey))
            aggregate = try MuSig.aggregate(participants)
            internalKey = Data(aggregate.dropFirst())
            // Key path only: the TapTweak commits to no script tree.
            tweaks = [Taproot.tweak(internalKey: internalKey, merkleRoot: nil)]
            isXOnly = [true]
            signingKey = try MuSig.aggregate(publicKeys: participants, tweaks: tweaks, isXOnlyTweaks: isXOnly)
            let script = try Taproot.scriptPubKey(internalKey: internalKey)
            let tx = try TransactionBuilder.build(
                inputs: [Transaction.Outpoint(txid: Data(repeating: 0x5A, count: 32), vout: 1)],
                payments: [Payment(amount: 40_000, scriptPubKey: Data([0x51, 0x20] + repeatElement(0x66, count: 32)))],
                change: nil, changePosition: nil)
            psbt = try PSBT(unsignedTx: tx,
                            inputs: [PSBT.InputInfo(spentOutput: .init(amount: 50_000, scriptPubKey: script), key: nil)],
                            outputs: [PSBT.OutputInfo(key: nil)])
            try psbt.attachMuSig2(input: 0, internalKey: internalKey, aggregate: aggregate, participants: participants)
        }

        func sighash(_ psbt: PSBT) throws -> Data {
            try SighashBIP341.sighash(tx: psbt.unsignedTransaction(), inputIndex: 0,
                                      spentOutputs: psbt.spentOutputs(), hashType: .default)
        }

        func id(_ signer: Signer) -> PSBT.MuSig2KeyID {
            PSBT.MuSig2KeyID(participant: signer.publicKey, aggregate: signingKey)
        }
    }

    /// Each signer works on its own decoded copy, as on separate devices.
    static func roundTrip(_ psbt: PSBT) throws -> PSBT {
        try PSBT(base64: psbt.base64V0())
    }

    @Test("participants, nonces and partial signatures survive v0 and v2 encodings")
    func fieldsRoundTrip() throws {
        var fixture = try Fixture()
        let nonce = Data([0x02] + repeatElement(0x11, count: 32) + [0x03] + repeatElement(0x22, count: 32))
        try fixture.psbt.attachMuSig2PubNonce(input: 0, id: fixture.id(fixture.signers[0]), nonce: nonce)
        var partials = fixture.psbt.inputs[0].musig2PartialSigs
        partials[fixture.id(fixture.signers[1])] = Data(repeating: 0x07, count: 32)
        fixture.psbt.inputs[0].musig2PartialSigs = partials
        let v0 = try Self.roundTrip(fixture.psbt)
        let v2 = try PSBT(base64: fixture.psbt.base64)
        for decoded in [v0, v2] {
            #expect(decoded.inputs[0].musig2ParticipantPubKeys == [fixture.aggregate: fixture.participants])
            #expect(decoded.inputs[0].musig2PubNonces == [fixture.id(fixture.signers[0]): nonce])
            #expect(decoded.inputs[0].musig2PartialSigs.count == 1)
            #expect(decoded.inputs[0].tapInternalKey == fixture.internalKey)
        }
        #expect(throws: PSBTError.self) {
            try fixture.psbt.attachMuSig2PubNonce(input: 0, id: fixture.id(fixture.signers[0]), nonce: Data(count: 65))
        }
    }

    @Test("two signers exchange PSBTs and finalize a valid key-path spend")
    func twoOfTwoSpend() throws {
        let fixture = try Fixture()
        let message = try fixture.sighash(fixture.psbt)

        // Round 1 on each device, then combine the two documents.
        var secretNonces: [Data] = []
        var copies: [PSBT] = []
        for signer in fixture.signers {
            var copy = try Self.roundTrip(fixture.psbt)
            let (secretNonce, publicNonce) = try MuSig.nonceGenerate(
                secretKey: signer.secret, publicKey: signer.publicKey,
                aggregateKey: Data(fixture.signingKey.dropFirst()), message: message)
            try copy.attachMuSig2PubNonce(input: 0, id: fixture.id(signer), nonce: publicNonce)
            secretNonces.append(secretNonce)
            copies.append(copy)
        }
        let withNonces = try copies[0].combined(with: [copies[1]])

        // Round 2 on each device from the combined document.
        var signed: [PSBT] = []
        for (index, signer) in fixture.signers.enumerated() {
            var copy = try Self.roundTrip(withNonces)
            let session = try copy.muSig2Session(input: 0, aggregateKey: fixture.aggregate, tweaks: fixture.tweaks,
                                                 isXOnlyTweaks: fixture.isXOnly, message: message)
            try copy.signMuSig2(input: 0, id: fixture.id(signer), secretNonce: &secretNonces[index],
                                secretKey: signer.secret, session: session)
            #expect(secretNonces[index] == Data(count: 97), "the secret nonce is consumed")
            signed.append(copy)
        }
        var final = try signed[0].combined(with: [signed[1]])
        let session = try final.muSig2Session(input: 0, aggregateKey: fixture.aggregate, tweaks: fixture.tweaks,
                                              isXOnlyTweaks: fixture.isXOnly, message: message)
        try final.aggregateMuSig2(input: 0, session: session)
        try final.finalize()

        let witness = try #require(final.inputs[0].finalScriptWitness)
        #expect(witness.count == 1 && witness[0].count == 64)
        #expect(Secp256k1.Schnorr.verify(signature: witness[0], message: message,
                                         publicKey: Data(fixture.signingKey.dropFirst())))
        let outputKey = try Taproot.tweakedOutputKey(internalKey: fixture.internalKey).key
        #expect(outputKey == Data(fixture.signingKey.dropFirst()), "BIP373 signing key is the Taproot output key")
        #expect(final.inputs[0].musig2PubNonces.isEmpty && final.inputs[0].musig2PartialSigs.isEmpty)
        _ = try final.extractedTransaction()
    }

    @Test("aggregation refuses a partial signature from the wrong key")
    func wrongPartialRefused() throws {
        var fixture = try Fixture()
        let message = try fixture.sighash(fixture.psbt)
        var secretNonces: [Data] = []
        for signer in fixture.signers {
            let (secretNonce, publicNonce) = try MuSig.nonceGenerate(
                secretKey: signer.secret, publicKey: signer.publicKey,
                aggregateKey: Data(fixture.signingKey.dropFirst()), message: message)
            try fixture.psbt.attachMuSig2PubNonce(input: 0, id: fixture.id(signer), nonce: publicNonce)
            secretNonces.append(secretNonce)
        }
        let session = try fixture.psbt.muSig2Session(input: 0, aggregateKey: fixture.aggregate,
                                                     tweaks: fixture.tweaks, isXOnlyTweaks: fixture.isXOnly,
                                                     message: message)
        try fixture.psbt.signMuSig2(input: 0, id: fixture.id(fixture.signers[0]), secretNonce: &secretNonces[0],
                                    secretKey: fixture.signers[0].secret, session: session)
        // The second signer's slot gets a partial made with the first signer's nonce slot replayed.
        var partials = fixture.psbt.inputs[0].musig2PartialSigs
        partials[fixture.id(fixture.signers[1])] = partials[fixture.id(fixture.signers[0])]
        fixture.psbt.inputs[0].musig2PartialSigs = partials
        #expect(throws: PSBTError.self) { try fixture.psbt.aggregateMuSig2(input: 0, session: session) }
        #expect(fixture.psbt.inputs[0].tapKeySignature == nil)
    }
}
