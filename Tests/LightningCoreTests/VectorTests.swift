import CryptoKit
import Foundation
import WalletCore
import XCTest
@testable import LightningCore

final class VectorTests: XCTestCase {
    func testAllBOLT3CommitmentAndHTLCVectors() throws {
        let vectors: CommitmentVectors = try loadVectors("bolt3-transactions")
        XCTAssertEqual(vectors.cases.count, 16)
        for vector in vectors.cases {
            let parameters = try vectors.parameters(for: vector)
            let commitment = try ChannelTransactions.commitment(parameters)
            let expected = try Transaction.decode(hex(vector.commit_tx))
            XCTAssertEqual(commitment.transaction.serialized(includeWitness: false),
                           expected.serialized(includeWitness: false), vector.name)
            let digest = try ChannelTransactions.fundingDigest(commitment)
            let signature = try ChannelKeys.sign(digest: digest, secret: hex(String(vectors.parameters["local_funding_privkey"]!.prefix(64))))
            XCTAssertEqual(signature.hex, vector.local_signature, vector.name)
            let signed = try ChannelTransactions.signed(commitment,
                localSignature: signature, remoteSignature: hex(vector.remote_signature))
            XCTAssertEqual(signed.serialized(includeWitness: true).hex, vector.commit_tx, vector.name)
            XCTAssertEqual(commitment.htlcOutputs.count, vector.num_htlcs, vector.name)
            for stage in vector.second_stage {
                let output = try XCTUnwrap(commitment.htlcOutputs.first { $0.htlc.id == stage.id })
                let actual = try ChannelTransactions.htlcTransaction(commitment: commitment, output: output)
                let expectedStage = try Transaction.decode(hex(stage.transaction))
                XCTAssertEqual(actual.serialized(includeWitness: false), expectedStage.serialized(includeWitness: false), vector.name)
                XCTAssertEqual(output.witnessScript.bytes, expectedStage.inputs[0].witness.last)
                let stageDigest = try SighashBIP143.sighash(tx: actual, inputIndex: 0, scriptCode: output.witnessScript.bytes,
                                                         value: Int64(output.htlc.amountMsat / 1000))
                let stageSig = try ChannelKeys.sign(digest: stageDigest, secret: hex(String(vectors.parameters["local_privkey"]!.prefix(64))))
                XCTAssertEqual(stageSig + Data([1]), expectedStage.inputs[0].witness[2], vector.name)
                XCTAssertTrue(ChannelKeys.verify(signature: Data(expectedStage.inputs[0].witness[1].dropLast()),
                                                digest: stageDigest, publicKey: parameters.keys.htlcRemote))
                let preimage = try output.htlc.offered ? nil : hex(XCTUnwrap(vectors.htlcs.first { $0.id == stage.id }).preimage)
                let signedStage = try ChannelRecovery.signedHTLC(commitment: commitment, output: output,
                    localSignature: stageSig,
                    remoteSignature: Data(expectedStage.inputs[0].witness[1].dropLast()), preimage: preimage)
                XCTAssertEqual(signedStage.serialized(includeWitness: true).hex, stage.transaction, vector.name)
            }
        }
    }

    func testBOLT3SecretGenerationVectors() throws {
        struct Vector: Decodable { let seed: String; let index: UInt64; let secret: String }
        let vectors: [Vector] = try loadVectors("bolt3-secrets")
        XCTAssertEqual(vectors.count, 5)
        for vector in vectors {
            XCTAssertEqual(try ChannelKeys.commitmentSecret(seed: hex(vector.seed),
                number: ChannelKeys.maximumCommitmentNumber - vector.index).hex, vector.secret)
        }
        XCTAssertThrowsError(try ChannelKeys.commitmentSecret(seed: Data(), number: 0))
        XCTAssertThrowsError(try ChannelKeys.commitmentSecret(seed: Data(repeating: 0, count: 32), number: 1 << 48))
    }

