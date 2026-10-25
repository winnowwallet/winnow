import Foundation
import P256K
import Testing
import TestSupport
@testable import WalletCore

/// ElligatorSwift against BIP 324's vectors, plus the parity rule BIP 77
/// relies on: the point decoded from an encoding is the point encoded, not
/// just its x coordinate.
@Suite("ElligatorSwift (BIP 324)")
struct ElligatorSwiftTests {
    private typealias FE = Secp256k1FieldElement

    private static func rows(_ file: String) throws -> [[String]] {
        try Vectors.string(file, in: .module)
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    @Test("ellswift_decode_test_vectors.csv: every (u, t) decodes to the listed x")
    func decodeVectors() throws {
        let rows = try Self.rows("ellswift_decode_test_vectors.csv")
        #expect(rows.count == 76)
        for row in rows {
            let encoded = try #require(Data(hex: row[0]))
            let expected = try #require(Data(hex: row[1]))
            let key = try ElligatorSwift.decode(encoded)
            #expect(key.dropFirst() == expected, Comment(rawValue: row[2]))
            // The prefix follows t's parity, after reduction mod p.
            let t = FE(bytes: encoded.suffix(32))
            #expect(key.first == (t.isOdd ? 0x03 : 0x02), Comment(rawValue: row[2]))
        }
    }

    @Test("xswiftec_inv_test_vectors.csv: each branch yields the listed t or nothing")
    func inverseVectors() throws {
        let rows = try Self.rows("xswiftec_inv_test_vectors.csv")
        #expect(rows.count == 32)
        for row in rows {
            let u = FE(bytes: try #require(Data(hex: row[0])))
            let x = FE(bytes: try #require(Data(hex: row[1])))
            for branch in 0 ..< 8 {
                let expected = row[2 + branch]
                let t = ElligatorSwift.xswiftecInverse(x, u, branch)
                if expected.isEmpty {
                    #expect(t == nil, "branch \(branch) of \(row[10])")
                } else {
                    #expect(t?.bytes.hex == expected, "branch \(branch) of \(row[10])")
                    if let t { #expect(ElligatorSwift.xswiftec(u, t) == x) }
                }
            }
        }
    }

    @Test("encode then decode returns the same point, parity included")
    func roundTrip() throws {
        for _ in 0 ..< 16 {
            let key = try P256K.Signing.PrivateKey().publicKey.dataRepresentation
            let encoded = try ElligatorSwift.encode(publicKey: key)
            #expect(encoded.count == 64)
            #expect(try ElligatorSwift.decode(encoded) == key)
        }
    }

    @Test("encode refuses bad keys and lengths")
    func refusals() throws {
        #expect(throws: ElligatorSwift.Failure.invalidLength) { try ElligatorSwift.encode(publicKey: Data(count: 32)) }
        #expect(throws: ElligatorSwift.Failure.invalidLength) { try ElligatorSwift.decode(Data(count: 63)) }
        // x = 5 is not on the curve.
        let offCurve = Data([0x02]) + Data(count: 31) + Data([5])
        #expect(throws: ElligatorSwift.Failure.invalidPublicKey) { try ElligatorSwift.encode(publicKey: offCurve) }
    }

    @Test("field arithmetic identities")
    func field() throws {
        let p = Data(hex: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f")!
        #expect(FE(bytes: p).isZero, "p reduces to zero")
        let a = FE(bytes: Data(hex: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")!)
        #expect((a * a.inverse()) == FE.one)
        #expect((a + (-a)).isZero)
        #expect((a - a).isZero)
        #expect(a.squared() == a * a)
        let root = try #require(a.squared().squareRoot())
        #expect(root == a || root == -a)
        #expect(ElligatorSwift.minus3Sqrt.squared() == -FE(3))
        #expect(FE.one.inverse() == FE.one)
        #expect(FE(bytes: (FE(bytes: p) - FE.one).bytes) == -FE.one)
    }
}
