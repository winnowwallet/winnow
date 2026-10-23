import Foundation
import NativeSecp256k1

extension Satochip {
    /// The card's half of BIP327 round 1: the public nonce for the PSBT, the
    /// card's id for it, and the secret nonce the card encrypted and MACed
    /// under keys it never exports. The card accepts that blob once.
    public struct CardNonce: Equatable, Sendable {
        public let publicNonce: Data
        public let id: UInt16
        public let encryptedSecretNonce: Data
    }

    /// A participant key read from the card: its account key and origin.
    public struct ParticipantKey: Equatable, Sendable {
        public let masterFingerprint: UInt32
        public let path: [UInt32]
        /// The account key, public only.
        public let accountKey: HDKey

        /// `[fingerprint/path]xpub`, the form a `musig()` participant takes.
        public func keyExpression(network: HDKey.Network) -> String {
            let steps = path.map { $0 >= HDKey.hardenedOffset ? "\($0 - HDKey.hardenedOffset)'" : "\($0)" }
            let origin = ([String(format: "%08x", masterFingerprint)] + steps).joined(separator: "/")
            return "[\(origin)]\(accountKey.serialized(network: network))"
        }
    }

    /// One tap's conversation with the card: select, the secure channel, the
    /// PIN, a derivation, then nonces or signatures. Everything the card holds
    /// for a session (the channel, the PIN, the derived key) ends when it is
    /// deselected or loses the field, so each tap starts again from `connect`.
    /// After `secureChannelLost` the session is spent; never resend a command
    /// into a new channel, which would overwrite what the card staged.
    public struct Session: Sendable {
        private let transport: any SatochipTransport
        public private(set) var status: Status?
        private var channel: SecureChannel?
        /// The path derived since the card was selected, which Sign and NonceGen use.
        public private(set) var derivedPath: [UInt32]?

        public init(transport: any SatochipTransport) {
            self.transport = transport
        }

        // MARK: - Session

        /// SELECT the applet; the answer is the card's status.
        @discardableResult
        public mutating func select() async throws -> Status {
            channel = nil
            derivedPath = nil
            let response = try await transport.transmit(Data([0x00, 0xA4, 0x04, 0x00, UInt8(appletID.count)]) + appletID)
            if let error = Satochip.error(for: response.statusWord) { throw error }
            let status = try Status(bytes: response.data)
            self.status = status
            return status
        }

        /// GET STATUS in clear.
        public mutating func readStatus() async throws -> Status {
            let response = try await transport.transmit(Data([0xB0, 0x3C, 0x00, 0x00, 0x00]))
            if let error = Satochip.error(for: response.statusWord) { throw error }
            let status = try Status(bytes: response.data)
            self.status = status
            return status
        }

        /// INIT_SECURE_CHANNEL with a fresh key. The card logs the PIN out.
        public mutating func openSecureChannel() async throws {
            let ephemeral = Satochip.randomPrivateKey()
            let response = try await transport.transmit(SecureChannel.openingCommand(ephemeral: ephemeral))
            if let error = Satochip.error(for: response.statusWord) { throw error }
            channel = try SecureChannel(ephemeral: ephemeral, response: response.data)
        }

        /// The card's identity key, as the channel reported it.
        public var cardAuthentikeyX: Data? { channel?.cardAuthentikeyX }

        /// Select, check the version, open the channel and verify the PIN.
        public mutating func connect(pin: Data) async throws {
            let status = try await select()
            guard status.isSupportedVersion else {
                throw SatochipError.unsupportedVersion(major: status.protocolMajor, minor: status.protocolMinor)
            }
            guard status.isSetUp else { throw SatochipError.notSetUp }
            try await openSecureChannel()
            try await verifyPIN(pin)
        }

        public mutating func verifyPIN(_ pin: Data) async throws {
            _ = try await send(0x42, data: pin)
        }

        // MARK: - Provisioning (a fresh card; development and tests)

        /// SETUP (0x2A) of a fresh card: the PIN and PUK and their try limits.
        /// The legacy default PIN field is ignored by protocol 0.16 but still parsed.
        public mutating func setUp(pin: Data, puk: Data, pinTries: UInt8 = 5, pukTries: UInt8 = 5) async throws {
            var data = Data([8]) + Data("Muscle00".utf8)
            data.append(contentsOf: [pinTries, pukTries, UInt8(pin.count)])
            data.append(pin)
            data.append(UInt8(puk.count))
            data.append(puk)
            _ = try await send(0x2A, data: data)
        }