    func testBOLT8PublishedHandshakeVectors() throws {
        struct Vector: Decodable {
            struct Step: Decodable { let kind: String; let value: String }
            let name: String; let fields: [String: String]; let steps: [Step]
        }
        let vectors: [Vector] = try loadVectors("bolt8-handshakes")
        XCTAssertEqual(vectors.count, 15)
        for vector in vectors {
            let initiator = vector.name.hasPrefix("transport-initiator")
            let handshake = try LightningHandshake(role: initiator ? .initiator : .responder,
                localSecret: hex(vector.fields["ls.priv"]!),
                remotePublicKey: initiator ? hex(vector.fields["rs.pub"]!) : nil,
                ephemeral: hex(vector.fields["e.priv"]!))
            var reply: Data? = initiator ? try handshake.start() : nil
            var failure: Error?
            for step in vector.steps {
                if step.kind == "input" {
                    do { reply = try handshake.receive(hex(String(step.value.dropFirst(2)))).reply }
                    catch { failure = error }
                } else if step.value.hasPrefix("ERROR") {
                    XCTAssertNotNil(failure, vector.name)
                    XCTAssertThrowsError(try handshake.receive(Data()), vector.name)
                } else if step.value.hasPrefix("0x") {
                    XCTAssertNil(failure, vector.name)
                    XCTAssertEqual(reply?.hex, String(step.value.dropFirst(2)), vector.name)
                }
            }
        }
    }

    func testBOLT8PublishedMessageRotationVectors() throws {
        struct Vector: Decodable { let index: Int; let ciphertext: String }
        let vectors: [Vector] = try loadVectors("bolt8-messages")
        XCTAssertEqual(vectors.count, 6)
        let (sender, receiver) = try transportPair()
        let expected = Dictionary(uniqueKeysWithValues: vectors.map { ($0.index, $0.ciphertext) })
        for index in 0...1001 {
            let frame = try sender.encrypt(Data("hello".utf8))
            if let vector = expected[index] { XCTAssertEqual(frame.hex, vector) }
            XCTAssertEqual(try receiver.receive(frame), [Data("hello".utf8)])
        }
    }

    func testTransportFragmentationAndAuthenticationFailure() throws {
        let (sender, receiver) = try transportPair()
        let messages = [Data(), Data([1, 2]), Data(repeating: 7, count: 65535)]
        var result: [Data] = []
        for message in messages {
            for byte in try sender.encrypt(message) { result += try receiver.receive(Data([byte])) }
        }
        XCTAssertEqual(result, messages)
        XCTAssertThrowsError(try sender.encrypt(Data(repeating: 0, count: 65536)))
        var bad = try sender.encrypt(Data([9]))
        bad[bad.index(before: bad.endIndex)] ^= 1
        XCTAssertThrowsError(try receiver.receive(bad))
        XCTAssertTrue(receiver.isClosed)
        XCTAssertThrowsError(try receiver.encrypt(Data()))
        XCTAssertThrowsError(try receiver.receive(Data()))
    }

    func testTwoFreshPeersAuthenticateBothIdentities() throws {
        let local = Data(repeating: 1, count: 32), remote = Data(repeating: 2, count: 32)
        let sender = try LightningHandshake(role: .initiator, localSecret: local,
                                           remotePublicKey: ChannelKeys.publicKey(secret: remote))
        let receiver = try LightningHandshake(role: .responder, localSecret: remote)
        let two = try XCTUnwrap(receiver.receive(sender.start()).reply)
        let result = try sender.receive(two)
        let first = try XCTUnwrap(result.transport)
        let second = try XCTUnwrap(receiver.receive(XCTUnwrap(result.reply)).transport)
        XCTAssertEqual(first.remotePublicKey, try ChannelKeys.publicKey(secret: remote))
        XCTAssertEqual(second.remotePublicKey, try ChannelKeys.publicKey(secret: local))
        XCTAssertEqual(try second.receive(first.encrypt(Data([1, 2, 3]))), [Data([1, 2, 3])])
        XCTAssertEqual(try first.receive(second.encrypt(Data([4]))), [Data([4])])
        XCTAssertThrowsError(try sender.receive(two))
    }

