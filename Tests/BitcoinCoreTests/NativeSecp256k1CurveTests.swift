import Foundation
@testable import NativeSecp256k1
import Testing
import TestSupport
@testable import WalletCore

/// Scalars, points and group operations of the native secp256k1 module.
/// Expected coordinates and products were computed with Python integers in
/// an independent double-and-add implementation (not the Swift code), except
/// where noted as official vectors.
@Suite("Native secp256k1 curve")
struct NativeSecp256k1CurveTests {
    struct KeyVector: Decodable {
        let name: String
        let x: String
        let evenY: String?
    }

    static let gx = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
    static let gy = "483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"
    static let orderHex = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"
    static let orderMinusOne = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140"

    /// k, x(kG), y(kG). Row 1 agrees with BIP340 vector 0 (secret key 3).
    static let generatorMultiples: [(String, String, String)] = [
        ("0000000000000000000000000000000000000000000000000000000000000001", gx, gy),
        ("0000000000000000000000000000000000000000000000000000000000000002",
         "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5",
         "1ae168fea63dc339a3c58419466ceaeef7f632653266d0e1236431a950cfe52a"),
        ("0000000000000000000000000000000000000000000000000000000000000003",
         "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9",
         "388f7b0f632de8140fe337e62a37f3566500a99934c2231b6cb9fd7584b8e672"),
        ("0000000000000000000000000000000000000000000000000000000000000007",
         "5cbdf0646e5db4eaa398f365f2ea7a0e3d419b7e0330e39ce92bddedcac4f9bc",
         "6aebca40ba255960a3178d6d861a54dba813d0b813fde7b5a5082628087264da"),
        ("0000000000000000000000000000000100000000000000000000000000000000",
         "8f68b9d2f63b5f339239c1ad981f162ee88c5678723ea3351b7b444c9ec4c0da",
         "662a9f2dba063986de1d90c2b6be215dbbea2cfe95510bfdf23cbf79501fff82"),
        ("8000000000000000000000000000000000000000000000000000000000000000",
         "b23790a42be63e1b251ad6c94fdef07271ec0aada31db6c3e8bd32043f8be384",
         "fc6b694919d55edbe8d50f88aa81f94517f004f4149ecb58d10a473deb19880e"),
        (orderMinusOne, gx, "b7c52588d95c3b9aa25b0403f1eef75702e84bb7597aabe663b82f6f04ef2777"),
        ("deadbeefcafebabe0123456789abcdeffedcba98765432100f0f0f0f0f0f0f0f",
         "d0598f937bfb8fa93aa6210b0f80841015269b49339331446114d43b53cf2e2c",
         "841007eee269a124443b745273dd212625b2eb8a4064b8f4bc719d1eac249f9d"),
    ]

    /// a, b, a·b mod n, a+b mod n.
    static let scalarPairs: [(String, String, String, String)] = [
        (orderMinusOne, orderMinusOne,
         "0000000000000000000000000000000000000000000000000000000000000001",
         "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd036413f"),
        ("0000000000000000000000000000000000000000000000000000000000000002", orderMinusOne,
         "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd036413f",
         "0000000000000000000000000000000000000000000000000000000000000001"),
        ("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
         "fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321",
         "f98f7d20ac3698c87edae71c5a4709c495593962d6c397bad9a1b3edb5d15217",
         "111110821811111111111082181111125662339b68c870d5513eb1f547dacfcf"),
        (orderMinusOne, "8000000000000000000000000000000000000000000000000000000000000000",
         "7ffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",
         "7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
        ("0000000000000000000000000000000000000000000000000000000000000003",
         "0055555555555555555555555555555555555555555555555555555555555555",
         "00ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
         "0055555555555555555555555555555555555555555555555555555555555558"),
    ]

    static func bytes(_ hex: String) throws -> Data {
        try #require(Data(hex: hex), "hex \(hex)")
    }

    static func scalar(_ hex: String) throws -> Scalar {
        let data = try bytes(hex)
        return try #require(Scalar(bigEndian: data), "scalar \(hex)")
    }

    static func field(_ hex: String) throws -> FieldElement {
        let data = try bytes(hex)
        return try #require(FieldElement(bigEndian: data), "field \(hex)")
    }

    static func affine(_ point: JacobianPoint) throws -> AffinePoint {
        try #require(point.affine(), "finite point")
    }

    // MARK: - Scalars

    @Test("scalar parsing accepts 0 ..< n and rejects everything else")
    func scalarParsing() throws {
        #expect(try Self.scalar("00" + String(repeating: "0", count: 62)) == .zero)
        #expect(try Self.scalar("00" + String(repeating: "0", count: 61) + "1") == .one)
        #expect(try Self.scalar(Self.orderMinusOne).bigEndian.hex == Self.orderMinusOne)
        for hex in [Self.orderHex,
                    "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364142",
                    String(repeating: "f", count: 64)] {
            let data = try Self.bytes(hex)
            #expect(Scalar(bigEndian: data) == nil, "\(hex)")
        }
        for length in [0, 1, 31, 33, 64] {
            #expect(Scalar(bigEndian: Data(repeating: 1, count: length)) == nil, "length \(length)")
        }
        #expect(Scalar(reducing: Scalar.order) == .zero)
        let allOnes = Integer256(l0: .max, l1: .max, l2: .max, l3: .max)
        #expect(Scalar(reducing: allOnes).bigEndian.hex
            == "000000000000000000000000000000014551231950b75fc4402da1732fc9bebe")
    }

