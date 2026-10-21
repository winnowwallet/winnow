import CryptoKit
import Foundation
import NativeSecp256k1
import Testing
import TestSupport
@testable import WalletCore

/// The Satochip client against `SatochipEmulator`, a model of applet
/// protocol 0.16: the secure channel, provisioning, the participant key and
/// complete MuSig2 rounds, and the failures a card session can meet.
@Suite("Satochip session")
struct SatochipSessionTests {
    static let pin = Data("1234".utf8)
    static let cardSeed = Data(repeating: 0x02, count: 32)
    static let phoneSeed = Data(repeating: 0x01, count: 32)
    static let twoFactorKey = Data(hex: "00112233445566778899aabbccddeeff01234567")!
    static let path: [UInt32] = [86 + HDKey.hardenedOffset, 1 + HDKey.hardenedOffset, HDKey.hardenedOffset]

    /// A connected session with the account key derived.
    static func connected(_ card: SatochipEmulator) async throws -> Satochip.Session {
        var session = Satochip.Session(transport: card)
        try await session.connect(pin: pin)
        try await session.derive(path: path)
        return session
    }

    // MARK: - Channel primitives

    @Test("AES-128-CBC matches NIST SP 800-38A F.2.1 and round-trips with padding")
    func aesCBC() throws {
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")!
        let iv = Data(hex: "000102030405060708090a0b0c0d0e0f")!
        let plaintext = Data(hex: "6bc1bee22e409f96e93d7e117393172a")!
        let ciphertext = try Satochip.AESCBC.encrypt(key: key, iv: iv, plaintext: plaintext)
        #expect(ciphertext.prefix(16) == Data(hex: "7649abac8119b246cee98e9b12e9197d")!)
        #expect(ciphertext.count == 32) // a full block of PKCS#7 padding
        #expect(try Satochip.AESCBC.decrypt(key: key, iv: iv, ciphertext: ciphertext) == plaintext)
    }

    /// Expected values computed with Python's hmac, as pysatochip derives them.
    @Test("channel keys are HMAC-SHA1 of the shared x over sc_key and sc_mac")
    func channelKeys() {
        let keys = Satochip.ChannelKeys(sharedX: Data(1 ... 32))
        #expect(keys.encryption == Data(hex: "6e298dbd382b7523384e6323771062a3")!)
        #expect(keys.mac == Data(hex: "0c2ca467a2e60763b69fcd9f116232666e0b32dc")!)
    }

    @Test("both ends of the ECDH agree from x coordinates alone")
    func sharedSecret() throws {
        let a = try Secp256k1.PrivateKey(Data(repeating: 0x11, count: 32))
        let b = try Secp256k1.PrivateKey(Data(repeating: 0x22, count: 32))
        let ax = Data(a.publicKey.compressed.dropFirst())
        let bx = Data(b.publicKey.compressed.dropFirst())
        #expect(try Satochip.sharedX(privateKey: a, peerX: bx) == Satochip.sharedX(privateKey: b, peerX: ax))
    }

    // MARK: - Provisioning and PIN

    @Test("a fresh card is set up, unlocked and seeded through the channel")
    func provisioning() async throws {
        let card = SatochipEmulator()
        var session = Satochip.Session(transport: card)
        let fresh = try await session.select()
        #expect(fresh.isSupportedVersion && !fresh.isSetUp && !fresh.isSeeded)
        await #expect(throws: Satochip.SatochipError.notSetUp) { try await session.connect(pin: Self.pin) }
        try await session.openSecureChannel()
        try await session.setUp(pin: Self.pin, puk: Data("87654321".utf8))
        try await session.verifyPIN(Self.pin)
        try await session.importSeed(Self.cardSeed)
        let status = try await session.readStatus()
        #expect(status.isSetUp && status.isSeeded && !status.needsTwoFactor)
        #expect(status.musig2Policy == 0)
    }

