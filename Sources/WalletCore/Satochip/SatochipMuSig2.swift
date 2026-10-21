import CryptoKit
import Foundation

/// A Satochip card (applet protocol 0.16) as a BIP327 cosigner. The card runs
/// only NonceGen and Sign and never sees the message: the host hands it the
/// session values ready-made. With 2FA enabled the card signs only when those
/// values carry an approval made with a key the card holds, so a separate
/// checker that recomputes them from the PSBT decides what the card signs.
/// See docs/satochip-musig2.md.
public enum Satochip {
    public enum SatochipError: Error, Equatable {
        /// A signing context is exactly 66 bytes.
        case invalidSigningContext
        /// The 2FA secret is exactly 20 bytes (an HMAC-SHA1 key).
        case invalidTwoFactorKey
    }
}

extension Satochip {
    /// The Musig2SignHash (0x7F) OP_FINALIZE data:
    /// b ‖ e·a mod n ‖ R_odd ‖ ggacc_is_one, the flags 0x00 or 0x01 only.
    public static func signingContext(_ parameters: MuSig.PartialSignParameters) -> Data {
        var context = Data(parameters.nonceCoefficient)
        context.append(parameters.challengeTimesKeyCoefficient)
        context.append(parameters.negateNonces ? 0x01 : 0x00)
        context.append(parameters.negateSecretKey ? 0x00 : 0x01)
        return context
    }

    /// The signing context of the card's participant key in `session`.
    public static func signingContext(publicKey: Data, session: MuSig.Session) throws -> Data {
        signingContext(try MuSig.partialSignParameters(publicKey: publicKey, session: session))
    }

    /// The flag that announces an HMAC-SHA1 challenge-response approval.
    public static let twoFactorFlag = Data([0x80, 0x00])

    /// The 22-byte 2FA approval the card requires after the context:
    /// 0x8000 ‖ HMAC-SHA1(key, SHA-256(context) ‖ 0xEE × 32). The 0xEE padding
    /// separates MuSig2 approvals from the card's other 2FA operations.
    public static func twoFactorApproval(signingContext: Data, key: Data) throws -> Data {
        guard signingContext.count == 66 else { throw SatochipError.invalidSigningContext }
        guard key.count == 20 else { throw SatochipError.invalidTwoFactorKey }
        var message = Data(SHA256.hash(data: signingContext))
        message.append(Data(repeating: 0xEE, count: 32))
        let code = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return twoFactorFlag + Data(code)
    }
}
