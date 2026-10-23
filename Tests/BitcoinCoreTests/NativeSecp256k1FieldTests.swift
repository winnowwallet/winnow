import Foundation
@testable import NativeSecp256k1
import Testing
import TestSupport
@testable import WalletCore

/// The 256-bit integer and base-field layers of the native secp256k1 module,
/// checked against answers computed outside Swift (see
/// Vectors/native-secp256k1/README.md) and against algebraic identities.
@Suite("Native secp256k1 field")
struct NativeSecp256k1FieldTests {
    struct ArithmeticVector: Decodable {
        let a: String
        let b: String
        let sum: String
        let product: String
        let negation: String
    }

    struct RootVector: Decodable {
        let value: String
        let evenRoot: String?
    }

    static func fixture<T: Decodable>(_ name: String) throws -> T {
        try Vectors.decode(T.self, name + ".json", in: .module, subdirectory: "Vectors/native-secp256k1")
    }

    static func bytes(_ hex: String) throws -> Data {
        try #require(Data(hex: hex), "hex \(hex)")
    }

    static func element(_ hex: String) throws -> FieldElement {
        let data = try bytes(hex)
        return try #require(FieldElement(bigEndian: data), "element \(hex)")
    }

    static let pMinusOne = "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2e"

    // MARK: - Integer256

    @Test("Integer256 round-trips big-endian bytes and exposes bits")
    func integerEncoding() throws {
        let hex = "0123456789abcdeffedcba9876543210" + "00000000000000010000000000000080"
        let value = try #require(Integer256(bigEndian: Self.bytes(hex)))
        #expect(value.l3 == 0x0123_4567_89ab_cdef)
        #expect(value.l2 == 0xfedc_ba98_7654_3210)
        #expect(value.l1 == 1)
        #expect(value.l0 == 0x80)
        #expect(value.bigEndian.hex == hex)
        #expect(value.bit(7) && !value.bit(6) && value.bit(64) && !value.bit(65) && value.bit(248))
        #expect(!value.bit(-1) && !value.bit(256))
        #expect(value.bits(from: 4, count: 4) == 0x8)
        #expect(value.bits(from: 60, count: 8) == 0x10) // crosses the l0/l1 boundary: low nibble 0, then bit 64
        #expect(value.bits(from: 192, count: 64) == 0x0123_4567_89ab_cdef)
        #expect(value.bits(from: 252, count: 8) == 0x0)
        #expect(Integer256(bigEndian: Data(repeating: 0, count: 31)) == nil)
        #expect(Integer256(bigEndian: Data(repeating: 0, count: 33)) == nil)
    }

    @Test("Integer256 addition, subtraction and comparison carry across limbs")
    func integerAddSubCompare() {
        let max = Integer256(l0: .max, l1: .max, l2: .max, l3: .max)
        let (sum, overflow) = max.addingReportingOverflow(.one)
        #expect(sum == .zero && overflow)
        let (difference, borrow) = Integer256.zero.subtractingReportingOverflow(.one)
        #expect(difference == max && borrow)
        let (carried, carry) = Integer256(l0: .max, l1: 0, l2: 0, l3: 0).addingReportingOverflow(.one)
        #expect(carried == Integer256(l0: 0, l1: 1, l2: 0, l3: 0) && !carry)
        #expect(Integer256.zero < .one)
        #expect(Integer256(l0: 0, l1: 0, l2: 0, l3: 1) > Integer256(l0: .max, l1: .max, l2: .max, l3: 0))
        #expect(!(max < max))
    }

    @Test("Integer256 full-width products match closed forms")
    func integerMultiply() {
        let max = Integer256(l0: .max, l1: .max, l2: .max, l3: .max)
        // (2^256 − 1)^2 = 2^512 − 2^257 + 1
        let (high, low) = max.multipliedFullWidth(by: max)
        #expect(low == .one)
        #expect(high == Integer256(l0: .max - 1, l1: .max, l2: .max, l3: .max))
        // (2^64 − 1)^2 = 2^128 − 2^65 + 1
        let limb = Integer256(l0: .max, l1: 0, l2: 0, l3: 0)
        let (high2, low2) = limb.multipliedFullWidth(by: limb)
        #expect(high2 == .zero)
        #expect(low2 == Integer256(l0: 1, l1: .max - 1, l2: 0, l3: 0))
        // single-limb multiplier: (2^256 − 1) × (2^64 − 1) = 2^320 − 2^256 − 2^64 + 1
        let (top, rest) = max.multipliedFullWidth(by: UInt64.max)
        #expect(top == UInt64.max - 1)
        #expect(rest == Integer256(l0: 1, l1: .max, l2: .max, l3: .max))
        #expect(Integer256.zero.multipliedFullWidth(by: max) == (Integer256.zero, Integer256.zero))
    }

    // MARK: - Field fixtures

