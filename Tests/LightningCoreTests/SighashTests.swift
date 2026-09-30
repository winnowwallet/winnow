import Foundation
import WalletCore
import XCTest
@testable import LightningCore

final class SighashTests: XCTestCase {
    func testPublishedBIP143Digests() throws {
        struct Vector: Decodable {
            let transaction: String; let input: Int; let script_code: String
            let value: Int64; let hash_type: UInt32; let digest: String
        }
        let vectors: [Vector] = try loadVectors("bip143")
        XCTAssertEqual(vectors.count, 9)
        XCTAssertEqual(Set(vectors.map(\.hash_type)), Set(SighashBIP143.HashType.allCases.map(\.rawValue)))
        for vector in vectors {
            let digest = try SighashBIP143.sighash(tx: Transaction.decode(hex(vector.transaction)), inputIndex: vector.input,
                scriptCode: hex(vector.script_code), value: vector.value, hashType: XCTUnwrap(.init(rawValue: vector.hash_type)))
            XCTAssertEqual(digest.hex, vector.digest)
        }
    }

    func testAmountsAndSignaturesCannotBeSubstituted() throws {
        let vectors: CommitmentVectors = try loadVectors("bolt3-transactions")
        let parameters = try vectors.parameters(for: vectors.cases[0])
        let commitment = try ChannelTransactions.commitment(parameters)
        let digest = try ChannelTransactions.fundingDigest(commitment)
        let signature = try hex(vectors.cases[0].local_signature)
        XCTAssertTrue(ChannelKeys.verify(signature: signature, digest: digest, publicKey: parameters.keys.fundingLocal))
        let wrongAmount = try SighashBIP143.sighash(tx: commitment.transaction, inputIndex: 0,
            scriptCode: commitment.fundingScript.bytes, value: Int64(parameters.fundingSat - 1))
        XCTAssertFalse(ChannelKeys.verify(signature: signature, digest: wrongAmount, publicKey: parameters.keys.fundingLocal))
        XCTAssertFalse(ChannelKeys.verify(signature: signature, digest: Data(), publicKey: parameters.keys.fundingLocal))
        // BOLT 2 requires LOW_S. This is the same valid (r, n-s) pair as the
        // published signature, deliberately changed to the forbidden high-S form.
        let highS = try hex("30450220616210b2cc4d3afb601013c373bbd8aac54febd9f15400379a8cb65ce7deca60022100cbdc93fef66e41480088faefa9e5172232534fadddb42df2fc4333ac7ad1cfff")
        XCTAssertFalse(ChannelKeys.verify(signature: highS, digest: digest, publicKey: parameters.keys.fundingLocal))
        XCTAssertFalse(ChannelKeys.verify(signature: signature + Data([0]), digest: digest, publicKey: parameters.keys.fundingLocal))
        XCTAssertThrowsError(try ChannelTransactions.signed(commitment, localSignature: signature, remoteSignature: signature))
    }

    func testHTLCResolutionRejectsWrongPreimagesAndSignatures() throws {
        let vectors: CommitmentVectors = try loadVectors("bolt3-transactions")
        let vector = try XCTUnwrap(vectors.cases.first { $0.second_stage.count > 1 })
        let commitment = try ChannelTransactions.commitment(vectors.parameters(for: vector))
        for stage in vector.second_stage {
            let output = try XCTUnwrap(commitment.htlcOutputs.first { $0.htlc.id == stage.id })
            let signed = try Transaction.decode(hex(stage.transaction))
            let local = Data(signed.inputs[0].witness[2].dropLast())
            let remote = Data(signed.inputs[0].witness[1].dropLast())
            XCTAssertThrowsError(try ChannelRecovery.signedHTLC(commitment: commitment, output: output,
                localSignature: local, remoteSignature: remote, preimage: Data(repeating: 42, count: 32)))
            let preimage = output.htlc.offered ? nil : signed.inputs[0].witness[3]
            XCTAssertThrowsError(try ChannelRecovery.signedHTLC(commitment: commitment, output: output,
                localSignature: remote, remoteSignature: local, preimage: preimage))
        }
    }

    func testInvalidSighashInputsRejectWithoutTrapping() throws {
        let tx = Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: Data(repeating: 0, count: 32), vout: 0),
            scriptSig: Data(), sequence: 0)], outputs: [], locktime: 0)
        XCTAssertThrowsError(try SighashBIP143.sighash(tx: tx, inputIndex: -1, scriptCode: Data(), value: 1))
        XCTAssertThrowsError(try SighashBIP143.sighash(tx: tx, inputIndex: 1, scriptCode: Data(), value: 1))
        XCTAssertThrowsError(try SighashBIP143.sighash(tx: tx, inputIndex: 0, scriptCode: Data(), value: -1))
        XCTAssertThrowsError(try SighashBIP143.sighash(tx: tx, inputIndex: 0, scriptCode: Data(), value: Int64.max))
        var malformed = tx
        malformed.inputs[0].previousOutput.txid = Data([1])
        XCTAssertThrowsError(try SighashBIP143.sighash(tx: malformed, inputIndex: 0, scriptCode: Data(), value: 1))
        let single = try SighashBIP143.sighash(tx: tx, inputIndex: 0, scriptCode: Data(), value: 1, hashType: .single)
        XCTAssertEqual(single.count, 32)
        XCTAssertNotEqual(single, Data([1]) + Data(repeating: 0, count: 31))
    }

    func testBOLT3KeyDerivations() throws {
        let base = Data(0...31), commitment = Data((0...31).reversed())
        let basepoint = try ChannelKeys.publicKey(secret: base)
        let point = try ChannelKeys.publicKey(secret: commitment)
        XCTAssertEqual(try ChannelKeys.derivedPublicKey(basepoint: basepoint, commitmentPoint: point).hex,
                       "0235f2dbfaa89b57ec7b055afe29849ef7ddfeb1cefdb9ebdc43f5494984db29e5")
        XCTAssertEqual(try ChannelKeys.derivedPrivateKey(baseSecret: base, commitmentPoint: point).hex,
                       "cbced912d3b21bf196a766651e436aff192362621ce317704ea2f75d87e7be0f")
        XCTAssertEqual(try ChannelKeys.revocationPublicKey(basepoint: basepoint, commitmentPoint: point).hex,
                       "02916e326636d19c33f13e8c0c3a03dd157f332f3e99c317c141dd865eb01f8ff0")
        XCTAssertEqual(try ChannelKeys.revocationPrivateKey(baseSecret: base, commitmentSecret: commitment).hex,
                       "d09ffff62ddb2297ab000cc85bcb4283fdeb6aa052affbc9dddcf33b61078110")
        XCTAssertThrowsError(try ChannelKeys.publicKey(secret: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try ChannelKeys.derivedPublicKey(basepoint: Data(), commitmentPoint: point))
    }
}
