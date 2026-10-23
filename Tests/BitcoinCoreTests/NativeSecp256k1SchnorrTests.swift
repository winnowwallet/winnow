import Foundation
import NativeSecp256k1
import Testing
import TestSupport
@testable import WalletCore

/// BIP340 signing and verification in the native module: the official
/// vectors, the BIP341 key-path spending vectors end to end, and byte-level
/// agreement with recorded libsecp256k1 signatures and verdicts on derived
/// inputs and mutated signatures (see Vectors/native-secp256k1/README.md).
@Suite("Native secp256k1 Schnorr")
struct NativeSecp256k1SchnorrTests {
    struct Row {
        let index: Int
        let secretKey: Data?
        let publicKey: Data
        let auxiliaryRand: Data?
        let message: Data
        let signature: Data
        let valid: Bool
        let comment: String
    }

    struct SignatureVector: Decodable {
        let name: String
        let secret: String
        let message: String
        let auxiliaryRand: String
        let signature: String
    }

    struct VerificationVector: Decodable {
        let name: String
        let signature: String
        let message: String
        let publicKey: String
        let valid: Bool
    }

    static func hexOrEmpty(_ hex: String) throws -> Data {
        hex.isEmpty ? Data() : try #require(Data(hex: hex), "hex \(hex)")
    }

    static func fixture<T: Decodable>(_ name: String) throws -> T {
        try Vectors.decode(T.self, name + ".json", in: .module, subdirectory: "Vectors/native-secp256k1")
    }

