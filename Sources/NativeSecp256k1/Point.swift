import Foundation

/// A finite point on secp256k1, y² = x³ + 7, in affine coordinates. Never the
/// point at infinity: that state exists only on `JacobianPoint`.
struct AffinePoint: Equatable, Sendable {
    let x: FieldElement
    let y: FieldElement

    var negated: AffinePoint { AffinePoint(x: x, y: y.negated()) }

    /// True when y is odd: the BIP340 parity bit and the 0x03 SEC prefix.
    var hasOddY: Bool { y.isOdd }

    /// The 33-byte SEC compressed encoding.
    var compressed: Data { Data([hasOddY ? 0x03 : 0x02]) + x.bigEndian }
}

/// A point in Jacobian coordinates (X : Y : Z) representing the affine point
/// (X/Z², Y/Z³); Z = 0 is the point at infinity. The formulas are the
/// a = 0 specialisations from the Explicit-Formulas Database. Variable-time:
/// the exceptional cases (infinity, doubling, inverses) take branches.
struct JacobianPoint: Sendable {
    var x: FieldElement
    var y: FieldElement
    var z: FieldElement

    static let infinity = JacobianPoint(x: .one, y: .one, z: .zero)

    init(x: FieldElement, y: FieldElement, z: FieldElement) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(_ affine: AffinePoint) {
        self.init(x: affine.x, y: affine.y, z: .one)
    }

    var isInfinity: Bool { z.isZero }

    /// 2P by `dbl-2009-l` (2M + 5S). Infinity stays infinity because Z3 = 2·Y·Z.
    /// The formula is in Generated/GeneratedCurve.swift, proved in Tools/Proofs
    /// against the affine group law.
    func doubled() -> JacobianPoint {
        let (x3, y3, z3) = GeneratedCurve.double(x, y, z)
        return JacobianPoint(x: x3, y: y3, z: z3)
    }

    /// P + Q for an affine Q by `madd-2007-bl` (7M + 4S), with the three
    /// cases the formula cannot express handled here: P at infinity, Q = P
    /// (doubling) and Q = −P (infinity). The formula, and the facts these
    /// branches rely on (H = 0 exactly when the x coordinates agree, r = 0
    /// exactly when the y coordinates do), are proved in Tools/Proofs.
    func adding(_ other: AffinePoint) -> JacobianPoint {
        guard !isInfinity else { return JacobianPoint(other) }
        let (x3, y3, z3, h, r) = GeneratedCurve.addMixed(x, y, z, other.x, other.y)
        if h.isZero {
            return r.isZero ? doubled() : .infinity
        }
        return JacobianPoint(x: x3, y: y3, z: z3)
    }

    /// The affine point, or nil for infinity. Costs one field inversion.
    func affine() -> AffinePoint? {
        guard !isInfinity else { return nil }
        let zInverse = z.inverse()
        let zInverse2 = zInverse.squared()
        return AffinePoint(x: x * zInverse2, y: y * zInverse2 * zInverse)
    }
}

/// Group-level operations on secp256k1.
enum Curve {
    /// G = (79BE667E F9DCBBAC 55A06295 CE870B07 029BFCDB 2DCE28D9 59F2815B 16F81798,
    ///      483ADA77 26A3C465 5DA4FBFC 0E1108A8 FD17B448 A6855419 9C47D08F FB10D4B8).
    static let generator = AffinePoint(
        x: FieldElement(reducing: Integer256(l0: 0x59F2_815B_16F8_1798, l1: 0x029B_FCDB_2DCE_28D9,
                                             l2: 0x55A0_6295_CE87_0B07, l3: 0x79BE_667E_F9DC_BBAC)),
        y: FieldElement(reducing: Integer256(l0: 0x9C47_D08F_FB10_D4B8, l1: 0xFD17_B448_A685_5419,
                                             l2: 0x5DA4_FBFC_0E11_08A8, l3: 0x483A_DA77_26A3_C465)))

    /// BIP340 lift_x: the point with this x coordinate and even y, or nil
    /// when x³ + 7 is a non-residue.
    static func liftX(_ x: FieldElement) -> AffinePoint? {
        let rightHandSide = x.squared() * x + .seven
        guard let root = rightHandSide.squareRoot() else { return nil }
        return AffinePoint(x: x, y: root.isOdd ? root.negated() : root)
    }

    /// Parses a 33-byte SEC compressed point: prefix 0x02 or 0x03, x below p
    /// and on the curve. Nil for anything else, including infinity encodings.
    static func parse(compressed data: Data) -> AffinePoint? {
        guard data.count == 33 else { return nil }
        let bytes = Array(data)
        guard bytes[0] == 0x02 || bytes[0] == 0x03,
              let x = FieldElement(bigEndian: Data(bytes[1...])),
              let even = liftX(x)
        else { return nil }
        return bytes[0] == 0x03 ? even.negated : even
    }

    /// k·P by left-to-right double-and-add. Variable-time in k. Infinity for
    /// k = 0.
    static func multiply(_ point: AffinePoint, by scalar: Scalar) -> JacobianPoint {
        var accumulator = JacobianPoint.infinity
        for index in stride(from: 255, through: 0, by: -1) {
            accumulator = accumulator.doubled()
            if scalar.bit(index) { accumulator = accumulator.adding(point) }
        }
        return accumulator
    }

    /// k·G through the fixed-base table.
    static func multiplyGenerator(_ scalar: Scalar) -> JacobianPoint {
        GeneratorTable.multiply(scalar)
    }
}
