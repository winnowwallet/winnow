import Foundation

/// An integer modulo the secp256k1 group order n, stored fully reduced.
/// Private keys, nonces and tweaks are scalars. Every operation is
/// variable-time, so timing depends on the secret values it processes.
struct Scalar: Equatable, Hashable, Sendable {
    /// The canonical value, always below `order`.
    let value: Integer256

    static let order = Integer256(l0: 0xBFD2_5E8C_D036_4141, l1: 0xBAAE_DCE6_AF48_A03B,
                                  l2: 0xFFFF_FFFF_FFFF_FFFE, l3: .max)

    static let zero = Scalar(canonical: .zero)
    static let one = Scalar(canonical: .one)

    private init(canonical: Integer256) {
        value = canonical
    }

    /// Exactly 32 big-endian bytes encoding an integer below n, zero
    /// included; nil for any other length or a value of n or more.
    init?(bigEndian: Data) {
        guard let parsed = Integer256(bigEndian: bigEndian), parsed < Self.order else { return nil }
        value = parsed
    }

    /// Any 256-bit integer, reduced modulo n; this is how BIP340 reduces
    /// hash outputs.
    init(reducing integer: Integer256) {
        value = GeneratedScalar.reduce(integer)
    }

    var bigEndian: Data { value.bigEndian }
    var isZero: Bool { value.isZero }

    /// Bit `index` of the canonical value, 0 being the least significant.
    func bit(_ index: Int) -> Bool { value.bit(index) }

    // The bodies are in Generated/GeneratedScalar.swift, printed from
    // programs that Tools/Proofs proves return the canonical residue.

    static func + (lhs: Scalar, rhs: Scalar) -> Scalar {
        Scalar(canonical: GeneratedScalar.add(lhs.value, rhs.value))
    }

    func negated() -> Scalar {
        Scalar(canonical: GeneratedScalar.negate(value))
    }

    static func - (lhs: Scalar, rhs: Scalar) -> Scalar {
        Scalar(canonical: GeneratedScalar.subtract(lhs.value, rhs.value))
    }

    /// The product modulo n: the full 512-bit product, then a reduction.
    func multiplied(by other: Scalar) -> Scalar {
        Scalar(canonical: GeneratedScalar.multiply(value, other.value))
    }
}