        /// IMPORT SEED (0x6C): a 16- to 64-byte BIP32 seed.
        public mutating func importSeed(_ seed: Data) async throws {
            _ = try await send(0x6C, p1: UInt8(seed.count), data: seed)
        }

        /// SET 2FA KEY (0x79): from now on the card signs only with approvals
        /// made with this 20-byte key. Whoever sends this sees the key, so only
        /// the checker may.
        public mutating func setTwoFactorKey(_ key: Data) async throws {
            guard key.count == 20 else { throw SatochipError.invalidTwoFactorKey }
            _ = try await send(0x79, data: key + Data(count: 8))
        }

        // MARK: - Keys

        /// BIP32 derivation (0x6D) to `path`; the key becomes the card's signing
        /// key until it is deselected. Returns the key's x coordinate and chain
        /// code (the card reports no parity).
        @discardableResult
        public mutating func derive(path: [UInt32]) async throws -> (x: Data, chainCode: Data) {
            guard path.count <= 10 else { throw SatochipError.cardStatus(0x9C10) }
            var data = Data()
            for step in path { withUnsafeBytes(of: step.bigEndian) { data.append(contentsOf: $0) } }
            let response = try await send(0x6D, p1: UInt8(path.count), data: data)
            var reader = Reader(response)
            let chainCode = try reader.take(32)
            let x = try reader.sized(exactly: 32)
            derivedPath = path
            return (x, chainCode)
        }

        /// The full point of the derived key, from TaprootTweakPrivateKey in
        /// its no-tweak mode (0x7C, P2 = 0x01), which returns it uncompressed.
        /// That mode follows the card's Nostr policy.
        public mutating func derivedPublicKey() async throws -> Data {
            guard derivedPath != nil else { throw SatochipError.keyNotDerived }
            var reader = Reader(try await send(0x7C, p1: 0xFF, p2: 0x01))
            let point = try reader.sized(exactly: 65)
            return try Secp256k1.PublicKey(uncompressed: point).compressed
        }

        /// The participant key at `path` with its origin: the master
        /// fingerprint, the parent fingerprint and the account key, each with
        /// its parity. The account key is left derived for signing.
        public mutating func participantKey(path: [UInt32]) async throws -> ParticipantKey {
            guard !path.isEmpty else { throw SatochipError.cardStatus(0x9C10) }
            try await derive(path: [])
            let master = HDKey(depth: 0, parentFingerprint: 0, childIndex: 0, chainCode: Data(count: 32),
                               privateKey: nil, publicKey: try await derivedPublicKey())
            var parentFingerprint = master.fingerprint
            if path.count > 1 {
                try await derive(path: Array(path.dropLast()))
                parentFingerprint = HDKey(depth: 0, parentFingerprint: 0, childIndex: 0, chainCode: Data(count: 32),
                                          privateKey: nil, publicKey: try await derivedPublicKey()).fingerprint
            }
            let (x, chainCode) = try await derive(path: path)
            let publicKey = try await derivedPublicKey()
            guard publicKey.dropFirst() == x else { throw SatochipError.malformedResponse("derived key mismatch") }
            let account = HDKey(depth: UInt8(path.count), parentFingerprint: parentFingerprint, childIndex: path.last!,
                                chainCode: chainCode, privateKey: nil, publicKey: publicKey)
            return ParticipantKey(masterFingerprint: master.fingerprint, path: path, accountKey: account)
        }

        // MARK: - MuSig2

        /// NonceGen (0x7E) for the derived key: OP_INIT returns the public nonce
        /// and id, OP_FINALIZE the encrypted secret nonce. The two run back to
        /// back; the card keeps the blob only until it is deselected.
        public mutating func generateNonce(aggregateKey: Data?, message: Data?,
                                           extraInput: Data? = nil) async throws -> CardNonce {
            guard derivedPath != nil else { throw SatochipError.keyNotDerived }
            let initial = try await send(0x7E, p1: 0xFF, p2: 0x01,
                                         data: Self.nonceInput(aggregateKey: aggregateKey, message: message,
                                                               extraInput: extraInput))
            let (publicNonce, id) = try Self.parseNonce(initial)
            let blob = try await send(0x7E, p1: 0xFF, p2: 0x03)
            guard blob.count == 144 else { throw SatochipError.malformedResponse("secret nonce of \(blob.count) bytes") }
            return CardNonce(publicNonce: publicNonce, id: id, encryptedSecretNonce: blob)
        }

