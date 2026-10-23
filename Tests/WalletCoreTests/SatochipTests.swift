import Foundation
import Testing
@testable import WalletCore

/// What Winnow sends a Satochip card (applet protocol 0.16) for its BIP327
/// partial signature, and the checker's 2FA approval of it.
@Suite("Satochip MuSig2")
struct SatochipTests {
    /// BIP327 sign_verify vector 0 for its signer: b, e·a, R odd, g·gacc = 1.
    static let vectorZeroParameters = MuSig.PartialSignParameters(
        nonceCoefficient: Data(hex: "f6311d2583176bb178ec12973b760a2d733544d4c72b4b3a8c260f7679f7d9c6")!,
        challengeTimesKeyCoefficient: Data(hex: "f696bb3be7fc4ee399c173813d0bddded1471cfe8acf5f729b1610d489eb3600")!,
        negateNonces: true, negateSecretKey: false)

    /// The applet test suite's 2FA secret (SatochipTest.java KEY_2FA).
    static let twoFactorKey = Data(hex: "00112233445566778899aabbccddeeff01234567")!

    @Test("the signing context is b, e·a and the two flags, as the card reads them")
    func signingContext() throws {
        let context = Satochip.signingContext(Self.vectorZeroParameters)
        #expect(context.count == 66)
        #expect(context.prefix(32) == Self.vectorZeroParameters.nonceCoefficient)
        #expect(context.dropFirst(32).prefix(32) == Self.vectorZeroParameters.challengeTimesKeyCoefficient)
        // R odd → 0x01; g·gacc = 1 → 0x01 (the card negates its key on 0x00).
        #expect(Array(context.suffix(2)) == [0x01, 0x01])

        let flipped = MuSig.PartialSignParameters(
            nonceCoefficient: Self.vectorZeroParameters.nonceCoefficient,
            challengeTimesKeyCoefficient: Self.vectorZeroParameters.challengeTimesKeyCoefficient,
            negateNonces: false, negateSecretKey: true)
        #expect(Array(Satochip.signingContext(flipped).suffix(2)) == [0x00, 0x00])
    }

    /// Expected value computed independently with Python's hmac and hashlib:
    /// HMAC-SHA1(key, SHA-256(context) ‖ 0xEE × 32), the format Satochip.java
    /// checks in Musig2SignHash and its test suite exercises.
    @Test("the 2FA approval is the flag and HMAC-SHA1 over the hashed context")
    func twoFactorApproval() throws {
        let context = Satochip.signingContext(Self.vectorZeroParameters)
        let approval = try Satochip.twoFactorApproval(signingContext: context, key: Self.twoFactorKey)
        #expect(approval == Data(hex: "8000c91e46550d3748e913b050a9ec37f38f828aa795")!)

        var changed = context
        changed[changed.startIndex + 40] ^= 0x01
        #expect(try Satochip.twoFactorApproval(signingContext: changed, key: Self.twoFactorKey) != approval)
        #expect(throws: Satochip.SatochipError.invalidSigningContext) {
            try Satochip.twoFactorApproval(signingContext: context.prefix(64), key: Self.twoFactorKey)
        }
        #expect(throws: Satochip.SatochipError.invalidTwoFactorKey) {
            try Satochip.twoFactorApproval(signingContext: context, key: Data(count: 16))
        }
    }
}
