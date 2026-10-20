import Foundation

/// Group arithmetic for protocols built on top of keys and signatures: BIP327
/// MuSig2 aggregates keys and nonces, so it needs scalars that may be zero,
/// point sums that may be infinity, and arbitrary points times scalars.
/// Variable-time like the rest of the module; see the README.
extension Secp256k1 {
    /// An integer modulo the group order n, zero included (unlike
    /// `PrivateKey`, which refuses zero).
    public struct ScalarModN: Equatable, Sendable {
        let value: Scalar

        public static let zero = ScalarModN(value: .zero)
        public static let one = ScalarModN(value: .one)

        init(value: Scalar) {
            self.value = value
        }

        /// Exactly 32 big-endian bytes below n; zero is allowed.
        public init(_ bytes: Data) throws {
            guard let scalar = Scalar(bigEndian: bytes) else { throw Secp256k1Error.invalidScalar }
            value = scalar
        }

        /// Exactly 32 bytes, such as a hash output, reduced modulo n.
        public init(reducing bytes: Data) throws {
            guard let integer = Integer256(bigEndian: bytes) else { throw Secp256k1Error.invalidScalar }
            value = Scalar(reducing: integer)
        }

        /// The 32-byte big-endian value.
        public var bytes: Data { value.bigEndian }
        public var isZero: Bool { value.isZero }

        /// −s mod n; zero stays zero.
        public var negated: ScalarModN { ScalarModN(value: value.negated()) }

        public static func + (lhs: ScalarModN, rhs: ScalarModN) -> ScalarModN {
            ScalarModN(value: lhs.value + rhs.value)
        }

        public static func * (lhs: ScalarModN, rhs: ScalarModN) -> ScalarModN {
            ScalarModN(value: lhs.value.multiplied(by: rhs.value))
        }
    }
}

extension Secp256k1.PublicKey {
    /// −P, the same x with the other y.
    public var negated: Secp256k1.PublicKey { Secp256k1.PublicKey(point: point.negated) }

    /// P + Q, or nil when the sum is the point at infinity (Q = −P).
    public func adding(_ other: Secp256k1.PublicKey) -> Secp256k1.PublicKey? {
        JacobianPoint(point).adding(other.point).affine().map(Secp256k1.PublicKey.init(point:))
    }

    /// k·P, or nil for k = 0.
    public func multiplied(by scalar: Secp256k1.ScalarModN) -> Secp256k1.PublicKey? {
        Curve.multiply(point, by: scalar.value).affine().map(Secp256k1.PublicKey.init(point:))
    }

    /// k·G, or nil for k = 0.
    public static func generatorMultiple(_ scalar: Secp256k1.ScalarModN) -> Secp256k1.PublicKey? {
        Curve.multiplyGenerator(scalar.value).affine().map(Secp256k1.PublicKey.init(point:))
    }

    /// The sum of the points, or nil for an empty list or a sum at infinity.
    public static func sum(_ points: [Secp256k1.PublicKey]) -> Secp256k1.PublicKey? {
        var total = JacobianPoint.infinity
        for key in points { total = total.adding(key.point) }
        return total.affine().map(Secp256k1.PublicKey.init(point:))
    }
}