    @Test("scalar addition, negation and products match Python answers")
    func scalarArithmetic() throws {
        for (a, b, product, sum) in Self.scalarPairs {
            let x = try Self.scalar(a)
            let y = try Self.scalar(b)
            #expect(x.multiplied(by: y).bigEndian.hex == product, "\(a) × \(b)")
            #expect(y.multiplied(by: x).bigEndian.hex == product, "\(b) × \(a)")
            #expect((x + y).bigEndian.hex == sum, "\(a) + \(b)")
            #expect((x + y) - y == x)
            #expect(x.multiplied(by: .one) == x)
            #expect(x.multiplied(by: .zero) == .zero)
            #expect(x + x.negated() == .zero)
        }
        #expect(Scalar.zero.negated() == .zero)
        #expect(try Self.scalar(Self.orderMinusOne).negated() == .one)
        #expect(Scalar.one.negated() == (try Self.scalar(Self.orderMinusOne)))
    }

    // MARK: - Points

    @Test("the generator encodes, parses and negates as expected")
    func generator() throws {
        let g = Curve.generator
        #expect(g.x.bigEndian.hex == Self.gx)
        #expect(g.y.bigEndian.hex == Self.gy)
        #expect(!g.hasOddY)
        #expect(g.compressed.hex == "02" + Self.gx)
        #expect(Curve.parse(compressed: g.compressed) == g)
        let odd = try Self.bytes("03" + Self.gx)
        #expect(Curve.parse(compressed: odd) == g.negated)
        #expect(Curve.parse(compressed: odd)?.hasOddY == true)
        #expect(Curve.liftX(g.x) == g)
    }

    @Test("compressed parsing rejects bad prefixes, lengths, x ≥ p and off-curve x")
    func compressedRejections() throws {
        for prefix in ["00", "01", "04", "05", "ff"] {
            let data = try Self.bytes(prefix + Self.gx)
            #expect(Curve.parse(compressed: data) == nil, "\(prefix)")
        }
        #expect(Curve.parse(compressed: try Self.bytes(Self.gx)) == nil)
        #expect(Curve.parse(compressed: try Self.bytes("02" + Self.gx + "00")) == nil)
        #expect(Curve.parse(compressed: Data()) == nil)
        let tooLarge = try Self.bytes("02fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f")
        #expect(Curve.parse(compressed: tooLarge) == nil)
        // x = 5 has no point on secp256k1 (BIP340 vector 5's public key).
        let offCurve = try Self.bytes("020000000000000000000000000000000000000000000000000000000000000005")
        #expect(Curve.parse(compressed: offCurve) == nil)
    }

    @Test("lift_x agrees with the BIP340 reference and libsecp256k1 on 318 inputs")
    func liftXFixtures() throws {
        let vectors: [KeyVector] = try Vectors.decode([KeyVector].self, "xonly-validation.json", in: .module,
                                                      subdirectory: "Vectors/native-secp256k1")
        #expect(vectors.count == 318)
        for vector in vectors {
            let data = try Self.bytes(vector.x)
            let lifted = FieldElement(bigEndian: data).flatMap(Curve.liftX)
            if let expected = vector.evenY {
                let point = try #require(lifted, "\(vector.name)")
                #expect(point.x.bigEndian.hex == vector.x, "\(vector.name) x")
                #expect(point.y.bigEndian.hex == expected, "\(vector.name) y")
                #expect(!point.hasOddY, "\(vector.name) parity")
            } else {
                #expect(lifted == nil, "\(vector.name)")
            }
        }
    }

