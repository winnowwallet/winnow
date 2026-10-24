import Foundation

/// Why a native secp256k1 operation refused its input. Every public
/// operation reports malformed input this way, or with `nil`/`false`, and
/// never traps: some callers feed it bytes taken from the network.
public enum Secp256k1Error: Error, Equatable, Sendable {
    /// A private key that is not 32 bytes, is zero, or is not below the group order.
    case invalidPrivateKey
    /// A public key with the wrong length or prefix, an x coordinate of p or
    /// more, or an x with no point on the curve.
    case invalidPublicKey
    /// A tweak that is not 32 bytes or is not below the group order.
    case invalidTweak
    /// A scalar that is not 32 bytes or is not below the group order.
    case invalidScalar
    /// A tweak that produced the zero scalar or the point at infinity.
    case invalidResult
    /// Auxiliary randomness for signing that is not exactly 32 bytes.
    case invalidAuxiliaryRand
    /// The derived nonce was zero, or the fresh signature failed its own
    /// verification. Both have negligible probability for correct code.
    case signingFailed
}
