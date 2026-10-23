import Foundation
@testable import NativeSecp256k1
import Testing
@testable import WinnowFuzzCore

/// Field and scalar arithmetic against ReferenceSecp256k1, the fuzz core's
/// second implementation, on operands built from structured limbs: zero, one,
/// all ones, the top bit, and the limbs of p and n with their neighbours.
/// Products and sums of such limbs drive the rare carries in the product scan
/// and the final reductions that random values, and the fuzzer's keys and
/// points, almost never reach.
@Suite("Native secp256k1 against the reference implementation")
struct NativeSecp256k1ReferenceTests {
    typealias Reference = ReferenceSecp256k1

    static let limbs: [UInt64] = [
        0, 1, 2, 3, .max, .max - 1, .max - 2, 1 << 63, (1 << 63) - 1, (1 << 32) - 1, 1 << 32, .max ^ (1 << 32),
        0xFFFF_FFFE_FFFF_FC2D, 0xFFFF_FFFE_FFFF_FC2E, 0xFFFF_FFFE_FFFF_FC2F, 0xFFFF_FFFE_FFFF_FC30,
        0xBFD2_5E8C_D036_4140, 0xBFD2_5E8C_D036_4141, 0xBAAE_DCE6_AF48_A03B, 0xFFFF_FFFF_FFFF_FFFE,
    ]

    /// Deterministic integers whose limbs come from `limbs`, with a raw
    /// random limb now and then. A quarter carry p's top three limbs and a
    /// quarter n's: independent limbs almost never land between p and 2^256
    /// or near n, which is where the final reductions live.
    static func integers(count: Int, seed: UInt64) -> [Integer256] {
        var rng = SplitMix64(state: seed)
        func limb() -> UInt64 { rng.index(8) == 0 ? rng.next() : limbs[rng.index(limbs.count)] }
        return (0 ..< count).map { _ in
            switch rng.index(4) {
            case 0:
                return Integer256(l0: limb(), l1: .max, l2: .max, l3: .max)
            case 1:
                let l1 = rng.index(2) == 0 ? 0xBAAE_DCE6_AF48_A03B : limb()
                return Integer256(l0: limb(), l1: l1, l2: 0xFFFF_FFFF_FFFF_FFFE, l3: .max)
            default:
                return Integer256(l0: limb(), l1: limb(), l2: limb(), l3: limb())
            }
        }
    }

    static func number(_ value: Integer256) -> Reference.Number { Reference.Number(bigEndian: value.bigEndian) }

    @Test("field products, squares, sums, differences and negations match")
    func fieldArithmetic() {
        let values = Self.integers(count: 4_000, seed: 0x4649_454C_44).map { FieldElement(reducing: $0) }
        for (a, b) in zip(values, values.dropFirst() + values.prefix(1)) {
            let x = Self.number(a.value), y = Self.number(b.value)
            #expect(Self.number((a * b).value) == Reference.p.multiply(x, y), "\(a.bigEndian.hexString) × \(b.bigEndian.hexString)")
            #expect(Self.number(a.squared().value) == Reference.p.multiply(x, x), "\(a.bigEndian.hexString)²")
            #expect(Self.number((a + b).value) == Reference.p.add(x, y), "\(a.bigEndian.hexString) + \(b.bigEndian.hexString)")
            #expect(Self.number((a - b).value) == Reference.p.subtract(x, y), "\(a.bigEndian.hexString) − \(b.bigEndian.hexString)")
            #expect(Self.number(a.negated().value) == Reference.p.negate(x), "−\(a.bigEndian.hexString)")
        }
    }

    @Test("field inverses and square roots match")
    func fieldInversesAndRoots() {
        let values = Self.integers(count: 300, seed: 0x524F_4F54).map { FieldElement(reducing: $0) }
        for a in values where !a.isZero {
            let x = Self.number(a.value)
            #expect(Self.number(a.inverse().value) == Reference.p.inverse(x), "1/\(a.bigEndian.hexString)")
            let root = Reference.p.power(x, (Reference.p.value + .one).halved.halved)
            let isSquare = Reference.p.multiply(root, root) == x
            let native = a.squareRoot()
            #expect((native != nil) == isSquare, "√\(a.bigEndian.hexString) existence")
            if let native { #expect(native.squared() == a, "√\(a.bigEndian.hexString)") }
        }
    }

    @Test("scalar sums, differences, negations and products match")
    func scalarArithmetic() {
        let values = Self.integers(count: 600, seed: 0x5343_414C).map { Scalar(reducing: $0) }
        for (a, b) in zip(values, values.dropFirst() + values.prefix(1)) {
            let x = Self.number(a.value), y = Self.number(b.value)
            #expect(Self.number((a + b).value) == Reference.n.add(x, y), "\(a.bigEndian.hexString) + \(b.bigEndian.hexString)")
            #expect(Self.number((a - b).value) == Reference.n.subtract(x, y), "\(a.bigEndian.hexString) − \(b.bigEndian.hexString)")
            #expect(Self.number(a.negated().value) == Reference.n.negate(x), "−\(a.bigEndian.hexString)")
            #expect(Self.number(a.multiplied(by: b).value) == Reference.n.multiply(x, y),
                    "\(a.bigEndian.hexString) × \(b.bigEndian.hexString)")
        }
    }

    @Test("parsing accepts exactly the values below p and below n")
    func parsingBounds() {
        let p = Integer256(l0: 0xFFFF_FFFE_FFFF_FC2F, l1: .max, l2: .max, l3: .max)
        let n = Integer256(l0: 0xBFD2_5E8C_D036_4141, l1: 0xBAAE_DCE6_AF48_A03B, l2: 0xFFFF_FFFF_FFFF_FFFE, l3: .max)
        let one = Integer256.one
        let edges = [p, n].flatMap { [$0.subtractingReportingOverflow(one).partialValue, $0,
                                      $0.addingReportingOverflow(one).partialValue] }
        for value in edges + Self.integers(count: 2_000, seed: 0x5041_5253) {
            let bytes = value.bigEndian
            #expect((FieldElement(bigEndian: bytes) != nil) == (Self.number(value) < Reference.p.value), "\(bytes.hexString)")
            #expect((Scalar(bigEndian: bytes) != nil) == (Self.number(value) < Reference.n.value), "\(bytes.hexString)")
        }
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
