import Foundation
import Testing
@testable import WinnowFuzzCore

/// The fuzz target's second secp256k1 is only a useful judge if it is right,
/// so it has to reproduce BIP340's own vectors before it is trusted to
/// disagree with the native module.
@Suite("Reference secp256k1")
struct ReferenceSecp256k1Tests {
    struct Vector {
        let index: Int
        let secret: Data?
        let publicKey: Data
        let auxiliaryRand: Data?
        let message: Data
        let signature: Data
        let valid: Bool
    }

    static let vectors: [Vector] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BitcoinCoreTests/Vectors/bip340-test-vectors.csv")
        // The file has CRLF line endings, and "\r\n" is one Character in Swift.
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.split(whereSeparator: \.isNewline).dropFirst() ?? []
        return lines.map { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            func bytes(_ hex: String) -> Data { ReferenceSecp256k1.Number.hexBytes(hex) }
            return Vector(index: Int(fields[0])!, secret: fields[1].isEmpty ? nil : bytes(fields[1]),
                          publicKey: bytes(fields[2]), auxiliaryRand: fields[3].isEmpty ? nil : bytes(fields[3]),
                          message: bytes(fields[4]), signature: bytes(fields[5]), valid: fields[6] == "TRUE")
        }
    }()

    @Test("the vectors file loads")
    func loads() {
        #expect(Self.vectors.count >= 15)
    }

    @Test("verification matches every BIP340 vector")
    func verification() {
        for vector in Self.vectors {
            let verdict = ReferenceSecp256k1.verify(signature: vector.signature, message: vector.message,
                                                    publicKey: vector.publicKey)
            #expect(verdict == vector.valid, "vector \(vector.index)")
        }
    }

    @Test("keys and signatures match every BIP340 signing vector")
    func signing() throws {
        for vector in Self.vectors {
            guard let secretBytes = vector.secret, let aux = vector.auxiliaryRand else { continue }
            let secret = try #require(ReferenceSecp256k1.secret(secretBytes), "vector \(vector.index)")
            #expect(ReferenceSecp256k1.publicKey(secret).x.bigEndian32 == vector.publicKey, "vector \(vector.index)")
            #expect(ReferenceSecp256k1.sign(message: vector.message, secret: secret, auxiliaryRand: aux)
                == vector.signature, "vector \(vector.index)")
        }
    }

    @Test("small multiples of G and the group order")
    func smallMultiples() {
        let g = ReferenceSecp256k1.generator
        #expect(ReferenceSecp256k1.multiply(g, .one) == g)
        #expect(ReferenceSecp256k1.multiply(g, ReferenceSecp256k1.Number(2)) == ReferenceSecp256k1.add(g, g))
        #expect(ReferenceSecp256k1.multiply(g, ReferenceSecp256k1.Number(2))?.compressed
            == ReferenceSecp256k1.Number.hexBytes("02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"))
        #expect(ReferenceSecp256k1.multiply(g, ReferenceSecp256k1.n.value) == nil)
        #expect(ReferenceSecp256k1.multiply(g, ReferenceSecp256k1.n.value - .one) == ReferenceSecp256k1.negate(g))
    }

    @Test("an odd-nonce signature is valid in every way but R's parity")
    func oddNonce() throws {
        let secret = try #require(ReferenceSecp256k1.secret(Data(repeating: 0, count: 31) + Data([3])))
        let message = Data(repeating: 0x5A, count: 32)
        let publicX = ReferenceSecp256k1.publicKey(secret).x.bigEndian32
        var found = 0
        for nonce in 1 ... UInt32(8) {
            guard let signature = ReferenceSecp256k1.oddNonceSignature(
                message: message, secret: secret, nonce: ReferenceSecp256k1.Number(nonce)) else { continue }
            found += 1
            #expect(!ReferenceSecp256k1.verify(signature: signature, message: message, publicKey: publicX))
        }
        #expect(found > 0)
    }
}