    func testCoalescedFramesAndHeaderAuthentication() throws {
        let (sender, receiver) = try transportPair()
        let messages = [Data([1]), Data(repeating: 2, count: 1024), Data()]
        let wire = try messages.reduce(into: Data()) { $0.append(try sender.encrypt($1)) }
        let padded = Data([0xff]) + wire
        XCTAssertEqual(try receiver.receive(padded.dropFirst()), messages)
        var tampered = try sender.encrypt(Data([3]))
        tampered[tampered.startIndex] ^= 1
        XCTAssertThrowsError(try receiver.receive(tampered))
        XCTAssertTrue(receiver.isClosed)
    }

    func transportPair() throws -> (LightningTransport, LightningTransport) {
        let chain = try hex("919219dbb2920afa8db80f9a51787a840bcf111ed8d588caf9ab4be716e42b01")
        let send = try hex("969ab31b4d288cedf6218839b27a3e2140827047f2c0f01bf5c04435d43511a9")
        let receive = try hex("bb9020b8965f4df047e07f955f3c4b88418984aadc5cdb35096b9ea8fa5c3442")
        return (LightningTransport(remotePublicKey: Data(), chainingKey: chain, sendKey: send, receiveKey: receive),
                LightningTransport(remotePublicKey: Data(), chainingKey: chain, sendKey: receive, receiveKey: send))
    }
}

func hex(_ string: String) throws -> Data { try XCTUnwrap(Data(hex: string)) }
func loadVectors<T: Decodable>(_ name: String) throws -> T {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Vectors"))
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

struct CommitmentVectors: Decodable {
    struct HTLC: Decodable { let id: UInt64; let offered: Bool; let amount_msat: UInt64; let expiry: UInt32; let preimage: String }
    struct Case: Decodable {
        struct Stage: Decodable { let id: UInt64; let transaction: String }
        let name: String; let to_local_msat: UInt64; let to_remote_msat: UInt64; let local_feerate_per_kw: UInt32
        let local_signature: String; let remote_signature: String; let commit_tx: String
        let num_htlcs: Int; let htlc_ids: [UInt64]; let second_stage: [Stage]
    }
    let parameters: [String: String]; let htlcs: [HTLC]; let cases: [Case]
    func parameters(for vector: Case) throws -> ChannelTransactions.Parameters {
        func key(_ name: String) throws -> Data { try hex(XCTUnwrap(parameters[name])) }
        let keys = try ChannelTransactions.Keys(fundingLocal: key("local_funding_pubkey"), fundingRemote: key("remote_funding_pubkey"),
            revocation: key("local_revocation_pubkey"), delayedLocal: key("local_delayedpubkey"), paymentRemote: key("remote_payment_basepoint"),
            htlcLocal: key("local_htlcpubkey"), htlcRemote: key("remote_htlcpubkey"))
        let selected = try htlcs.filter { vector.htlc_ids.contains($0.id) }.map {
            ChannelTransactions.HTLC(id: $0.id, offered: $0.offered, amountMsat: $0.amount_msat,
                paymentHash: ChannelKeys.hash(try hex($0.preimage)), expiry: $0.expiry)
        }
        return try ChannelTransactions.Parameters(funding: .init(txid: Data(key("funding_tx_id").reversed()), vout: 0),
            fundingSat: 10_000_000, localMsat: vector.to_local_msat, remoteMsat: vector.to_remote_msat,
            localIsFunder: true, dustSat: 546, feePerKW: vector.local_feerate_per_kw, delay: 144, number: 42,
            openerPaymentBasepoint: key("local_payment_basepoint"), accepterPaymentBasepoint: key("remote_payment_basepoint"), keys: keys, htlcs: selected)
    }
}
