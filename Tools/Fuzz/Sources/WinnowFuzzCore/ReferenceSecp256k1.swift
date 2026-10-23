import CryptoKit
import Foundation

/// A second secp256k1, written to share no code and no algorithm with
/// NativeSecp256k1, so the fuzz target can require byte-for-byte agreement.
/// The native module works in 64-bit limbs, reduces with p's special form,
/// inverts by Fermat, uses Jacobian coordinates, a fixed-base table and
/// left-to-right double-and-add. This file uses 32-bit limbs, Montgomery
/// multiplication for any odd modulus, the binary extended Euclidean
/// algorithm, affine chord-and-tangent formulas, right-to-left
/// double-and-add, and BIP340 written from the specification's pseudocode.
/// Variable-time and slow; fuzzing and tests only.
enum ReferenceSecp256k1 {
    // MARK: - Unsigned integers below 2^512

    /// Sixteen little-endian 32-bit limbs. Values reduced by a `Modulus`
    /// stay below 2^256, in the low eight.
    struct Number: Equatable, Comparable {
        var limbs: SIMD16<UInt32>

        static let zero = Number(limbs: .zero)
        static let one = Number(1)

        init(limbs: SIMD16<UInt32>) {
            self.limbs = limbs
        }

        init(_ value: UInt32) {
            var limbs = SIMD16<UInt32>.zero
            limbs[0] = value
            self.init(limbs: limbs)
        }

        /// Up to 64 big-endian bytes.
        init(bigEndian bytes: Data) {
            var limbs = SIMD16<UInt32>.zero
            for (offset, byte) in bytes.reversed().enumerated() where offset < 64 {
                limbs[offset / 4] |= UInt32(byte) << UInt32(8 * (offset % 4))
            }
            self.init(limbs: limbs)
        }

        init(hex: String) {
            self.init(bigEndian: Self.hexBytes(hex))
        }

        /// Bytes from an even-length hex string written in this file or a vector file.
        static func hexBytes(_ hex: String) -> Data {
            var bytes = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(UInt8(hex[index ..< next], radix: 16)!)
                index = next
            }
            return bytes
        }

        /// The low 256 bits as 32 big-endian bytes.
        var bigEndian32: Data {
            var bytes = Data()
            for index in stride(from: 31, through: 0, by: -1) {
                bytes.append(UInt8(truncatingIfNeeded: limbs[index / 4] >> UInt32(8 * (index % 4))))
            }
            return bytes
        }

        var isZero: Bool { limbs == .zero }
        var isEven: Bool { limbs[0] & 1 == 0 }

        func bit(_ index: Int) -> Bool { (limbs[index / 32] >> UInt32(index % 32)) & 1 == 1 }

        /// One more than the index of the highest set bit; 0 for zero.
        var bitLength: Int {
            for index in stride(from: 15, through: 0, by: -1) where limbs[index] != 0 {
                return 32 * index + 32 - limbs[index].leadingZeroBitCount
            }
            return 0
        }

        static func < (lhs: Number, rhs: Number) -> Bool {
            for index in stride(from: 15, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
                return lhs.limbs[index] < rhs.limbs[index]
            }
            return false
        }

        /// The sum modulo 2^512.
        static func + (lhs: Number, rhs: Number) -> Number {
            var result = zero
            var carry: UInt64 = 0
            for index in 0 ..< 16 {
                let sum = UInt64(lhs.limbs[index]) + UInt64(rhs.limbs[index]) + carry
                result.limbs[index] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            return result
        }

        /// Requires lhs ≥ rhs.
        static func - (lhs: Number, rhs: Number) -> Number {
            var result = zero
            var borrow: UInt64 = 0
            for index in 0 ..< 16 {
                let difference = (UInt64(lhs.limbs[index]) &- UInt64(rhs.limbs[index])) &- borrow
                result.limbs[index] = UInt32(truncatingIfNeeded: difference)
                borrow = difference >> 63
            }
            return result
        }

        var halved: Number {
            var result = Number.zero
            for index in 0 ..< 16 {
                let high = index < 15 ? limbs[index + 1] << 31 : 0
                result.limbs[index] = (limbs[index] >> 1) | high
            }
            return result
        }

        /// The remainder by binary long division, one bit at a time. Slow;
        /// used only to set up the Montgomery constants and to reduce hashes.
        func remainder(_ modulus: Number) -> Number {
            var remainder = Number.zero
            for index in stride(from: bitLength - 1, through: 0, by: -1) {
                remainder = remainder + remainder
                if bit(index) { remainder.limbs[0] |= 1 }
                if !(remainder < modulus) { remainder = remainder - modulus }
            }
            return remainder
        }
    }

