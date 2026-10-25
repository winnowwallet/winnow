import Foundation

/// Arithmetic in the secp256k1 base field GF(p), p = 2²⁵⁶ − 2³² − 977. Four
/// 64-bit limbs, least significant first, always kept fully reduced. This is
/// field arithmetic only — no curve points — for the ElligatorSwift encoding
/// BIP 77 puts on the wire; point operations stay in the pinned
/// `swift-secp256k1`. Variable time: every value it touches is public (an
/// encoded ephemeral public key).
///
/// Exercised by `ElligatorSwiftTests`, whose BIP 324 vectors drive every
/// operation here through `xswiftec` and `xswiftecInverse`.
struct Secp256k1FieldElement: Equatable, Sendable {
    /// Little-endian limbs of the reduced value.
    private(set) var limbs: [UInt64]

    /// p as limbs.
    private static let modulus: [UInt64] = [
        0xFFFF_FFFE_FFFF_FC2F, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF,
    ]
    /// 2²⁵⁶ − p = 2³² + 977, the fold constant for reduction.
    private static let fold: UInt64 = 0x1_0000_03D1

    static let zero = Secp256k1FieldElement(limbs: [0, 0, 0, 0])
    static let one = Secp256k1FieldElement(limbs: [1, 0, 0, 0])
    static let seven = Secp256k1FieldElement(limbs: [7, 0, 0, 0])

    private init(limbs: [UInt64]) {
        self.limbs = limbs
    }

    init(_ small: UInt64) {
        limbs = [small, 0, 0, 0]
    }

    /// A 32-byte big-endian integer, reduced mod p (values at or above p are
    /// accepted and folded, as libsecp256k1's `fe_set_b32_mod` does).
    init(bytes: Data) {
        precondition(bytes.count == 32, "field elements are 32 bytes")
        var limbs = [UInt64](repeating: 0, count: 4)
        for (offset, byte) in bytes.enumerated() {
            let limb = 3 - offset / 8
            limbs[limb] = limbs[limb] << 8 | UInt64(byte)
        }
        self.limbs = Self.reduceOnce(limbs)
    }