    @Test("generator multiples match an independent Python implementation")
    func generatorMultiples() throws {
        for (k, x, y) in Self.generatorMultiples {
            let point = try Self.affine(Curve.multiplyGenerator(try Self.scalar(k)))
            #expect(point.x.bigEndian.hex == x, "x of \(k)")
            #expect(point.y.bigEndian.hex == y, "y of \(k)")
        }
        // (n − 1)·G = −G
        let last = try Self.affine(Curve.multiplyGenerator(try Self.scalar(Self.orderMinusOne)))
        #expect(last == Curve.generator.negated)
        #expect(Curve.multiplyGenerator(.zero).isInfinity)
    }

    @Test("the fixed-base table agrees with plain double-and-add")
    func generatorTable() throws {
        #expect(GeneratorTable.points.count == 64 * 15)
        #expect(GeneratorTable.points[0] == Curve.generator)
        #expect(GeneratorTable.points[1].x.bigEndian.hex == Self.generatorMultiples[1].1)
        var scalars: [Scalar] = [.one, try Self.scalar(Self.orderMinusOne)]
        for bit in [4, 7, 8, 63, 64, 127, 128, 200, 252, 255] {
            var limbs = Integer256.zero
            if bit < 64 { limbs.l0 = 1 << UInt64(bit) }
            else if bit < 128 { limbs.l1 = 1 << UInt64(bit - 64) }
            else if bit < 192 { limbs.l2 = 1 << UInt64(bit - 128) }
            else { limbs.l3 = 1 << UInt64(bit - 192) }
            scalars.append(Scalar(reducing: limbs))
            scalars.append(Scalar(reducing: limbs).negated())
        }
        scalars.append(Scalar(reducing: Integer256(l0: .max, l1: .max, l2: .max, l3: 0x0FFF_FFFF_FFFF_FFFF)))
        var rng = SeededRandom(state: 0x7AB1E)
        for _ in 0 ..< 1000 {
            scalars.append(Scalar(reducing: Integer256(l0: rng.next(), l1: rng.next(), l2: rng.next(), l3: rng.next())))
        }
        for scalar in scalars {
            let table = GeneratorTable.multiply(scalar).affine()
            let plain = Curve.multiply(Curve.generator, by: scalar).affine()
            #expect(table == plain, "scalar \(scalar.bigEndian.hex)")
        }
        #expect(GeneratorTable.multiply(.zero).isInfinity)
    }

    @Test("doubling, mixed addition and the exceptional cases")
    func groupLaw() throws {
        let g = JacobianPoint(Curve.generator)
        let twoG = try Self.affine(g.doubled())
        #expect(twoG.x.bigEndian.hex == Self.generatorMultiples[1].1)
        #expect(try Self.affine(g.adding(Curve.generator)) == twoG) // P == Q takes the doubling branch
        #expect(try Self.affine(g.doubled().adding(Curve.generator)).x.bigEndian.hex == Self.generatorMultiples[2].1)
        #expect(g.adding(Curve.generator.negated).isInfinity) // P == −Q
        #expect(try Self.affine(JacobianPoint.infinity.adding(Curve.generator)) == Curve.generator)
        #expect(JacobianPoint.infinity.doubled().isInfinity)
        #expect(JacobianPoint.infinity.affine() == nil)
        // (n − 1)·G + G = ∞ through the general path with a non-trivial Z.
        let almost = Curve.multiplyGenerator(try Self.scalar(Self.orderMinusOne))
        #expect(!almost.z.isZero && almost.z != .one)
        #expect(almost.adding(Curve.generator).isInfinity)
        // k·P for a non-generator base: 3·(2G) == 6G == 2·(3G)
        let sixViaTwo = try Self.affine(Curve.multiply(twoG, by: try Self.scalar(
            "0000000000000000000000000000000000000000000000000000000000000003")))
        let threeG = try Self.affine(Curve.multiplyGenerator(try Self.scalar(
            "0000000000000000000000000000000000000000000000000000000000000003")))
        #expect(try Self.affine(JacobianPoint(threeG).doubled()) == sixViaTwo)
    }
}