        /// Sign (0x7F) with the derived key: OP_INIT stages the encrypted
        /// secret nonce, OP_FINALIZE sends the signing context and, when the
        /// card has 2FA, the checker's approval. The card consumes the nonce
        /// before it looks the key up, so the key must already be derived.
        public mutating func partialSign(encryptedSecretNonce: Data, signingContext: Data,
                                         approval: Data?) async throws -> Data {
            guard derivedPath != nil else { throw SatochipError.keyNotDerived }
            guard encryptedSecretNonce.count == 144 else { throw SatochipError.nonceUnavailable }
            guard signingContext.count == 66 else { throw SatochipError.invalidSigningContext }
            var finalData = signingContext
            if let approval {
                guard approval.count == 22, approval.prefix(2) == twoFactorFlag else { throw SatochipError.approvalRefused }
                finalData.append(approval)
            } else if status?.needsTwoFactor == true {
                throw SatochipError.approvalRequired
            }
            _ = try await send(0x7F, p1: 0xFF, p2: 0x01, data: encryptedSecretNonce)
            let partial = try await send(0x7F, p1: 0xFF, p2: 0x03, data: finalData)
            guard partial.count == 32 else { throw SatochipError.malformedResponse("partial signature") }
            return partial
        }

        /// NonceGen's OP_INIT data: [len | aggpk][len | msg, or 0xFF for none][len | extra].
        static func nonceInput(aggregateKey: Data?, message: Data?, extraInput: Data?) throws -> Data {
            guard aggregateKey.map({ $0.count == 32 }) ?? true, message.map({ $0.count <= 32 }) ?? true,
                  extraInput.map({ $0.count <= 32 }) ?? true
            else { throw SatochipError.cardStatus(0x9C0F) }
            var data = Data([aggregateKey == nil ? 0 : 32]) + (aggregateKey ?? Data())
            data.append(message.map { UInt8($0.count) } ?? 0xFF)
            data.append(message ?? Data())
            data.append(UInt8(extraInput?.count ?? 0))
            data.append(extraInput ?? Data())
            return data
        }

        /// [R1 | R2 | id]: the 66-byte BIP327 public nonce, both points valid, and its id.
        static func parseNonce(_ initial: Data) throws -> (publicNonce: Data, id: UInt16) {
            guard initial.count == 68 else { throw SatochipError.malformedResponse("nonce of \(initial.count) bytes") }
            let bytes = Data(initial)
            for start in [0, 33] where (try? Secp256k1.PublicKey(compressed: bytes.subdata(in: start ..< start + 33))) == nil {
                throw SatochipError.malformedResponse("public nonce")
            }
            return (bytes.prefix(66), UInt16(bytes[66]) << 8 | UInt16(bytes[67]))
        }

        // MARK: - Transport

        /// One command through the secure channel; the plain answer, or the
        /// status word's error. A lost channel ends the session.
        private mutating func send(_ instruction: UInt8, p1: UInt8 = 0, p2: UInt8 = 0,
                                   data: Data = Data()) async throws -> Data {
            guard var channel else { throw SatochipError.secureChannelLost }
            guard data.count <= 255 else { throw SatochipError.commandTooLong }
            let command = Data([0xB0, instruction, p1, p2, UInt8(data.count)]) + data
            let wrapped = try channel.wrap(command)
            self.channel = channel
            let response = try await transport.transmit(wrapped)
            if let error = Satochip.error(for: response.statusWord) {
                if error == .secureChannelLost {
                    self.channel = nil
                    derivedPath = nil
                }
                throw error
            }
            return try channel.unwrap(response.data)
        }
    }

    /// A random secp256k1 private key (for a channel's single-use key).
    static func randomPrivateKey() -> Secp256k1.PrivateKey {
        while true {
            if let key = try? Secp256k1.PrivateKey(MuSig.randomBytes(32)) { return key }
        }
    }
}
