import Foundation
@testable import NativeSecp256k1
import Testing
@testable import WinnowFuzzCore

/// The generated arithmetic (Sources/NativeSecp256k1/Generated, printed by
/// Tools/Proofs from proved programs) against the hand-written arithmetic it
/// replaced and against ReferenceSecp256k1. The proofs cover the programs;
/// these tests cover what the proofs assume: the printer and the model of
/// Swift's UInt64 calls. Operands come from structured limbs (zero, one, all
/// ones, the top bit, the limbs of p and n and their neighbours), every pair
/// of a small grid of them, and the shapes NativeSecp256k1ReferenceTests uses.
@Suite("Native secp256k1 generated arithmetic")
struct NativeSecp256k1GeneratedTests {
    typealias Reference = ReferenceSecp256k1

    /// Every four-limb combination of a few edge limbs: 6^4 = 1296 values.
    static let grid: [Integer256] = {
        let edges: [UInt64] = [0, 1, .max, 1 << 63, 0xFFFF_FFFE_FFFF_FC2F, 0xBFD2_5E8C_D036_4141]
        return edges.flatMap { a in edges.flatMap { b in edges.flatMap { c in edges.map { d in
            Integer256(l0: a, l1: b, l2: c, l3: d)
        } } } }
    }()

    /// The grid followed by the reference suite's structured integers.
    static func operands(seed: UInt64) -> [Integer256] {
        grid + NativeSecp256k1ReferenceTests.integers(count: 3_000, seed: seed)
    }

    /// Pairs: each operand with its neighbour in the list, and with a value
    /// a stride away, so every grid value meets several others.
    static func pairs<T>(_ values: [T]) -> [(T, T)] {
        Array(zip(values, values.dropFirst() + values.prefix(1))) +
            values.enumerated().map { ($1, values[($0 * 37 + 11) % values.count]) }
    }

    static func number(_ value: Integer256) -> Reference.Number { Reference.Number(bigEndian: value.bigEndian) }

    @Test("integer sums, differences and products match the hand-written code")
    func integers() {
        for (a, b) in Self.pairs(Self.operands(seed: 0x494E_5447)) {
            let (sum, carry) = GeneratedInteger256.add(a, b)
            let oldSum = HandWritten.add(a, b)
            #expect(sum == oldSum.partialValue && (carry != 0) == oldSum.overflow && carry <= 1)
            let (difference, borrow) = GeneratedInteger256.subtract(a, b)
            let oldDifference = HandWritten.subtract(a, b)
            #expect(difference == oldDifference.partialValue && (borrow != 0) == oldDifference.overflow && borrow <= 1)
            #expect(GeneratedInteger256.multiply(a, b) == HandWritten.multiply(a, b))
            #expect(GeneratedInteger256.square(a) == HandWritten.square(a))
            #expect(GeneratedInteger256.multiply(a, b.l0) == HandWritten.multiply(a, by: b.l0))
        }
    }

    @Test("integer products match the reference's schoolbook product")
    func integerProducts() {
        for (a, b) in Self.pairs(Self.operands(seed: 0x5052_4F44)) {
            let (high, low) = GeneratedInteger256.multiply(a, b)
            let expected = Reference.Modulus.schoolbook(Self.number(a), Self.number(b))
            #expect(Reference.Number(bigEndian: high.bigEndian + low.bigEndian) == expected)
        }
    }

    @Test("field operations match the hand-written code and the reference")
    func field() {
        let values = Self.operands(seed: 0x4649_454C).map(HandWritten.fieldReducing)
        for (a, b) in Self.pairs(values) {
            let x = Self.number(a), y = Self.number(b)
            #expect(GeneratedField.multiply(a, b) == HandWritten.fieldMultiply(a, b))
            #expect(Self.number(GeneratedField.multiply(a, b)) == Reference.p.multiply(x, y))
            #expect(GeneratedField.square(a) == HandWritten.fieldSquare(a))
            #expect(GeneratedField.add(a, b) == HandWritten.fieldAdd(a, b))
            #expect(Self.number(GeneratedField.add(a, b)) == Reference.p.add(x, y))
            #expect(GeneratedField.subtract(a, b) == HandWritten.fieldSubtract(a, b))
            #expect(Self.number(GeneratedField.subtract(a, b)) == Reference.p.subtract(x, y))
            #expect(GeneratedField.negate(a) == HandWritten.fieldNegate(a))
        }
    }

    @Test("field reduction and products accept any 256-bit operands")
    func fieldUnreduced() {
        for (a, b) in Self.pairs(Self.operands(seed: 0x5245_4455)) {
            #expect(GeneratedField.reduce(a) == HandWritten.fieldReducing(a))
            // The theorems hold for operands of p or more; the hand-written
            // reduction takes any 512-bit product too.
            #expect(GeneratedField.multiply(a, b) == HandWritten.fieldMultiply(a, b))
            #expect(GeneratedField.square(a) == HandWritten.fieldSquare(a))
        }
    }

    @Test("scalar operations match the hand-written code and the reference")
    func scalar() {
        let values = Self.operands(seed: 0x5343_414C).map(HandWritten.scalarReducing)
        for (index, (a, b)) in Self.pairs(values).enumerated() {
            let x = Self.number(a), y = Self.number(b)
            #expect(Self.number(GeneratedScalar.multiply(a, b)) == Reference.n.multiply(x, y))
            #expect(GeneratedScalar.add(a, b) == HandWritten.scalarAdd(a, b))
            #expect(GeneratedScalar.subtract(a, b) == HandWritten.scalarSubtract(a, b))
            #expect(Self.number(GeneratedScalar.subtract(a, b)) == Reference.n.subtract(x, y))
            #expect(GeneratedScalar.negate(a) == HandWritten.scalarNegate(a))
            // The binary method costs 512 modular additions; sample it.
            if index % 8 == 0 { #expect(GeneratedScalar.multiply(a, b) == HandWritten.scalarMultiply(a, b)) }
        }
    }

    @Test("scalar reduction accepts any 256-bit operand")
    func scalarUnreduced() {
        for a in Self.operands(seed: 0x4841_5348) {
            #expect(GeneratedScalar.reduce(a) == HandWritten.scalarReducing(a))
            #expect(Self.number(GeneratedScalar.reduce(a)) == Reference.n.reduce(Self.number(a)))
        }
    }

    @Test("point formulas and exponentiation chains match the hand-written ones")
    func curve() {
        let values = Self.operands(seed: 0x4355_5256).map { FieldElement(reducing: $0) }
        for (index, (a, b)) in Self.pairs(values).enumerated() {
            let c = values[(index * 13 + 5) % values.count]
            let d = values[(index * 29 + 3) % values.count]
            let e = values[(index * 7 + 1) % values.count]
            #expect(GeneratedCurve.double(a, b, c) == HandWritten.double(a, b, c))
            #expect(GeneratedCurve.addMixed(a, b, c, d, e) == HandWritten.addMixed(a, b, c, d, e))
            // Square-and-multiply costs about 512 multiplications; sample it.
            if index % 16 == 0 {
                #expect(GeneratedCurve.invert(a) == HandWritten.inverse(a))
                #expect(GeneratedCurve.squareRootCandidate(a) == HandWritten.squareRootCandidate(a))
                #expect(Self.number(GeneratedCurve.invert(a).value) == Reference.p.inverse(Self.number(a.value)))
            }
        }
    }
}
