import Foundation
import NativeSecp256k1
import P256K
import Testing
import TestSupport
@testable import WalletCore

/// BIP340 signing and verification in the native module: the official
/// vectors, the BIP341 key-path spending vectors end to end, and byte-level
/// agreement with libsecp256k1 on random inputs and mutated signatures.
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

    static func hexOrEmpty(_ hex: String) throws -> Data {
        hex.isEmpty ? Data() : try #require(Data(hex: hex), "hex \(hex)")
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

    static func random(_ count: Int, _ rng: inout SeededRandom) -> Data {
        Data((0 ..< count).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
    }

    static func referenceSignature(secret: Data, message: Data, aux: Data) throws -> Data {
        var messageBytes = [UInt8](message)
        var auxBytes = [UInt8](aux)
        return try P256K.Schnorr.PrivateKey(dataRepresentation: secret)
            .signature(message: &messageBytes, auxiliaryRand: &auxBytes).dataRepresentation
    }

    static func referenceVerify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard let parsed = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: signature) else { return false }
        var messageBytes = [UInt8](message)
        return P256K.Schnorr.XonlyKey(dataRepresentation: publicKey).isValid(parsed, for: &messageBytes)
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

    // MARK: - Differential

    @Test("signatures are byte-identical to libsecp256k1 for fixed and random auxiliary input")
    func signaturesMatchReference() throws {
        var rng = SeededRandom(state: 0x5160)
        for iteration in 0 ..< 96 {
            let secret = Self.random(32, &rng)
            let key = try Secp256k1.PrivateKey(secret)
            let lengths = [32, 32, 0, 1, 17, 100]
            let message = Self.random(lengths[iteration % lengths.count], &rng)
            let aux = iteration % 2 == 0 ? Data(repeating: 0, count: 32) : Self.random(32, &rng)
            let native = try Secp256k1.Schnorr.sign(message: message, privateKey: key, auxiliaryRand: aux)
            let reference = try Self.referenceSignature(secret: secret, message: message, aux: aux)
            #expect(native == reference, "iteration \(iteration)")
            #expect(Self.referenceVerify(signature: native, message: message, publicKey: key.xOnlyKey.x))
            #expect(Secp256k1.Schnorr.verify(signature: native, message: message, publicKey: key.xOnlyKey.x))
        }
        #expect(throws: Secp256k1Error.invalidAuxiliaryRand) {
            try Secp256k1.Schnorr.sign(message: Data(), privateKey: try Secp256k1.PrivateKey(Self.random(32, &rng)),
                                       auxiliaryRand: Data(repeating: 0, count: 31))
        }
    }

    @Test("verification agrees with libsecp256k1 on valid, mutated and malformed signatures")
    func verificationMatchesReference() throws {
        var rng = SeededRandom(state: 0x7E51)
        let orderBytes = try Self.hexOrEmpty("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")
        let primeBytes = try Self.hexOrEmpty("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f")
        var agreedInvalid = 0
        let lengths = [32, 32, 0, 1, 17, 100]
        for iteration in 0 ..< 48 {
            let secret = Self.random(32, &rng)
            let key = try Secp256k1.PrivateKey(secret)
            let message = Self.random(lengths[iteration % lengths.count], &rng)
            let publicKey = key.xOnlyKey.x
            let signature = try Secp256k1.Schnorr.sign(message: message, privateKey: key,
                                                       auxiliaryRand: Self.random(32, &rng))
            var candidates: [(Data, Data, Data)] = [(signature, message, publicKey)]
            // One flipped bit in each component.
            for byte in [0, 17, 31, 32, 50, 63] {
                var mutated = signature
                mutated[byte] ^= UInt8(1 << (iteration % 8))
                candidates.append((mutated, message, publicKey))
            }
            var flippedMessage = message
            if !flippedMessage.isEmpty { flippedMessage[iteration % flippedMessage.count] ^= 0x80 }
            candidates.append((signature, flippedMessage, publicKey))
            var flippedKey = publicKey
            flippedKey[iteration % 32] ^= 0x01
            candidates.append((signature, message, flippedKey))
            // Out-of-range r and s, swapped halves, wrong lengths, other key.
            candidates.append((primeBytes + signature.suffix(32), message, publicKey))
            candidates.append((signature.prefix(32) + orderBytes, message, publicKey))
            candidates.append((signature.suffix(32) + signature.prefix(32), message, publicKey))
            candidates.append((signature.prefix(63), message, publicKey))
            candidates.append((signature + Data([0]), message, publicKey))
            candidates.append((signature, message, Self.random(32, &rng)))
            candidates.append((signature, message, Data(repeating: 0, count: 31)))
            candidates.append((signature, message + Data([0]), publicKey))
            for (candidate, candidateMessage, candidateKey) in candidates {
                let native = Secp256k1.Schnorr.verify(signature: candidate, message: candidateMessage,
                                                       publicKey: candidateKey)
                let reference = Self.referenceVerify(signature: candidate, message: candidateMessage,
                                                     publicKey: candidateKey)
                #expect(native == reference, "iteration \(iteration) \(candidate.hex)")
                if !native { agreedInvalid += 1 }
            }
        }
        #expect(agreedInvalid > 600)
    }
}
