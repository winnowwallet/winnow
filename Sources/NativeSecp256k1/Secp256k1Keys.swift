import Foundation

/// The public face of the native module: key types with the encodings,
/// validation rules and tweak semantics of libsecp256k1's `ec_seckey_*`,
/// `ec_pubkey_*`, `keypair_xonly_tweak_add` and `xonly_pubkey_tweak_add`,
/// which is what WalletCore's derivation, Taproot and signing code assume.
/// Variable-time throughout; see the module README.
public enum Secp256k1 {
    /// The generator G in 65-byte uncompressed SEC form (0x04 ‖ x ‖ y), the
    /// input of the BIP341 "nothing up my sleeve" internal key.
    public static let generatorUncompressed = Data([0x04]) + Curve.generator.x.bigEndian + Curve.generator.y.bigEndian

    /// A private key d with 0 < d < n.
    public struct PrivateKey: Equatable, Sendable {
        let scalar: Scalar

        /// Exactly 32 big-endian bytes, non-zero and below the group order.
        public init(_ bytes: Data) throws {
            guard let scalar = Scalar(bigEndian: bytes), !scalar.isZero else {
                throw Secp256k1Error.invalidPrivateKey
            }
            self.scalar = scalar
        }

        init(scalar: Scalar) {
            self.scalar = scalar
        }

        /// The 32-byte big-endian secret.
        public var bytes: Data { scalar.bigEndian }

        /// d·G. Costs one scalar multiplication each time it is read.
        public var publicKey: PublicKey {
            // A non-zero scalar below n never yields infinity.
            PublicKey(point: Curve.multiplyGenerator(scalar).affine()!)
        }

        /// The x-only key of d·G with its parity.
        public var xOnlyKey: XOnlyKey { publicKey.xOnlyKey }

        /// (d + t) mod n. A zero tweak is allowed; a tweak of n or more or a
        /// zero result is refused, as BIP32 requires.
        public func adding(_ tweak: Data) throws -> PrivateKey {
            let sum = scalar + (try Secp256k1.tweak(tweak))
            guard !sum.isZero else { throw Secp256k1Error.invalidResult }
            return PrivateKey(scalar: sum)
        }

        /// The BIP341 secret tweak: d is negated first when d·G has an odd y,
        /// so the result corresponds to `XOnlyKey.adding` on the x-only key.
        /// The result is not itself normalised to an even y.
        public func addingXOnly(_ tweak: Data) throws -> PrivateKey {
            try addingXOnly { _ in tweak }
        }

        /// `addingXOnly(_:)` with the tweak derived from this key's x-only
        /// form, as BIP341's TapTweak is; d·G is computed once and shared by
        /// the derivation and the parity check.
        public func addingXOnly(tweak derive: (XOnlyKey) throws -> Data) throws -> PrivateKey {
            let point = publicKey.point
            let t = try Secp256k1.tweak(derive(XOnlyKey(point: point)))
            let sum = (point.hasOddY ? scalar.negated() : scalar) + t
            guard !sum.isZero else { throw Secp256k1Error.invalidResult }
            return PrivateKey(scalar: sum)
        }
    }

    /// A finite curve point, exchanged in the 33-byte SEC compressed form.
    public struct PublicKey: Equatable, Sendable {
        let point: AffinePoint

        /// 33 bytes: 0x02 or 0x03 then x, with x below p and on the curve.
        public init(compressed bytes: Data) throws {
            guard let point = Curve.parse(compressed: bytes) else { throw Secp256k1Error.invalidPublicKey }
            self.point = point
        }

        /// 65 bytes: 0x04, x and y, both below p and on the curve. Smartcards
        /// exchange points this way (a Satochip's secure channel does).
        public init(uncompressed bytes: Data) throws {
            guard let point = Curve.parse(uncompressed: bytes) else { throw Secp256k1Error.invalidPublicKey }
            self.point = point
        }

        init(point: AffinePoint) {
            self.point = point
        }

        /// The 33-byte SEC compressed encoding with the real parity prefix.
        public var compressed: Data { point.compressed }

        /// The 65-byte SEC uncompressed encoding, 0x04 ‖ x ‖ y.
        public var uncompressed: Data { point.uncompressed }

        /// The x coordinate with the point's own parity.
        public var xOnlyKey: XOnlyKey { XOnlyKey(point: point) }

        /// K + t·G; refused when t is n or more or the sum is infinity.
        public func adding(_ tweak: Data) throws -> PublicKey {
            let t = try Secp256k1.tweak(tweak)
            guard let sum = Curve.multiplyGenerator(t).adding(point).affine() else {
                throw Secp256k1Error.invalidResult
            }
            return PublicKey(point: sum)
        }
    }

    /// A BIP340 x-only key: a point identified by its x coordinate, plus the
    /// parity of the y coordinate it was taken from.
    public struct XOnlyKey: Equatable, Sendable {
        let point: AffinePoint

        /// Exactly 32 bytes, x below p with a point on the curve; the even
        /// lift is taken (lift_x) and `parity` is false.
        public init(_ x: Data) throws {
            guard let field = FieldElement(bigEndian: x), let point = Curve.liftX(field) else {
                throw Secp256k1Error.invalidPublicKey
            }
            self.point = point
        }

        init(point: AffinePoint) {
            self.point = point
        }

        /// The 32-byte x coordinate.
        public var x: Data { point.x.bigEndian }

        /// True when the underlying point's y is odd.
        public var parity: Bool { point.hasOddY }

        /// Q = lift_x(x) + t·G as an x-only key carrying Q's parity, which the
        /// Taproot control block records. Refused when t is n or more or Q
        /// is infinity. The receiver's parity is ignored, as in BIP341.
        public func adding(_ tweak: Data) throws -> XOnlyKey {
            let t = try Secp256k1.tweak(tweak)
            let even = point.hasOddY ? point.negated : point
            guard let sum = Curve.multiplyGenerator(t).adding(even).affine() else {
                throw Secp256k1Error.invalidResult
            }
            return XOnlyKey(point: sum)
        }
    }

    /// A tweak: exactly 32 big-endian bytes below the group order, zero allowed.
    static func tweak(_ bytes: Data) throws -> Scalar {
        guard let scalar = Scalar(bigEndian: bytes) else { throw Secp256k1Error.invalidTweak }
        return scalar
    }
}