    /// The 19 rows of bip340-test-vectors.csv.
    static func rows() throws -> [Row] {
        let text = try Vectors.string("bip340-test-vectors.csv", in: .module)
        // The upstream file has CRLF line endings; "\r\n" is one Character in Swift.
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        #expect(lines.first == "index,secret key,public key,aux_rand,message,signature,verification result,comment")
        var rows: [Row] = []
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            try #require(fields.count >= 7, "row \(line)")
            rows.append(Row(index: Int(fields[0]) ?? -1,
                            secretKey: fields[1].isEmpty ? nil : try hexOrEmpty(fields[1]),
                            publicKey: try hexOrEmpty(fields[2]),
                            auxiliaryRand: fields[3].isEmpty ? nil : try hexOrEmpty(fields[3]),
                            message: try hexOrEmpty(fields[4]),
                            signature: try hexOrEmpty(fields[5]),
                            valid: fields[6] == "TRUE",
                            comment: fields.dropFirst(7).joined(separator: ",")))
        }
        return rows
    }

    // MARK: - Official vectors

    @Test("every BIP340 vector signs to the expected bytes and verifies as the CSV says")
    func bip340Vectors() throws {
        let rows = try Self.rows()
        #expect(rows.count == 19)
        var signed = 0
        for row in rows {
            if let secret = row.secretKey, let aux = row.auxiliaryRand {
                let key = try Secp256k1.PrivateKey(secret)
                #expect(key.xOnlyKey.x == row.publicKey, "public key of vector \(row.index)")
                let signature = try Secp256k1.Schnorr.sign(message: row.message, privateKey: key, auxiliaryRand: aux)
                #expect(signature == row.signature, "signature of vector \(row.index)")
                signed += 1
            }
            let verified = Secp256k1.Schnorr.verify(signature: row.signature, message: row.message,
                                                     publicKey: row.publicKey)
            #expect(verified == row.valid, "vector \(row.index): \(row.comment)")
        }
        #expect(signed == 8)
    }

    @Test("BIP341 key-path spending vectors: tweak, sign and verify natively")
    func bip341KeyPathSpending() throws {
        let root = try Vectors.json("bip341-wallet-test-vectors.json", in: .module) as! [String: Any]
        let spending = (root["keyPathSpending"] as! [[String: Any]])[0]
        let inputs = spending["inputSpending"] as! [[String: Any]]
        #expect(inputs.count == 7)
        for input in inputs {
            let given = input["given"] as! [String: Any]
            let intermediary = input["intermediary"] as! [String: Any]
            let expected = input["expected"] as! [String: Any]
            let key = try Secp256k1.PrivateKey(try Self.hexOrEmpty(given["internalPrivkey"] as! String))
            let merkleRoot = try Self.hexOrEmpty(given["merkleRoot"] as? String ?? "")
            let hashType = given["hashType"] as! Int
            #expect(key.xOnlyKey.x == (try Self.hexOrEmpty(intermediary["internalPubkey"] as! String)))

            let tweak = TaggedSHA256.hash(tag: "TapTweak", message: key.xOnlyKey.x + merkleRoot)
            #expect(tweak == (try Self.hexOrEmpty(intermediary["tweak"] as! String)))
            let tweakedKey = try key.addingXOnly(tweak)
            #expect(tweakedKey.bytes == (try Self.hexOrEmpty(intermediary["tweakedPrivkey"] as! String)))

            let sigHash = try Self.hexOrEmpty(intermediary["sigHash"] as! String)
            let witness = try Self.hexOrEmpty((expected["witness"] as! [String])[0])
            #expect(witness.count == (hashType == 0 ? 64 : 65))
            let signature = try Secp256k1.Schnorr.sign(message: sigHash, privateKey: tweakedKey,
                                                       auxiliaryRand: Data(repeating: 0, count: 32))
            #expect(signature == witness.prefix(64), "txin \(given["txinIndex"] ?? -1)")
            let outputKey = try key.xOnlyKey.adding(tweak)
            #expect(Secp256k1.Schnorr.verify(signature: signature, message: sigHash, publicKey: outputKey.x))
            #expect(outputKey.x == tweakedKey.xOnlyKey.x)
        }
    }

    // MARK: - Recorded libsecp256k1 answers

    @Test("signatures are byte-identical to libsecp256k1 for fixed and derived auxiliary input")
    func recordedSignatures() throws {
        let vectors: [SignatureVector] = try Self.fixture("schnorr-signatures")
        #expect(vectors.count == 12)
        var lengths: Set<Int> = []
        var zeroAux = 0
        for vector in vectors {
            let key = try Secp256k1.PrivateKey(try Self.hexOrEmpty(vector.secret))
            let message = try Self.hexOrEmpty(vector.message)
            let aux = try Self.hexOrEmpty(vector.auxiliaryRand)
            lengths.insert(message.count)
            if aux == Data(repeating: 0, count: 32) { zeroAux += 1 }
            let native = try Secp256k1.Schnorr.sign(message: message, privateKey: key, auxiliaryRand: aux)
            #expect(native.hex == vector.signature, "\(vector.name)")
            #expect(Secp256k1.Schnorr.verify(signature: native, message: message, publicKey: key.xOnlyKey.x), "\(vector.name)")
        }
        // Empty, one-byte, 17-byte, 32-byte and 100-byte messages; half the cases use zero auxiliary input.
        #expect(lengths == [0, 1, 17, 32, 100])
        #expect(zeroAux == 6)
        #expect(throws: Secp256k1Error.invalidAuxiliaryRand) {
            try Secp256k1.Schnorr.sign(message: Data(), privateKey: try Secp256k1.PrivateKey(Data(repeating: 7, count: 32)),
                                       auxiliaryRand: Data(repeating: 0, count: 31))
        }
    }

    @Test("verification agrees with libsecp256k1 on valid, mutated and malformed signatures")
    func recordedVerification() throws {
        let vectors: [VerificationVector] = try Self.fixture("schnorr-verification")
        #expect(vectors.count == 102)
        var valid = 0
        var kinds: Set<String> = []
        for vector in vectors {
            let verdict = Secp256k1.Schnorr.verify(signature: try Self.hexOrEmpty(vector.signature),
                                                   message: try Self.hexOrEmpty(vector.message),
                                                   publicKey: try Self.hexOrEmpty(vector.publicKey))
            #expect(verdict == vector.valid, "\(vector.name)")
            if vector.valid { valid += 1 }
            kinds.insert(vector.name.split(separator: "-").dropFirst(2).joined(separator: "-"))
        }
        // Six signatures, one per message length, each with sixteen mutations: flipped signature bits, message and key,
        // r = p, s = n, swapped halves, wrong lengths, another key, a short key and a longer message.
        // Flipping a byte of an empty message leaves it valid, which is the one extra valid row.
        #expect(valid == 6 + 1)
        #expect(kinds == ["valid", "signature-bit-0", "signature-bit-17", "signature-bit-31", "signature-bit-32",
                          "signature-bit-50", "signature-bit-63", "message-flipped", "key-flipped", "r-is-prime",
                          "s-is-order", "halves-swapped", "signature-63", "signature-65", "other-key", "key-31",
                          "message-extended"])
    }
}