    // MARK: - Arithmetic modulo an odd 256-bit number

    struct Modulus {
        let value: Number
        /// −value⁻¹ mod 2^32, for Montgomery reduction.
        let negatedInverse: UInt32
        /// 2^512 mod value, to leave Montgomery form after a product.
        let rSquared: Number

        init(hex: String) {
            value = Number(hex: hex)
            // Newton's iteration doubles the correct low bits each round: 1, 2, 4, ..., 32.
            var inverse: UInt32 = 1
            for _ in 0 ..< 5 { inverse = inverse &* (2 &- value.limbs[0] &* inverse) }
            negatedInverse = 0 &- inverse
            // 2^256 mod value is 2^256 − value, since value > 2^255.
            let r = Number.zero - value
            var rLow = Number.zero
            for index in 0 ..< 8 { rLow.limbs[index] = r.limbs[index] }
            rSquared = Self.schoolbook(rLow, rLow).remainder(value)
        }

        /// The full product of two numbers below 2^256.
        static func schoolbook(_ lhs: Number, _ rhs: Number) -> Number {
            var result = SIMD16<UInt64>.zero
            for i in 0 ..< 8 {
                var carry: UInt64 = 0
                for j in 0 ..< 8 {
                    let product = UInt64(lhs.limbs[i]) * UInt64(rhs.limbs[j]) + result[i + j] + carry
                    result[i + j] = product & 0xFFFF_FFFF
                    carry = product >> 32
                }
                result[i + 8] += carry
            }
            return Number(limbs: SIMD16<UInt32>(truncatingIfNeeded: result))
        }

        /// a·b·2^−256 mod value, for a, b below value (CIOS Montgomery multiplication).
        func montgomery(_ a: Number, _ b: Number) -> Number {
            var t = SIMD16<UInt64>.zero // t[0...9] used
            for i in 0 ..< 8 {
                var carry: UInt64 = 0
                for j in 0 ..< 8 {
                    let sum = t[j] + UInt64(a.limbs[j]) * UInt64(b.limbs[i]) + carry
                    t[j] = sum & 0xFFFF_FFFF
                    carry = sum >> 32
                }
                let top = t[8] + carry
                t[8] = top & 0xFFFF_FFFF
                t[9] = top >> 32
                let m = UInt64(UInt32(truncatingIfNeeded: t[0]) &* negatedInverse)
                carry = (t[0] + m * UInt64(value.limbs[0])) >> 32
                for j in 1 ..< 8 {
                    let sum = t[j] + m * UInt64(value.limbs[j]) + carry
                    t[j - 1] = sum & 0xFFFF_FFFF
                    carry = sum >> 32
                }
                let last = t[8] + carry
                t[7] = last & 0xFFFF_FFFF
                t[8] = t[9] + (last >> 32)
                t[9] = 0
            }
            var result = Number.zero
            for index in 0 ..< 9 { result.limbs[index] = UInt32(truncatingIfNeeded: t[index]) }
            return result < value ? result : result - value
        }

        func reduce(_ a: Number) -> Number { a.remainder(value) }
        func add(_ a: Number, _ b: Number) -> Number {
            let sum = a + b
            return sum < value ? sum : sum - value
        }
        func subtract(_ a: Number, _ b: Number) -> Number { a < b ? a + value - b : a - b }
        func negate(_ a: Number) -> Number { subtract(.zero, a) }
        /// (a·b·2^−256)·2^512·2^−256 = a·b.
        func multiply(_ a: Number, _ b: Number) -> Number { montgomery(montgomery(a, b), rSquared) }

