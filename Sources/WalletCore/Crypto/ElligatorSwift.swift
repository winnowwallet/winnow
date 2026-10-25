import Foundation

/// ElligatorSwift (BIP 324): a 64-byte encoding of a secp256k1 x coordinate
/// that is indistinguishable from uniformly random bytes. BIP 77 uses it to
/// put HPKE ephemeral keys on the wire so a directory cannot tell key
/// material from ciphertext. The y parity rides on t, as libsecp256k1 does:
/// decoding lifts x with y's parity equal to t's, and encoding negates t
/// when the parities differ — the HPKE receiver reconstructs the sender's
/// exact point from these 64 bytes, not just its x.
///
/// `xswiftec` and `xswiftecInverse` follow BIP 324's `reference.py` line by
/// line. Exercised by `ElligatorSwiftTests` with the BIP's
/// `ellswift_decode_test_vectors.csv` and `xswiftec_inv_test_vectors.csv`.
public enum ElligatorSwift {
    public enum Failure: Error, Equatable {
        case invalidLength
        case invalidPublicKey
        case encodingFailed
    }

    typealias FE = Secp256k1FieldElement

    /// √(−3) mod p, the constant BIP 324 calls MINUS_3_SQRT.
    static let minus3Sqrt = FE(bytes: Data(hex: "0a2d2ba93507f1df233770c2a797962cc61f6d15da14ecd47d8d27ae1cd5f852")!)

    // MARK: - Decoding

    /// Decodes (u, t) to an x coordinate on the curve. Never fails: every
    /// 64-byte string maps to some valid x.
    static func xswiftec(_ uIn: FE, _ tIn: FE) -> FE {
        var u = uIn
        var t = tIn
        if u.isZero { u = .one }
        if t.isZero { t = .one }
        let u3 = u * u * u
        if (u3 + t * t + .seven).isZero { t = t + t }
        let x = (u3 + .seven - t * t) / (t + t)
        let y = (x + t) / (minus3Sqrt * u)
        let candidates = [u + (y * y) * FE(4), (-x / y - u) / FE(2), (x / y - u) / FE(2)]
        for candidate in candidates where isValidX(candidate) {
            return candidate
        }
        preconditionFailure("xswiftec always yields a valid x")
    }

    static func isValidX(_ x: FE) -> Bool {
        (x * x * x + .seven).isSquare
    }

    /// The 33-byte compressed public key encoded by `encoded` (64 bytes:
    /// u ‖ t, big-endian, values at or above p reduced).
    public static func decode(_ encoded: Data) throws -> Data {
        guard encoded.count == 64 else { throw Failure.invalidLength }
        let u = FE(bytes: encoded.prefix(32))
        let t = FE(bytes: encoded.suffix(32))
        let x = xswiftec(u, t)
        // libsecp256k1: the lifted point's y has t's parity (after reduction).
        return Data([t.isOdd ? 0x03 : 0x02]) + x.bytes
    }

    // MARK: - Encoding

    /// One of up to eight t values with xswiftec(u, t) = x, by `case`
    /// (0 ..< 8), or nil when that branch has none.
    static func xswiftecInverse(_ x: FE, _ u: FE, _ branch: Int) -> FE? {
        let v: FE
        let s: FE
        let u3Plus7 = u * u * u + .seven
        if branch & 2 == 0 {
            if isValidX(-x - u) { return nil }
            v = x
            s = -u3Plus7 / (u * u + u * v + v * v)
        } else {
            s = x - u
            if s.isZero { return nil }
            guard let r = (-s * (u3Plus7 * FE(4) + s * u * u * FE(3))).squareRoot() else { return nil }
            if branch & 1 == 1, r.isZero { return nil }
            v = (-u + r / s) / FE(2)
        }
        guard let w = s.squareRoot() else { return nil }
        return applyBranch(branch, w: w, u: u, v: v)
    }

    private static func applyBranch(_ branch: Int, w: FE, u: FE, v: FE) -> FE {
        let half = FE(2).inverse()
        let minus = u * (FE.one - minus3Sqrt) * half + v
        let plus = u * (FE.one + minus3Sqrt) * half + v
        switch branch & 5 {
        case 0: return -w * minus
        case 1: return w * plus
        case 4: return w * minus
        default: return -w * plus
        }
    }

    /// Encodes a compressed public key as 64 uniformly random-looking bytes.
    /// Random u and branch until an inverse exists (a few tries on average);
    /// t takes y's parity so decoding recovers the same point. `randomBytes`
    /// supplies 33 bytes per try: 32 for u and one whose low three bits pick
    /// the branch, independent of u.
    public static func encode(publicKey: Data,
                              randomBytes: () -> Data = { Self.random(count: 33) }) throws -> Data {
        guard publicKey.count == 33 else { throw Failure.invalidLength }
        let prefix = publicKey[publicKey.startIndex]
        guard prefix == 0x02 || prefix == 0x03 else { throw Failure.invalidPublicKey }
        let x = FE(bytes: publicKey.dropFirst())
        guard isValidX(x) else { throw Failure.invalidPublicKey }
        let yOdd = prefix == 0x03
        for _ in 0 ..< 1_000 {
            let entropy = randomBytes()
            guard entropy.count == 33 else { throw Failure.encodingFailed }
            let u = FE(bytes: entropy.prefix(32))
            let branch = Int(entropy[entropy.startIndex + 32] & 7)
            guard !u.isZero, var t = xswiftecInverse(x, u, branch), !t.isZero else { continue }
            if t.isOdd != yOdd { t = -t }
            return u.bytes + t.bytes
        }
        throw Failure.encodingFailed
    }

    public static func random(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = Data(count: count)
        for index in 0 ..< count { bytes[index] = UInt8.random(in: 0 ... 255, using: &generator) }
        return bytes
    }
}