    /// Big-endian 32 bytes.
    var bytes: Data {
        var data = Data(capacity: 32)
        for limb in limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift)))
            }
        }
        return data
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }
    var isOdd: Bool { limbs[0] & 1 == 1 }

    // MARK: - Limb helpers

    /// Subtracts p once when the value is at or above it. Inputs are below
    /// 2²⁵⁶, so a single subtraction fully reduces.
    private static func reduceOnce(_ value: [UInt64]) -> [UInt64] {
        guard !lessThan(value, modulus) else { return value }
        return subtractLimbs(value, modulus).limbs
    }

    private static func lessThan(_ lhs: [UInt64], _ rhs: [UInt64]) -> Bool {
        for index in (0 ..< 4).reversed() where lhs[index] != rhs[index] {
            return lhs[index] < rhs[index]
        }
        return false
    }

    private static func addLimbs(_ lhs: [UInt64], _ rhs: [UInt64]) -> (limbs: [UInt64], carry: UInt64) {
        var result = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for index in 0 ..< 4 {
            let (partial, overflow1) = lhs[index].addingReportingOverflow(rhs[index])
            let (sum, overflow2) = partial.addingReportingOverflow(carry)
            result[index] = sum
            carry = (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
        }
        return (result, carry)
    }

    private static func subtractLimbs(_ lhs: [UInt64], _ rhs: [UInt64]) -> (limbs: [UInt64], borrow: UInt64) {
        var result = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for index in 0 ..< 4 {
            let (partial, underflow1) = lhs[index].subtractingReportingOverflow(rhs[index])
            let (difference, underflow2) = partial.subtractingReportingOverflow(borrow)
            result[index] = difference
            borrow = (underflow1 ? 1 : 0) + (underflow2 ? 1 : 0)
        }
        return (result, borrow)
    }

    /// `limbs × small`, as five limbs.
    private static func multiplySmall(_ limbs: [UInt64], _ small: UInt64) -> [UInt64] {
        var result = [UInt64](repeating: 0, count: 5)
        var carry: UInt64 = 0
        for index in 0 ..< 4 {
            let (high, low) = limbs[index].multipliedFullWidth(by: small)
            let (sum, overflow) = low.addingReportingOverflow(carry)
            result[index] = sum
            carry = high + (overflow ? 1 : 0)
        }
        result[4] = carry
        return result
    }

    /// Reduces an eight-limb product mod p by folding the high half twice:
    /// 2²⁵⁶ ≡ 2³² + 977.
    private static func reduceProduct(_ product: [UInt64]) -> [UInt64] {
        let low = Array(product[0 ..< 4])
        let high = Array(product[4 ..< 8])
        // low + high × fold: at most 2²⁹⁰, five limbs.
        let folded = multiplySmall(high, fold)
        let (sum, carry) = addLimbs(low, Array(folded[0 ..< 4]))
        let top = folded[4] + carry // below 2³⁴
        // Fold the fifth limb once more: top × fold is below 2⁶⁸.
        let (high2, low2) = top.multipliedFullWidth(by: fold)
        let (sum2, carry2) = addLimbs(sum, [low2, high2, 0, 0])
        var result = sum2
        if carry2 != 0 {
            // The wrapped value is tiny, so adding the fold cannot overflow.
            result = addLimbs(result, [fold, 0, 0, 0]).limbs
        }
        return reduceOnce(result)
    }

    // MARK: - Field operations

    static func + (lhs: Self, rhs: Self) -> Self {
        let (sum, carry) = addLimbs(lhs.limbs, rhs.limbs)
        if carry != 0 {
            // sum = 2²⁵⁶ + wrapped; subtracting p is adding the fold.
            return Self(limbs: reduceOnce(addLimbs(sum, [fold, 0, 0, 0]).limbs))
        }
        return Self(limbs: reduceOnce(sum))
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        let (difference, borrow) = subtractLimbs(lhs.limbs, rhs.limbs)
        if borrow != 0 {
            return Self(limbs: addLimbs(difference, modulus).limbs)
        }
        return Self(limbs: difference)
    }

    static prefix func - (value: Self) -> Self {
        zero - value
    }

    static func * (lhs: Self, rhs: Self) -> Self {
        var product = [UInt64](repeating: 0, count: 8)
        for i in 0 ..< 4 {
            var carry: UInt64 = 0
            for j in 0 ..< 4 {
                let (high, low) = lhs.limbs[i].multipliedFullWidth(by: rhs.limbs[j])
                let (sum1, overflow1) = product[i + j].addingReportingOverflow(low)
                let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
                product[i + j] = sum2
                carry = high + (overflow1 ? 1 : 0) + (overflow2 ? 1 : 0)
            }
            product[i + 4] = carry
        }
        return Self(limbs: reduceProduct(product))
    }

    func squared() -> Self { self * self }

    /// `self ^ exponent`, exponent given as 32 big-endian bytes.
    func power(_ exponent: Data) -> Self {
        var result = Self.one
        for byte in exponent {
            for bit in stride(from: 7, through: 0, by: -1) {
                result = result.squared()
                if (byte >> UInt8(bit)) & 1 == 1 { result = result * self }
            }
        }
        return result
    }

    /// Multiplicative inverse by Fermat (p − 2); zero inverts to zero.
    func inverse() -> Self {
        power(Self.exponentPMinus2)
    }

    static func / (lhs: Self, rhs: Self) -> Self {
        lhs * rhs.inverse()
    }

    /// A square root when one exists: p ≡ 3 (mod 4), so `self^((p+1)/4)`
    /// is a root exactly when `self` is a square. Which root comes back is
    /// fixed by that formula (BIP 324's reference uses the same one).
    func squareRoot() -> Self? {
        let candidate = power(Self.exponentSqrt)
        return candidate.squared() == self ? candidate : nil
    }

    var isSquare: Bool { squareRoot() != nil }

    /// p − 2, big-endian.
    private static let exponentPMinus2 = Data(hex: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2d")!
    /// (p + 1) / 4, big-endian.
    private static let exponentSqrt = Data(hex: "3fffffffffffffffffffffffffffffffffffffffffffffffffffffffbfffff0c")!
}
