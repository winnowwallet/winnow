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

    /// Any 256-bit integer, reduced modulo n. Since n > 2^255, one
    /// subtraction suffices; this is how BIP340 reduces hash outputs.
    init(reducing integer: Integer256) {
        value = integer < Self.order
            ? integer
            : integer.subtractingReportingOverflow(Self.order).partialValue
    }

    var bigEndian: Data { value.bigEndian }
    var isZero: Bool { value.isZero }

    /// Bit `index` of the canonical value, 0 being the least significant.
    func bit(_ index: Int) -> Bool { value.bit(index) }

    static func + (lhs: Scalar, rhs: Scalar) -> Scalar {
        let (sum, carry) = lhs.value.addingReportingOverflow(rhs.value)
        // Both operands are below n, so the true sum is below 2n. With a
        // carry the wrapped value is below n and subtracting n (wrapping)
        // yields sum + 2^256 − n, the correct residue.
        guard carry || sum >= Self.order else { return Scalar(canonical: sum) }
        return Scalar(canonical: sum.subtractingReportingOverflow(Self.order).partialValue)
    }

    func negated() -> Scalar {
        isZero ? self : Scalar(canonical: Self.order.subtractingReportingOverflow(value).partialValue)
    }

    static func - (lhs: Scalar, rhs: Scalar) -> Scalar { lhs + rhs.negated() }

    /// The product modulo n by the binary method: 256 doublings and at most
    /// 256 additions, each a modular addition. Slow but simple; the wallet
    /// multiplies scalars once per signature.
    func multiplied(by other: Scalar) -> Scalar {
        var accumulator = Scalar.zero
        for index in stride(from: 255, through: 0, by: -1) {
            accumulator = accumulator + accumulator
            if other.bit(index) { accumulator = accumulator + self }
        }
        return accumulator
    }
}
