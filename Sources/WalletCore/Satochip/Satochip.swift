import Foundation

/// A Satochip card (applet protocol 0.16) as a BIP327 cosigner. The card runs
/// only NonceGen and Sign and never sees the message: the host hands it the
/// session values ready-made. With 2FA enabled the card signs only when those
/// values carry an approval made with a key the card holds, so a separate
/// checker that recomputes them from the PSBT decides what the card signs.
/// See docs/satochip-musig2.md.
public enum Satochip {
    /// The Satochip applet's instance AID, "SatoChip" and 0x00.
    public static let appletID = Data([0x53, 0x61, 0x74, 0x6F, 0x43, 0x68, 0x69, 0x70, 0x00])
    /// The only protocol version this client speaks: 0.16 changed the MuSig2
    /// 2FA field, the PIN commands and the life of derived keys.
    public static let protocolVersion: (major: UInt8, minor: UInt8) = (0, 16)

    /// A card response: its data and the ISO 7816 status word.
    public struct Response: Equatable, Sendable {
        public var data: Data
        public var statusWord: UInt16

        public init(data: Data, statusWord: UInt16) {
            self.data = data
            self.statusWord = statusWord
        }

        /// Splits a raw response, data followed by the two status bytes.
        public init(raw: Data) throws {
            guard raw.count >= 2 else { throw SatochipError.malformedResponse("response without a status word") }
            data = Data(raw.dropLast(2))
            statusWord = UInt16(raw[raw.endIndex - 2]) << 8 | UInt16(raw[raw.endIndex - 1])
        }

        /// The data followed by the status word, as a card sends it.
        public var raw: Data { data + Data([UInt8(statusWord >> 8), UInt8(statusWord & 0xFF)]) }
    }

    public enum SatochipError: Error, Equatable {
        /// A signing context is exactly 66 bytes.
        case invalidSigningContext
        /// The 2FA secret is exactly 20 bytes (an HMAC-SHA1 key).
        case invalidTwoFactorKey
        /// The card runs another protocol version than 0.16.
        case unsupportedVersion(major: UInt8, minor: UInt8)
        /// The card has not been set up (no PIN yet).
        case notSetUp
        /// The card holds no seed.
        case notSeeded
        /// The card's MuSig2 feature is disabled or blocked.
        case featureDisabled
        /// The card needs the PIN for this command.
        case pinRequired
        case wrongPIN(triesLeft: Int)
        case pinBlocked
        /// The card dropped the secure channel (it was reset, reselected or
        /// lost the field). Start again from select; never resend into it.
        case secureChannelLost
        /// The card has 2FA on and this signature needs the checker's approval.
        case approvalRequired
        /// The card's 2FA refused the approval.
        case approvalRefused
        /// The nonce was used, evicted or invalidated on the card: run round 1 again.
        case nonceUnavailable
        /// The nonce belongs to another key than the one derived for this tap.
        case nonceKeyMismatch
        /// No key was derived since the card was selected.
        case keyNotDerived
        /// A command too long for one secure-channel APDU.
        case commandTooLong
        case malformedResponse(String)
        /// Any other status word the card returned.
        case cardStatus(UInt16)
    }

    /// The error a status word stands for, nil for success.
    static func error(for statusWord: UInt16) -> SatochipError? {
        switch statusWord {
        case 0x9000: nil
        case 0x63C0 ... 0x63CF: .wrongPIN(triesLeft: Int(statusWord & 0x0F))
        case 0x9C04: .notSetUp
        case 0x9C06: .pinRequired
        case 0x9C0B: .approvalRefused
        case 0x9C0C: .pinBlocked
        case 0x9C13: .keyNotDerived
        case 0x9C14: .notSeeded
        case 0x9C20 ... 0x9C23: .secureChannelLost
        case 0x9C44, 0x9C46, 0x9C47: .nonceUnavailable
        case 0x9C45: .nonceKeyMismatch
        case 0x9C4A, 0x9C4B: .featureDisabled
        default: .cardStatus(statusWord)
        }
    }

    /// GET STATUS, also returned by SELECT: versions, PIN and PUK tries, the
    /// 2FA, seed and setup flags, and the optional-feature policies.
    public struct Status: Equatable, Sendable {
        public let protocolMajor: UInt8
        public let protocolMinor: UInt8
        public let appletMajor: UInt8
        public let appletMinor: UInt8
        public let pinTriesLeft: UInt8
        public let pukTriesLeft: UInt8
        public let needsTwoFactor: Bool
        public let isSeeded: Bool
        public let isSetUp: Bool
        /// 0 enabled, 1 disabled, 2 blocked; nil on applets before MuSig2.
        public let musig2Policy: UInt8?
        /// The Nostr policy also gates TaprootTweakPrivateKey's no-tweak mode,
        /// which is how this client reads a derived key's full point.
        public let nostrPolicy: UInt8?

        public init(bytes: Data) throws {
            let b = Array(bytes)
            guard b.count >= 12 else { throw SatochipError.malformedResponse("status of \(b.count) bytes") }
            protocolMajor = b[0]
            protocolMinor = b[1]
            appletMajor = b[2]
            appletMinor = b[3]
            pinTriesLeft = b[4]
            pukTriesLeft = b[5]
            needsTwoFactor = b[8] != 0
            isSeeded = b[9] != 0
            isSetUp = b[10] != 0
            nostrPolicy = b.count > 14 ? b[14] : nil
            musig2Policy = b.count > 16 ? b[16] : nil
        }

        public var isSupportedVersion: Bool {
            protocolMajor == Satochip.protocolVersion.major && protocolMinor == Satochip.protocolVersion.minor
        }
    }
}

extension Satochip.SatochipError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSigningContext: "The card's signing request is malformed."
        case .invalidTwoFactorKey: "A 2FA secret is 20 bytes."
        case let .unsupportedVersion(major, minor):
            "This Satochip runs protocol \(major).\(minor); Winnow needs 0.16."
        case .notSetUp: "This Satochip has not been set up."
        case .notSeeded: "This Satochip holds no seed."
        case .featureDisabled: "This Satochip has the feature Winnow needs turned off."
        case .pinRequired: "The card needs its PIN."
        case let .wrongPIN(triesLeft): "Wrong PIN. \(triesLeft) tries left before the card blocks it."
        case .pinBlocked: "The card's PIN is blocked. Unblock it with the PUK."
        case .secureChannelLost: "The card left the field. Tap again."
        case .approvalRequired: "The card has 2FA on: paste the checker's approvals first."
        case .approvalRefused: "The card refused the approvals: they are not for this payment."
        case .nonceUnavailable: "The card no longer holds this nonce. Start the exchange again."
        case .nonceKeyMismatch: "The card's nonce belongs to another key. Start the exchange again."
        case .keyNotDerived: "The card has no key ready. Tap again."
        case .commandTooLong: "A card command is too long."
        case let .malformedResponse(what): "The card sent an unexpected answer (\(what))."
        case let .cardStatus(word): "The card refused the command (status \(String(format: "%04X", word)))."
        }
    }
}

/// Carries command APDUs to a Satochip and returns its responses: Core NFC on
/// the phone, the applet simulator over a bridge, or an emulated card in tests.
public protocol SatochipTransport: Sendable {
    func transmit(_ command: Data) async throws -> Satochip.Response
}