    @Test("a wrong PIN reports the tries left, then the PIN blocks")
    func wrongPIN() async throws {
        let card = SatochipEmulator(pin: Self.pin, seed: Self.cardSeed)
        var session = Satochip.Session(transport: card)
        try await session.select()
        try await session.openSecureChannel()
        for left in (0 ..< 5).reversed() {
            await #expect(throws: Satochip.SatochipError.wrongPIN(triesLeft: left)) {
                try await session.verifyPIN(Data("0000".utf8))
            }
        }
        await #expect(throws: Satochip.SatochipError.pinBlocked) { try await session.verifyPIN(Self.pin) }
    }

    // MARK: - Participant key

    @Test("the participant key carries the card's master fingerprint, parent and parity")
    func participantKey() async throws {
        let card = SatochipEmulator(pin: Self.pin, seed: Self.cardSeed)
        var session = Satochip.Session(transport: card)
        try await session.connect(pin: Self.pin)
        let key = try await session.participantKey(path: Self.path)
        let master = try HDKey(seed: Self.cardSeed)
        let expected = try master.derived(path: Self.path).neutered
        #expect(key.accountKey == expected)
        #expect(key.masterFingerprint == master.fingerprint)
        #expect(key.keyExpression(network: .testnet)
            == "[\(String(format: "%08x", master.fingerprint))/86'/1'/0']\(expected.serialized(network: .testnet))")
        #expect(session.derivedPath == Self.path) // left ready to sign
    }

    @Test("without the Nostr policy the card will not show a derived key's parity")
    func participantKeyNeedsNostrPolicy() async throws {
        let card = SatochipEmulator(pin: Self.pin, seed: Self.cardSeed)
        card.nostrPolicy = 1
        var session = Satochip.Session(transport: card)
        try await session.connect(pin: Self.pin)
        await #expect(throws: Satochip.SatochipError.featureDisabled) {
            _ = try await session.participantKey(path: Self.path)
        }
    }

    // MARK: - MuSig2

    struct TwoOfTwo {
        let phoneSecret: Data
        let phoneKey: Data
        let cardKey: Data
        let keys: [Data]
        let tweaks: [Data]
        let isXOnly: [Bool]
        let message: Data

        var outputKey: Data {
            get throws { try MuSig.aggregateXonly(publicKeys: keys, tweaks: tweaks, isXOnlyTweaks: isXOnly) }
        }

        func session(cardNonce: Data, phoneNonce: Data) throws -> MuSig.Session {
            MuSig.Session(aggregateNonce: try MuSig.nonceAggregate(publicNonces: [phoneNonce, cardNonce]),
                          publicKeys: keys, tweaks: tweaks, isXOnlyTweaks: isXOnly, message: message)
        }
    }

    static func twoOfTwo(cardKey: Data, message: Data, tweaks: [Data] = [], isXOnly: [Bool] = []) throws -> TwoOfTwo {
        let phone = try HDKey(seed: phoneSeed).derived(path: path)
        return TwoOfTwo(phoneSecret: phone.privateKey!, phoneKey: phone.publicKey, cardKey: cardKey,
                        keys: MuSig.keySort([phone.publicKey, cardKey]), tweaks: tweaks, isXOnly: isXOnly,
                        message: message)
    }

    /// Round 1 and round 2 with the card, the phone's own partial, and the
    /// aggregate checked as a BIP340 signature for the tweaked key.
    static func sign(_ setup: TwoOfTwo, with session: inout Satochip.Session,
                     twoFactorKey: Data?) async throws -> (signature: Data, context: Data) {
        let outputKey = try setup.outputKey
        let cardNonce = try await session.generateNonce(aggregateKey: outputKey, message: setup.message)
        let phoneNonce = try MuSig.nonceGenerate(
            secretKey: setup.phoneSecret, publicKey: setup.phoneKey, aggregateKey: outputKey, message: setup.message)
        var phoneSecretNonce = phoneNonce.secretNonce
        let musig = try setup.session(cardNonce: cardNonce.publicNonce, phoneNonce: phoneNonce.publicNonce)
        let context = try Satochip.signingContext(publicKey: setup.cardKey, session: musig)
        let approval = try twoFactorKey.map { try Satochip.twoFactorApproval(signingContext: context, key: $0) }
        let cardPartial = try await session.partialSign(encryptedSecretNonce: cardNonce.encryptedSecretNonce,
                                                        signingContext: context, approval: approval)
        guard try MuSig.partialVerify(partialSignature: cardPartial, publicNonce: cardNonce.publicNonce,
                                      publicKey: setup.cardKey, session: musig)
        else { throw Satochip.SatochipError.malformedResponse("card partial failed verification") }
        let phonePartial = try MuSig.partialSign(secretNonce: &phoneSecretNonce, secretKey: setup.phoneSecret,
                                                 session: musig)
        let ordered = setup.keys.map { $0 == setup.cardKey ? cardPartial : phonePartial }
        return (try MuSig.partialSigAggregate(partialSignatures: ordered, session: musig), context)
    }

    @Test("the card co-signs 2-of-2 spends, tweaked or not, under its 2FA")
    func twoOfTwoSignatures() async throws {
        let card = SatochipEmulator(pin: Self.pin, seed: Self.cardSeed, twoFactorKey: Self.twoFactorKey)
        var session = Satochip.Session(transport: card)
        try await session.connect(pin: Self.pin)
        let cardKey = try await session.participantKey(path: Self.path).accountKey.publicKey
        var flags = Set<[UInt8]>()
        var rng = SeededRandom(state: 0x5A70)
        func random32() -> Data {
            var bytes = Data()
            for _ in 0 ..< 4 {
                var word = rng.next().bigEndian
                withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) }
            }
            bytes[bytes.startIndex] &= 0x7F // below n
            return bytes
        }
        for round in 0 ..< 8 {
            let message = random32()
            // A plain tweak then an x-only one, as BIP328 then TapTweak apply them.
            let setup = round == 0
                ? try Self.twoOfTwo(cardKey: cardKey, message: message)
                : try Self.twoOfTwo(cardKey: cardKey, message: message, tweaks: [random32(), random32()],
                                    isXOnly: [false, true])
            let (signature, context) = try await Self.sign(setup, with: &session, twoFactorKey: Self.twoFactorKey)
            #expect(Secp256k1.Schnorr.verify(signature: signature, message: message, publicKey: try setup.outputKey))
            flags.insert(Array(context.suffix(2)))
        }
        #expect(flags.count > 1, "the rounds should exercise both negations")
    }

    @Test("a card nonce signs once; a replay is refused")
    func nonceSignsOnce() async throws {
        let card = SatochipEmulator(pin: Self.pin, seed: Self.cardSeed)
        var session = try await Self.connected(card)
        let cardKey = try await session.derivedPublicKey()
        let setup = try Self.twoOfTwo(cardKey: cardKey, message: Data(repeating: 7, count: 32))
        let nonce = try await session.generateNonce(aggregateKey: try setup.outputKey, message: setup.message)
        let phone = try MuSig.nonceGenerate(publicKey: setup.phoneKey).publicNonce
        let context = try Satochip.signingContext(publicKey: cardKey,
                                                  session: setup.session(cardNonce: nonce.publicNonce, phoneNonce: phone))
        _ = try await session.partialSign(encryptedSecretNonce: nonce.encryptedSecretNonce, signingContext: context,
                                          approval: nil)
        await #expect(throws: Satochip.SatochipError.nonceUnavailable) {
            _ = try await session.partialSign(encryptedSecretNonce: nonce.encryptedSecretNonce,
                                              signingContext: context, approval: nil)
        }
    }

    @Test("with 2FA on, a missing approval stays on the phone and a wrong one keeps the nonce")
    func approvals() async throws {
        let card = SatochipEmulator(pin: Self.pin, seed: Self.cardSeed, twoFactorKey: Self.twoFactorKey)
        var session = try await Self.connected(card)
        let cardKey = try await session.derivedPublicKey()
        let setup = try Self.twoOfTwo(cardKey: cardKey, message: Data(repeating: 9, count: 32))
        let nonce = try await session.generateNonce(aggregateKey: try setup.outputKey, message: setup.message)
        let phone = try MuSig.nonceGenerate(publicKey: setup.phoneKey).publicNonce
        let context = try Satochip.signingContext(publicKey: cardKey,
                                                  session: setup.session(cardNonce: nonce.publicNonce, phoneNonce: phone))
        let sent = card.instructions.count
        await #expect(throws: Satochip.SatochipError.approvalRequired) {
            _ = try await session.partialSign(encryptedSecretNonce: nonce.encryptedSecretNonce, signingContext: context,
                                              approval: nil)
        }
        #expect(card.instructions.count == sent, "nothing reaches the card without an approval")
        let wrong = try Satochip.twoFactorApproval(signingContext: context, key: Data(repeating: 0xAB, count: 20))
        await #expect(throws: Satochip.SatochipError.approvalRefused) {
            _ = try await session.partialSign(encryptedSecretNonce: nonce.encryptedSecretNonce, signingContext: context,
                                              approval: wrong)
        }
        let right = try Satochip.twoFactorApproval(signingContext: context, key: Self.twoFactorKey)
        let partial = try await session.partialSign(encryptedSecretNonce: nonce.encryptedSecretNonce,
                                                    signingContext: context, approval: right)
        #expect(partial.count == 32)
    }

    @Test("a nonce used with another key is burned, as the applet burns it")
    func nonceBoundToItsKey() async throws {
        let card = SatochipEmulator(pin: Self.pin, seed: Self.cardSeed)
        var session = try await Self.connected(card)
        let cardKey = try await session.derivedPublicKey()
        let setup = try Self.twoOfTwo(cardKey: cardKey, message: Data(repeating: 3, count: 32))
        let nonce = try await session.generateNonce(aggregateKey: try setup.outputKey, message: setup.message)
        let phone = try MuSig.nonceGenerate(publicKey: setup.phoneKey).publicNonce
        let context = try Satochip.signingContext(publicKey: cardKey,
                                                  session: setup.session(cardNonce: nonce.publicNonce, phoneNonce: phone))
        try await session.derive(path: Array(Self.path.dropLast()) + [HDKey.hardenedOffset + 1])
        await #expect(throws: Satochip.SatochipError.nonceKeyMismatch) {
            _ = try await session.partialSign(encryptedSecretNonce: nonce.encryptedSecretNonce, signingContext: context,
                                              approval: nil)
        }
        try await session.derive(path: Self.path)
        await #expect(throws: Satochip.SatochipError.nonceUnavailable) {
            _ = try await session.partialSign(encryptedSecretNonce: nonce.encryptedSecretNonce, signingContext: context,
                                              approval: nil)
        }
    }

    @Test("a tampered command loses the channel, and the session refuses to go on")
    func tamperedChannel() async throws {
        let card = SatochipEmulator(pin: Self.pin, seed: Self.cardSeed)
        let tamper = InterposedTransport(card) { command in
            guard command.count > 30, command[command.startIndex + 1] == 0x82 else { return command }
            var changed = command
            changed[changed.startIndex + 30] ^= 0x01
            return changed
        }
        var session = Satochip.Session(transport: tamper)
        try await session.select()
        try await session.openSecureChannel()
        await #expect(throws: Satochip.SatochipError.secureChannelLost) { try await session.verifyPIN(Self.pin) }
        await #expect(throws: Satochip.SatochipError.secureChannelLost) { try await session.verifyPIN(Self.pin) }
    }

    @Test("losing the field mid-nonce or mid-signature costs at most a nonce")
    func fieldLoss() async throws {
        let card = SatochipEmulator(pin: Self.pin, seed: Self.cardSeed)
        var dropNext: UInt8?
        let dropping = InterposedTransport(card) { command in
            if let instruction = dropNext, command.count > 1, command[command.startIndex + 1] == 0x82,
               card.instructions.last == instruction {
                card.reset()
                dropNext = nil
            }
            return command
        }
        func reconnect() async throws -> Satochip.Session {
            var session = Satochip.Session(transport: dropping)
            try await session.connect(pin: Self.pin)
            try await session.derive(path: Self.path)
            return session
        }
        var session = try await reconnect()
        let cardKey = try await session.derivedPublicKey()
        let setup = try Self.twoOfTwo(cardKey: cardKey, message: Data(repeating: 5, count: 32))

        // Lost between NonceGen's two steps: that nonce is gone, the next works.
        dropNext = 0x7E
        await #expect(throws: Satochip.SatochipError.secureChannelLost) {
            _ = try await session.generateNonce(aggregateKey: try setup.outputKey, message: setup.message)
        }
        session = try await reconnect()
        let nonce = try await session.generateNonce(aggregateKey: try setup.outputKey, message: setup.message)

        // Lost between Sign's two steps: the id survives, the next tap signs.
        let phone = try MuSig.nonceGenerate(publicKey: setup.phoneKey).publicNonce
        let context = try Satochip.signingContext(publicKey: cardKey,
                                                  session: setup.session(cardNonce: nonce.publicNonce, phoneNonce: phone))
        dropNext = 0x7F
        await #expect(throws: Satochip.SatochipError.secureChannelLost) {
            _ = try await session.partialSign(encryptedSecretNonce: nonce.encryptedSecretNonce, signingContext: context,
                                              approval: nil)
        }
        session = try await reconnect()
        let partial = try await session.partialSign(encryptedSecretNonce: nonce.encryptedSecretNonce,
                                                    signingContext: context, approval: nil)
        #expect(partial.count == 32)
    }

    @Test("sixteen nonces may be outstanding; the seventeenth evicts the oldest")
    func sixteenSlots() async throws {
        let card = SatochipEmulator(pin: Self.pin, seed: Self.cardSeed)
        var session = try await Self.connected(card)
        let cardKey = try await session.derivedPublicKey()
        let setup = try Self.twoOfTwo(cardKey: cardKey, message: Data(repeating: 4, count: 32))
        var nonces: [Satochip.CardNonce] = []
        for _ in 0 ..< 17 {
            nonces.append(try await session.generateNonce(aggregateKey: try setup.outputKey, message: setup.message))
        }
        let phone = try MuSig.nonceGenerate(publicKey: setup.phoneKey).publicNonce
        for (index, nonce) in [(0, nonces[0]), (1, nonces[1]), (16, nonces[16])] {
            let context = try Satochip.signingContext(publicKey: cardKey,
                                                      session: setup.session(cardNonce: nonce.publicNonce, phoneNonce: phone))
            if index == 0 {
                await #expect(throws: Satochip.SatochipError.nonceUnavailable) {
                    _ = try await session.partialSign(encryptedSecretNonce: nonce.encryptedSecretNonce,
                                                      signingContext: context, approval: nil)
                }
            } else {
                #expect(try await session.partialSign(encryptedSecretNonce: nonce.encryptedSecretNonce,
                                                      signingContext: context, approval: nil).count == 32)
            }
        }
    }

    @Test("when the id counter wraps, every outstanding nonce is invalidated")
    func counterWrap() async throws {
        let card = SatochipEmulator(pin: Self.pin, seed: Self.cardSeed)
        var session = try await Self.connected(card)
        let cardKey = try await session.derivedPublicKey()
        let setup = try Self.twoOfTwo(cardKey: cardKey, message: Data(repeating: 6, count: 32))
        card.setNonceCounter(0xFFFF)
        let last = try await session.generateNonce(aggregateKey: try setup.outputKey, message: setup.message)
        #expect(last.id == 0xFFFF)
        await #expect(throws: Satochip.SatochipError.nonceUnavailable) {
            _ = try await session.generateNonce(aggregateKey: try setup.outputKey, message: setup.message)
        }
        let phone = try MuSig.nonceGenerate(publicKey: setup.phoneKey).publicNonce
        let context = try Satochip.signingContext(publicKey: cardKey,
                                                  session: setup.session(cardNonce: last.publicNonce, phoneNonce: phone))
        await #expect(throws: Satochip.SatochipError.nonceUnavailable) {
            _ = try await session.partialSign(encryptedSecretNonce: last.encryptedSecretNonce, signingContext: context,
                                              approval: nil)
        }
        #expect(try await session.generateNonce(aggregateKey: try setup.outputKey, message: setup.message).id == 1)
    }
}

/// Passes commands through a closure on their way to the card.
final class InterposedTransport: SatochipTransport, @unchecked Sendable {
    private let card: SatochipEmulator
    private let change: (Data) -> Data

    init(_ card: SatochipEmulator, change: @escaping (Data) -> Data) {
        self.card = card
        self.change = change
    }

    func transmit(_ command: Data) async throws -> Satochip.Response {
        try await card.transmit(change(command))
    }
}
