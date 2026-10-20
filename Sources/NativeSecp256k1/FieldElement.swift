import Foundation

/// An element of the secp256k1 base field GF(p), p = 2^256 − 2^32 − 977,
/// stored fully reduced. Every operation is variable-time: timing depends on
/// the operands, so the field must only ever see public data or data the
/// caller has accepted may leak through timing.
struct FieldElement: Equatable, Hashable, Sendable {
    /// The canonical value, always below `modulus`.
    let value: Integer256

    static let modulus = Integer256(l0: 0xFFFF_FFFE_FFFF_FC2F, l1: .max, l2: .max, l3: .max)

    /// 2^256 − p = 2^32 + 977. Because 2^256 ≡ fold (mod p), any limb that
    /// overflows past 2^256 can be multiplied by `fold` and added back.
    private static let fold: UInt64 = 0x1_0000_03D1
    private static let foldValue = Integer256(l0: fold, l1: 0, l2: 0, l3: 0)

    /// p − 2, the Fermat inversion exponent.
    private static let inverseExponent = Integer256(l0: 0xFFFF_FFFE_FFFF_FC2D, l1: .max, l2: .max, l3: .max)

    /// (p + 1) / 4; p ≡ 3 (mod 4), so a^((p+1)/4) is a square root when one exists.
    private static let squareRootExponent = Integer256(l0: 0xFFFF_FFFF_BFFF_FF0C, l1: .max, l2: .max,
                                                    l3: 0x3FFF_FFFF_FFFF_FFFF)

    static let zero = FieldElement(canonical: .zero)
    static let one = FieldElement(canonical: .one)
    static let seven = FieldElement(canonical: Integer256(l0: 7, l1: 0, l2: 0, l3: 0))

    private init(canonical: Integer256) {
        value = canonical
    }

    /// Exactly 32 big-endian bytes encoding an integer below p; nil for any
    /// other length or a value of p or more (no reduction on input).
    init?(bigEndian: Data) {
        guard let parsed = Integer256(bigEndian: bigEndian), parsed < Self.modulus else { return nil }
        value = parsed
    }

    /// Any 256-bit integer, reduced modulo p. Since p > 2^255, one
    /// subtraction suffices.
    init(reducing integer: Integer256) {
        value = integer < Self.modulus
            ? integer
            : integer.subtractingReportingOverflow(Self.modulus).partialValue
    }

    var bigEndian: Data { value.bigEndian }
    var isZero: Bool { value.isZero }
    var isOdd: Bool { value.isOdd }

    // MARK: - Ring operations

    static func + (lhs: FieldElement, rhs: FieldElement) -> FieldElement {
        let (sum, carry) = lhs.value.addingReportingOverflow(rhs.value)
        guard carry else { return FieldElement(reducing: sum) }
        // The true sum is 2^256 + sum, below 2p, so subtracting p once gives
        // sum + (2^256 − p), which is below p and cannot overflow.
        return FieldElement(canonical: sum.addingReportingOverflow(foldValue).partialValue)
    }

    static func - (lhs: FieldElement, rhs: FieldElement) -> FieldElement {
        let (difference, borrow) = lhs.value.subtractingReportingOverflow(rhs.value)
        guard borrow else { return FieldElement(canonical: difference) }
        // difference is lhs − rhs + 2^256; adding p and dropping 2^256 is
        // subtracting (2^256 − p). lhs − rhs + p is at least 1, so no underflow.
        return FieldElement(canonical: difference.subtractingReportingOverflow(foldValue).partialValue)
    }

    static func * (lhs: FieldElement, rhs: FieldElement) -> FieldElement {
        let (high, low) = lhs.value.multipliedFullWidth(by: rhs.value)
        return reduce(high: high, low: low)
    }

    func squared() -> FieldElement {
        let (high, low) = value.squaredFullWidth()
        return Self.reduce(high: high, low: low)
    }

    func negated() -> FieldElement {
        isZero ? self : FieldElement(canonical: Self.modulus.subtractingReportingOverflow(value).partialValue)
    }

    /// `self` raised to `exponent`, by square-and-multiply from the top bit.
    func pow(_ exponent: Integer256) -> FieldElement {
        var result = FieldElement.one
        for index in stride(from: 255, through: 0, by: -1) {
            result = result.squared()
            if exponent.bit(index) { result = result * self }
        }
        return result
    }

    /// The multiplicative inverse by Fermat's little theorem. Zero maps to zero.
    func inverse() -> FieldElement { pow(Self.inverseExponent) }

    /// A square root, or nil for a non-residue. Either root may be returned;
    /// callers choose a parity by negating.
    func squareRoot() -> FieldElement? {
        let root = pow(Self.squareRootExponent)
        return root.squared() == self ? root : nil
    }

    // MARK: - Reduction

    /// Reduces a 512-bit product `high · 2^256 + low` modulo p.
    ///
    /// Step 1 replaces `high · 2^256` with `high · fold`, a 289-bit value, so
    /// the running total has one extra limb below 2^34. Step 2 folds that limb
    /// the same way; its contribution is below 2^67, so the final carry out is
    /// at most 1, and when it is set the remaining value is tiny (below 2^67)
    /// and one more `fold` lands it below p. One conditional subtraction then
    /// makes the result canonical, since everything below 2^256 is below 2p.
    private static func reduce(high: Integer256, low: Integer256) -> FieldElement {
        let (highFold, lowFold) = high.multipliedFullWidth(by: fold)
        let (total, overflow) = low.addingReportingOverflow(lowFold)
        let extra = highFold &+ (overflow ? 1 : 0)

        let (extraHigh, extraLow) = extra.multipliedFullWidth(by: fold)
        var carry: UInt64 = 0
        let r0 = Integer256.addLimb(total.l0, extraLow, &carry)
        let r1 = Integer256.addLimb(total.l1, extraHigh, &carry)
        let r2 = Integer256.addLimb(total.l2, 0, &carry)
        let r3 = Integer256.addLimb(total.l3, 0, &carry)
        var result = Integer256(l0: r0, l1: r1, l2: r2, l3: r3)
        if carry != 0 {
            result = result.addingReportingOverflow(foldValue).partialValue
        }
        return FieldElement(reducing: result)
    }
}