    @Test("Python big-integer answers across limb and modulus boundaries")
    func arithmeticKnownAnswers() throws {
        let vectors: [ArithmeticVector] = try Self.fixture("field-arithmetic")
        #expect(vectors.count == 290)
        for (index, vector) in vectors.enumerated() {
            let a = try Self.element(vector.a)
            let b = try Self.element(vector.b)
            #expect(a.bigEndian.hex == vector.a, "round trip \(index)")
            #expect((a + b).bigEndian.hex == vector.sum, "addition \(index)")
            #expect((a * b).bigEndian.hex == vector.product, "multiplication \(index)")
            #expect(a.negated().bigEndian.hex == vector.negation, "negation \(index)")
            #expect((a + b) - b == a, "subtraction \(index)")
            #expect(a - b == a + b.negated(), "subtraction as negation \(index)")
        }
    }

    @Test("square roots, zero and non-residues against Python modular exponentiation")
    func rootKnownAnswers() throws {
        let vectors: [RootVector] = try Self.fixture("field-roots")
        #expect(vectors.count == 56)
        #expect(vectors.contains { $0.evenRoot == nil })
        for vector in vectors {
            let value = try Self.element(vector.value)
            let root = value.squareRoot()
            if let expected = vector.evenRoot {
                let actual = try #require(root, "root of \(vector.value)")
                let even = actual.isOdd ? actual.negated() : actual
                #expect(even.bigEndian.hex == expected, "root of \(vector.value)")
                #expect(actual.squared() == value)
            } else {
                #expect(root == nil, "non-residue \(vector.value)")
            }
        }
    }

    // MARK: - Identities

    @Test("inverses, squares and powers agree with multiplication")
    func inverseAndPower() throws {
        var rng = SeededRandom(state: 0x5EC2_56C1)
        let top = try Self.element(Self.pMinusOne)
        var elements = [FieldElement.one, FieldElement.seven, top]
        for _ in 0 ..< 256 {
            let integer = Integer256(l0: rng.next(), l1: rng.next(), l2: rng.next(), l3: rng.next())
            elements.append(FieldElement(reducing: integer))
        }
        for element in elements where !element.isZero {
            #expect(element * element.inverse() == .one)
            #expect(element.inverse().inverse() == element)
            #expect(element.squared() == element * element)
            #expect(element.pow(Integer256(l0: 3, l1: 0, l2: 0, l3: 0)) == element * element * element)
            #expect(element * .one == element)
            #expect(element * .zero == .zero)
            #expect(element + element.negated() == .zero)
        }
        #expect(FieldElement.zero.inverse() == .zero)
        #expect(FieldElement.zero.squareRoot() == .zero)
    }

    @Test("values at the top of the field reduce correctly")
    func boundaryProducts() throws {
        let minusOne = try Self.element(Self.pMinusOne)
        #expect(minusOne * minusOne == .one)
        #expect(minusOne + .one == .zero)
        let twice = try Self.element("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2d")
        #expect(minusOne + minusOne == twice)
        #expect(FieldElement.zero - .one == minusOne)
        // Every limb pattern that stresses the fold: all-ones limbs below the top.
        let patterns: [Integer256] = [
            Integer256(l0: .max, l1: .max, l2: .max, l3: 0),
            Integer256(l0: .max, l1: .max, l2: .max, l3: 0x7FFF_FFFF_FFFF_FFFF),
            Integer256(l0: 0, l1: 0, l2: 0, l3: 1 << 63),
            Integer256(l0: 0xFFFF_FFFE_FFFF_FC2E, l1: .max, l2: .max, l3: .max),
        ]
        for pattern in patterns {
            let element = FieldElement(reducing: pattern)
            // (x · y) · x⁻¹ == y for several partners exercises reduce() on large products.
            for partner in [minusOne, FieldElement.seven, element] {
                #expect(element * partner * element.inverse() == partner)
            }
        }
    }

    // MARK: - Input handling

    @Test("wrong lengths and non-canonical encodings are rejected without reduction")
    func malformedInputs() throws {
        for length in Array(0 ... 64) + [255, 1024] where length != 32 {
            #expect(FieldElement(bigEndian: Data(repeating: 0, count: length)) == nil, "length \(length)")
        }
        for value in [
            "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f", // p
            "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc30", // p + 1
            "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", // 2^256 − 1
        ] {
            let bytes = try Self.bytes(value)
            #expect(FieldElement(bigEndian: bytes) == nil, "\(value)")
        }
        let top = try Self.element(Self.pMinusOne)
        #expect(top.bigEndian.hex == Self.pMinusOne)
        #expect(FieldElement(reducing: Self.modulusPlusOne) == .one)
    }

    static let modulusPlusOne = Integer256(l0: 0xFFFF_FFFE_FFFF_FC30, l1: .max, l2: .max, l3: .max)

    @Test("offset Data slices and retained values preserve bytes")
    func offsetSlices() throws {
        let gx = try Self.bytes("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
        var storage = Data([0xAA, 0xBB]) + gx + Data([0xCC])
        let slice = storage.dropFirst(2).dropLast()
        #expect(slice.startIndex == 2)
        let element = try #require(FieldElement(bigEndian: slice))
        storage.resetBytes(in: storage.startIndex ..< storage.endIndex)
        #expect(element.bigEndian == gx)
    }
}
