import Foundation

/// An element of the secp256k1 base field GF(p), p = 2^256 − 2^32 − 977,
/// stored fully reduced. Every operation is variable-time: timing depends on
/// the operands, so the field must only ever see public data or data the
/// caller has accepted may leak through timing.
struct FieldElement: Equatable, Hashable, Sendable {
    /// The canonical value, always below `modulus`.
    let value: Integer256

    static let modulus = Integer256(l0: 0xFFFF_FFFE_FFFF_FC2F, l1: .max, l2: .max, l3: .max)

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

    /// Any 256-bit integer, reduced modulo p.
    init(reducing integer: Integer256) {
        value = GeneratedField.reduce(integer)
    }

    var bigEndian: Data { value.bigEndian }
    var isZero: Bool { value.isZero }
    var isOdd: Bool { value.isOdd }

    // MARK: - Ring operations
    //
    // The bodies are in Generated/GeneratedField.swift, printed from programs
    // that Tools/Proofs proves return the canonical residue.

    static func + (lhs: FieldElement, rhs: FieldElement) -> FieldElement {
        FieldElement(canonical: GeneratedField.add(lhs.value, rhs.value))
    }

    static func - (lhs: FieldElement, rhs: FieldElement) -> FieldElement {
        FieldElement(canonical: GeneratedField.subtract(lhs.value, rhs.value))
    }

    static func * (lhs: FieldElement, rhs: FieldElement) -> FieldElement {
        FieldElement(canonical: GeneratedField.multiply(lhs.value, rhs.value))
    }

    func squared() -> FieldElement {
        FieldElement(canonical: GeneratedField.square(value))
    }

    func negated() -> FieldElement {
        FieldElement(canonical: GeneratedField.negate(value))
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

    /// The multiplicative inverse by Fermat's little theorem: a^(p−2), by a
    /// fixed addition chain (255 squarings, 15 multiplications) whose exponent
    /// Tools/Proofs proves. Zero maps to zero.
    func inverse() -> FieldElement { GeneratedCurve.invert(self) }

    /// A square root, or nil for a non-residue: a^((p+1)/4) by a fixed
    /// addition chain (p ≡ 3 mod 4), kept only when it squares back. Either
    /// root may be returned; callers choose a parity by negating.
    func squareRoot() -> FieldElement? {
        let root = GeneratedCurve.squareRootCandidate(self)
        return root.squared() == self ? root : nil
    }
}