        /// Right-to-left square-and-multiply.
        func power(_ base: Number, _ exponent: Number) -> Number {
            var result = Number.one
            var square = base
            for index in 0 ..< exponent.bitLength {
                if exponent.bit(index) { result = multiply(result, square) }
                square = multiply(square, square)
            }
            return result
        }

        /// The inverse of a nonzero a below the odd prime `value`, by the
        /// binary extended Euclidean algorithm (Hankerson, Menezes and
        /// Vanstone, Guide to Elliptic Curve Cryptography, algorithm 2.22).
        func inverse(_ a: Number) -> Number {
            var u = a, v = value, x1 = Number.one, x2 = Number.zero
            guard !u.isZero else { return .zero }
            while u != .one, v != .one {
                while u.isEven {
                    u = u.halved
                    x1 = x1.isEven ? x1.halved : (x1 + value).halved
                }
                while v.isEven {
                    v = v.halved
                    x2 = x2.isEven ? x2.halved : (x2 + value).halved
                }
                if u < v {
                    v = v - u
                    x2 = subtract(x2, x1)
                } else {
                    u = u - v
                    x1 = subtract(x1, x2)
                }
            }
            return u == .one ? x1 : x2
        }
    }

    static let p = Modulus(hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F")
    static let n = Modulus(hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")

    // MARK: - Points

    struct Point: Equatable {
        let x: Number
        let y: Number
        var compressed: Data { Data([y.isEven ? 0x02 : 0x03]) + x.bigEndian32 }
    }

    /// The generator from SEC 2, section 2.4.1.
    static let generator = Point(
        x: Number(hex: "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"),
        y: Number(hex: "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8"))

    /// P + Q by the chord-and-tangent rule; nil is the point at infinity.
    static func add(_ lhs: Point?, _ rhs: Point?) -> Point? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        let slope: Number
        if lhs.x == rhs.x {
            guard lhs.y == rhs.y, !lhs.y.isZero else { return nil }
            // λ = 3x² / 2y
            let numerator = p.multiply(Number(3), p.multiply(lhs.x, lhs.x))
            slope = p.multiply(numerator, p.inverse(p.add(lhs.y, lhs.y)))
        } else {
            // λ = (y2 − y1) / (x2 − x1)
            slope = p.multiply(p.subtract(rhs.y, lhs.y), p.inverse(p.subtract(rhs.x, lhs.x)))
        }
        let x = p.subtract(p.subtract(p.multiply(slope, slope), lhs.x), rhs.x)
        let y = p.subtract(p.multiply(slope, p.subtract(lhs.x, x)), lhs.y)
        return Point(x: x, y: y)
    }

    static func negate(_ point: Point) -> Point { Point(x: point.x, y: p.negate(point.y)) }

    /// k·P by right-to-left double-and-add.
    static func multiply(_ point: Point?, _ k: Number) -> Point? {
        var result: Point?
        var addend = point
        for index in 0 ..< k.bitLength {
            if k.bit(index) { result = add(result, addend) }
            addend = add(addend, addend)
        }
        return result
    }

    /// BIP340 lift_x: the even-y point with this x, or nil.
    static func liftX(_ x: Number) -> Point? {
        guard x < p.value else { return nil }
        let c = p.add(p.multiply(x, p.multiply(x, x)), Number(7))
        let y = p.power(c, (p.value + .one).halved.halved)
        guard p.multiply(y, y) == c else { return nil }
        return Point(x: x, y: y.isEven ? y : p.negate(y))
    }

    /// A 33-byte SEC compressed point, or nil.
    static func parse(compressed bytes: Data) -> Point? {
        guard bytes.count == 33, let prefix = bytes.first, prefix == 0x02 || prefix == 0x03,
              let even = liftX(Number(bigEndian: bytes.dropFirst()))
        else { return nil }
        return prefix == 0x03 ? negate(even) : even
    }

    // MARK: - Keys and tweaks, as libsecp256k1 defines them

    /// A secret in 1...n−1, or nil.
    static func secret(_ bytes: Data) -> Number? {
        guard bytes.count == 32 else { return nil }
        let value = Number(bigEndian: bytes)
        return !value.isZero && value < n.value ? value : nil
    }

    /// A tweak in 0...n−1, or nil.
    static func tweak(_ bytes: Data) -> Number? {
        guard bytes.count == 32 else { return nil }
        let value = Number(bigEndian: bytes)
        return value < n.value ? value : nil
    }

    static func publicKey(_ secret: Number) -> Point { multiply(generator, secret)! }

    /// (d + t) mod n, nil when the tweak is out of range or the sum is zero.
    static func addingToSecret(_ secret: Number, tweak bytes: Data) -> Number? {
        guard let t = tweak(bytes) else { return nil }
        let sum = n.add(secret, t)
        return sum.isZero ? nil : sum
    }

    /// P + t·G, nil when the tweak is out of range or the sum is infinity.
    static func addingToPoint(_ point: Point, tweak bytes: Data) -> Point? {
        guard let t = tweak(bytes) else { return nil }
        return add(point, multiply(generator, t))
    }

    /// The secret whose public key is the even-y form of this one's.
    static func evenSecret(_ secret: Number) -> Number {
        publicKey(secret).y.isEven ? secret : n.negate(secret)
    }

    // MARK: - BIP340

    static func taggedHash(_ tag: String, _ message: Data) -> Data {
        let tagHash = Data(SHA256.hash(data: Data(tag.utf8)))
        return Data(SHA256.hash(data: tagHash + tagHash + message))
    }

    static func sign(message: Data, secret: Number, auxiliaryRand: Data) -> Data? {
        let point = publicKey(secret)
        let d = point.y.isEven ? secret : n.negate(secret)
        let mask = taggedHash("BIP0340/aux", auxiliaryRand)
        let t = Data(zip(d.bigEndian32, mask).map { $0 ^ $1 })
        let rand = taggedHash("BIP0340/nonce", t + point.x.bigEndian32 + message)
        let k0 = n.reduce(Number(bigEndian: rand))
        guard !k0.isZero, let r = multiply(generator, k0) else { return nil }
        let k = r.y.isEven ? k0 : n.negate(k0)
        let e = challenge(r.x, point.x, message)
        return r.x.bigEndian32 + n.add(k, n.multiply(e, d)).bigEndian32
    }

    static func verify(signature: Data, message: Data, publicKey x: Data) -> Bool {
        guard signature.count == 64, x.count == 32, let point = liftX(Number(bigEndian: x)) else { return false }
        let r = Number(bigEndian: signature.prefix(32))
        let s = Number(bigEndian: signature.suffix(32))
        guard r < p.value, s < n.value else { return false }
        let e = challenge(r, point.x, message)
        guard let result = add(multiply(generator, s), multiply(point, e).map(negate)) else { return false }
        return result.y.isEven && result.x == r
    }

    /// A signature that passes every BIP340 check but the parity of R: the
    /// nonce is not negated when R has odd y. Nil when R happens to be even.
    static func oddNonceSignature(message: Data, secret: Number, nonce: Number) -> Data? {
        let point = publicKey(secret)
        let d = point.y.isEven ? secret : n.negate(secret)
        guard !nonce.isZero, nonce < n.value, let r = multiply(generator, nonce), !r.y.isEven else { return nil }
        let e = challenge(r.x, point.x, message)
        return r.x.bigEndian32 + n.add(nonce, n.multiply(e, d)).bigEndian32
    }

    static func challenge(_ rX: Number, _ publicX: Number, _ message: Data) -> Number {
        n.reduce(Number(bigEndian: taggedHash("BIP0340/challenge", rX.bigEndian32 + publicX.bigEndian32 + message)))
    }
}
