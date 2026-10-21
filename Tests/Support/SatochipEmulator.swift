import CommonCrypto
import CryptoKit
import Foundation
import NativeSecp256k1
import WalletCore

/// A software model of the Satochip applet (protocol 0.16, Satochip.java at
/// tag v0.16-0.1) for the commands Winnow sends: select and status, the
/// secure channel, setup, PIN, seed import, BIP32 derivation, the no-tweak
/// TaprootTweakPrivateKey, MuSig2 NonceGen and Sign, and the 2FA key. It keeps
/// the applet's checks, their order and its status words, including the ones
/// a client can trip over: Sign consumes the nonce id before it looks the key
/// up, a failed 2FA check keeps the id, 16 ids at most are outstanding, and a
/// command that reuses the card's buffer wipes a staged nonce.
///
/// Not modelled: the ECDSA signatures the card adds to some responses are
/// fixed placeholders (Winnow reads only their lengths), keyslots, the BIP341
/// tweak, PIN changes, factory reset. The real applet runs in the simulator
/// harness (Tools/Satochip) to keep this model honest.
public final class SatochipEmulator: SatochipTransport, @unchecked Sendable {
    private let lock = NSLock()

    // Persistent state (EEPROM on a card).
    private var isSetUp = false
    private var pin = Data()
    private var pinTriesMax: UInt8 = 5
    private var pinTriesLeft: UInt8 = 5
    private var pukTriesLeft: UInt8 = 5
    private var master: HDKey?
    private var twoFactorKey: Data?
    private var nonceEncryptionKey = SatochipEmulator.random(16)
    private var nonceMACKey = SatochipEmulator.random(32)
    private var nonceCounter: UInt16 = 1
    private var validIDs = [UInt16](repeating: 0, count: 16)
    /// 0 enabled, 1 disabled, 2 blocked, as the card reports them.
    public var musig2Policy: UInt8 = 0
    public var nostrPolicy: UInt8 = 0

    // Transient state (cleared when the card is deselected or loses the field).
    private var channelKeys: Satochip.ChannelKeys?
    private var channelCounter: UInt32 = 0
    private var pinValidated = false
    private var derivedKey: HDKey?
    /// The applet's shared buffer holding a staged secret nonce between two
    /// steps; nil once anything else has written over it.
    private var staged: Data?

    /// The card's identity key; its x coordinate is what the channel reports.
    private let authentikey = SatochipEmulator.randomKey()

    /// Commands seen, in order, so tests can check what reached the card.
    public private(set) var instructions: [UInt8] = []

    /// A fresh card, or one already set up, seeded and with 2FA on, as the
    /// trusted setup machine would leave it.
    public init(pin: Data? = nil, seed: Data? = nil, twoFactorKey: Data? = nil) {
        if let pin {
            isSetUp = true
            self.pin = pin
        }
        if let seed { master = try? HDKey(seed: seed) }
        self.twoFactorKey = twoFactorKey
    }

    public func transmit(_ command: Data) async throws -> Satochip.Response {
        try lock.withLock { try Satochip.Response(raw: process(command)) }
    }

    /// The card left the field or was reset: everything transient goes.
    public func reset() {
        lock.withLock { clearTransient() }
    }

    /// Moves the nonce id counter, to test its wrap-around.
    public func setNonceCounter(_ value: UInt16) {
        lock.withLock { nonceCounter = value }
    }

    // MARK: - Dispatch

    private func clearTransient() {
        channelKeys = nil
        channelCounter = 0
        pinValidated = false
        derivedKey = nil
        staged = nil
    }

    private func process(_ apdu: Data) -> Data {
        let bytes = Array(apdu)
        guard bytes.count >= 4 else { return sw(0x6700) }
        if bytes[0] == 0x00, bytes[1] == 0xA4 {
            let aid = bytes.count > 5 ? Data(bytes[5 ..< min(bytes.count, 5 + Int(bytes[4]))]) : Data()
            guard aid == Satochip.appletID else { return sw(0x6A82) }
            clearTransient()
            return statusBytes() + sw(0x9000)
        }
        guard bytes[0] == 0xB0 else { return sw(0x6E00) }
        let data = bytes.count > 5 ? Data(bytes[5...]) : Data()
        instructions.append(bytes[1])
        switch bytes[1] {
        case 0x3C: return statusBytes() + sw(0x9000)
        case 0x81:
            pinValidated = false
            channelKeys = nil
            staged = nil // the channel works in the shared buffer
            return openChannel(data)
        case 0x82: return unwrapAndProcess(data)
        default: return sw(0x9C20)
        }
    }

    private func unwrapAndProcess(_ body: Data) -> Data {
        guard let keys = channelKeys else { return sw(0x9C21) }
        let b = Array(body)
        guard b.count >= 18 else { return sw(0x6700) }
        let size = Int(b[16]) << 8 | Int(b[17])
        guard size % 16 == 0, b.count >= 18 + size + 2 + 20 else { return sw(0x6700) }
        let macSize = Int(b[18 + size]) << 8 | Int(b[19 + size])
        guard macSize == 20 else { return sw(0x9C23) }
        let mac = Data(b[(20 + size) ..< (40 + size)])
        guard keys.authenticationCode(Data(b[0 ..< (18 + size)])) == mac else { return sw(0x9C23) }
        let counter = UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])
        guard counter & 1 == 1, counter > channelCounter else { return sw(0x9C22) }
        channelCounter = counter + 1
        guard let plain = try? Satochip.AESCBC.decrypt(key: keys.encryption, iv: Data(b[0 ..< 16]),
                                                        ciphertext: Data(b[18 ..< (18 + size)])),
              plain.count >= 4, plain[plain.startIndex] == 0xB0
        else { return sw(0x6700) }
        let command = Array(plain)
        let lc = command.count > 4 ? Int(command[4]) : 0
        guard command.count >= 5 + lc || command.count == 4 else { return sw(0x6700) }
        let data = lc > 0 ? Data(command[5 ..< 5 + lc]) : Data()
        instructions.append(command[1])
        let (output, status) = inner(command[1], p1: command[2], p2: command[3], data: data)
        guard status == 0x9000 else { return sw(status) }
        guard !output.isEmpty else { return sw(0x9000) }
        var iv = SatochipEmulator.random(12)
        withUnsafeBytes(of: channelCounter.bigEndian) { iv.append(contentsOf: $0) }
        guard let ciphertext = try? Satochip.AESCBC.encrypt(key: keys.encryption, iv: iv, plaintext: output) else {
            return sw(0x6F00)
        }
        return iv + Data([UInt8(ciphertext.count >> 8), UInt8(ciphertext.count & 0xFF)]) + ciphertext + sw(0x9000)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func inner(_ instruction: UInt8, p1: UInt8, p2: UInt8, data: Data) -> (Data, UInt16) {
        if !isSetUp, instruction != 0x2A, instruction != 0x42 { return (Data(), 0x9C04) }
        if isSetUp, instruction == 0x2A { return (Data(), 0x9C07) }
        switch instruction {
        case 0x2A: return setUp(data)
        case 0x3C: return (statusBytes(), 0x9000)
        case 0x42: return verifyPIN(p1: p1, data: data)
        default: break
        }
        guard pinValidated else { return (Data(), 0x9C06) }
        switch instruction {
        case 0x6C: return importSeed(p1: p1, data: data)
        case 0x6D: return derive(depth: p1, data: data)
        case 0x7C: return fullKey(p1: p1, p2: p2)
        case 0x7E: return generateNonce(p1: p1, p2: p2, data: data)
        case 0x7F: return sign(p1: p1, p2: p2, data: data)
        case 0x79: return setTwoFactor(data)
        default: return (Data(), 0x6D00)
        }
    }

    // MARK: - Commands

    private func openChannel(_ data: Data) -> Data {
        guard data.count >= 65, data[data.startIndex] == 0x04,
              let client = try? Secp256k1.PublicKey(uncompressed: data.prefix(65))
        else { return sw(0x9C0F) }
        let ephemeral = SatochipEmulator.randomKey()
        let clientX = Data(client.compressed.dropFirst())
        guard let shared = try? Satochip.sharedX(privateKey: ephemeral, peerX: clientX) else { return sw(0x9C0F) }
        channelKeys = Satochip.ChannelKeys(sharedX: shared)
        channelCounter = 0
        let ephemeralX = Data(ephemeral.publicKey.compressed.dropFirst())
        let authX = Data(authentikey.publicKey.compressed.dropFirst())
        return sized(ephemeralX) + sized(Self.placeholderSignature) + sized(Self.placeholderSignature)
            + sized(authX) + sw(0x9000)
    }

    private func setUp(_ data: Data) -> (Data, UInt16) {
        var reader = data.makeIterator()
        func lengthValue() -> Data? {
            guard let size = reader.next() else { return nil }
            var value = Data()
            for _ in 0 ..< size {
                guard let byte = reader.next() else { return nil }
                value.append(byte)
            }
            return value
        }
        guard lengthValue() != nil, let pinTries = reader.next(), let pukTries = reader.next(),
              (1 ... 16).contains(pinTries), (1 ... 16).contains(pukTries),
              let newPIN = lengthValue(), (4 ... 16).contains(newPIN.count),
              let newPUK = lengthValue(), (4 ... 16).contains(newPUK.count)
        else { return (Data(), 0x9C0F) }
        pin = newPIN
        pinTriesMax = pinTries
        pinTriesLeft = pinTries
        pukTriesLeft = pukTries
        isSetUp = true
        return (Data(), 0x9000)
    }

    private func verifyPIN(p1: UInt8, data: Data) -> (Data, UInt16) {
        guard p1 == 0 else { return (Data(), 0x9C10) }
        guard isSetUp else { return (Data(), 0x9000) }
        guard (4 ... 16).contains(data.count) else { return (Data(), 0x9C0F) }
        guard pinTriesLeft > 0 else { return (Data(), 0x9C0C) }
        guard data == pin else {
            pinTriesLeft -= 1
            return (Data(), 0x63C0 + UInt16(pinTriesLeft))
        }
        pinTriesLeft = pinTriesMax
        pinValidated = true
        return (Data(), 0x9000)
    }

    private func importSeed(p1: UInt8, data: Data) -> (Data, UInt16) {
        guard master == nil else { return (Data(), 0x9C17) }
        guard (16 ... 64).contains(Int(p1)), data.count >= Int(p1) else { return (Data(), 0x6700) }
        master = try? HDKey(seed: data.prefix(Int(p1)))
        return (sized(Data(authentikey.publicKey.compressed.dropFirst())) + sized(Self.placeholderSignature), 0x9000)
    }

    private func derive(depth: UInt8, data: Data) -> (Data, UInt16) {
        guard let master else { return (Data(), 0x9C14) }
        guard depth <= 10 else { return (Data(), 0x9C10) }
        guard data.count >= 4 * Int(depth) else { return (Data(), 0x9C0F) }
        staged = nil // derivation works in the shared buffer
        let b = Array(data)
        let path = (0 ..< Int(depth)).map { i in
            UInt32(b[4 * i]) << 24 | UInt32(b[4 * i + 1]) << 16 | UInt32(b[4 * i + 2]) << 8 | UInt32(b[4 * i + 3])
        }
        guard let key = try? master.derived(path: path) else { return (Data(), 0x9C0E) }
        derivedKey = key
        let response = key.chainCode + sized(Data(key.publicKey.dropFirst()))
            + sized(Self.placeholderSignature) + sized(Self.placeholderSignature)
        return (response, 0x9000)
    }

    private func signingKey(_ p1: UInt8) -> (key: HDKey?, status: UInt16) {
        guard p1 == 0xFF else { return (nil, 0x9C10) }
        guard master != nil else { return (nil, 0x9C14) }
        guard let derivedKey else { return (nil, 0x9C13) }
        return (derivedKey, 0x9000)
    }

    private func fullKey(p1: UInt8, p2: UInt8) -> (Data, UInt16) {
        let (key, status) = signingKey(p1)
        guard let key else { return (Data(), status) }
        guard p2 == 0x01 else { return (Data(), 0x9C11) } // the BIP341 tweak (0x00) is not modelled
        guard nostrPolicy == 0 else { return (Data(), 0x9C4A) }
        staged = nil
        guard let point = try? Secp256k1.PublicKey(compressed: key.publicKey) else { return (Data(), 0x6F00) }
        return (sized(point.uncompressed) + sized(Self.placeholderSignature), 0x9000)
    }

    private func generateNonce(p1: UInt8, p2: UInt8, data: Data) -> (Data, UInt16) {
        guard musig2Policy == 0 else { return (Data(), 0x9C4A) }
        if p2 == 0x03 {
            guard let blob = staged, verifyBlob(blob) else { return (Data(), 0x9C44) }
            return (blob, 0x9000)
        }
        let (key, status) = signingKey(p1)
        guard let key, let secret = key.privateKey else { return (Data(), status) }
        // [aggpk_size | aggpk | msg_size | msg | extra_size | extra], parsed as
        // Satochip.java does: a msg_size of 0x80 or more means no message.
        let d = Array(data)
        var offset = 0
        func field(sizes allowed: (Int) -> Bool, absentWhenNegative: Bool) -> Result<Data?, SatochipStatus> {
            guard offset < d.count else { return .failure(SatochipStatus(0x6700)) }
            let size = d[offset]
            offset += 1
            if absentWhenNegative, size >= 0x80 { return .success(nil) }
            guard d.count - offset >= Int(size) else { return .failure(SatochipStatus(0x6700)) }
            guard size < 0x80, allowed(Int(size)) else { return .failure(SatochipStatus(0x9C0F)) }
            defer { offset += Int(size) }
            return .success(Data(d[offset ..< offset + Int(size)]))
        }
        let fields = [field(sizes: { $0 == 0 || $0 == 32 }, absentWhenNegative: false),
                      field(sizes: { $0 <= 32 }, absentWhenNegative: true),
                      field(sizes: { $0 <= 32 }, absentWhenNegative: false)]
        var values: [Data?] = []
        for field in fields {
            switch field {
            case let .success(value): values.append(value)
            case let .failure(status): return (Data(), status.word)
            }
        }
        let aggregate = values[0].flatMap { $0.isEmpty ? nil : $0 }
        guard let (secretNonce, publicNonce) = try? MuSig.nonceGenerate(
            secretKey: secret, publicKey: key.publicKey, aggregateKey: aggregate, message: values[1],
            extraInput: values[2], rand: SatochipEmulator.random(32))
        else { return (Data(), 0x6F00) }
        let id = nonceCounter
        guard id != 0 else {
            // Every id has been used: new keys invalidate every blob, and the counter restarts.
            validIDs = [UInt16](repeating: 0, count: 16)
            nonceCounter = 1
            nonceEncryptionKey = SatochipEmulator.random(16)
            nonceMACKey = SatochipEmulator.random(32)
            return (Data(), 0x9C46)
        }
        validIDs[Int(id & 15)] = id
        nonceCounter &+= 1
        var plaintext = secretNonce // k1 ‖ k2 ‖ pk (97 bytes)
        plaintext.append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xFF)])
        plaintext.append(Data(repeating: 13, count: 13))
        let iv = SatochipEmulator.random(16)
        guard let ciphertext = SatochipEmulator.cbcNoPadding(CCOperation(kCCEncrypt), key: nonceEncryptionKey,
                                                             iv: iv, input: plaintext)
        else { return (Data(), 0x6F00) }
        staged = ciphertext + iv + blobMAC(ciphertext + iv)
        return (publicNonce + Data([UInt8(id >> 8), UInt8(id & 0xFF)]), 0x9000)
    }

    private func sign(p1: UInt8, p2: UInt8, data: Data) -> (Data, UInt16) {
        guard musig2Policy == 0 else { return (Data(), 0x9C4A) }
        if p2 == 0x01 {
            guard data.count >= 144 else { return (Data(), 0x6700) }
            staged = data.prefix(144)
            return (Data(), 0x9000)
        }
        let d = Array(data)
        guard d.count >= 66 else { return (Data(), 0x6700) }
        guard (d[64] | d[65]) & 0xFE == 0 else { return (Data(), 0x9C0F) }
        if let twoFactorKey {
            guard d.count >= 88 else { return (Data(), 0x6700) }
            guard d[66] == 0x80, d[67] == 0x00 else { return (Data(), 0x9C09) }
            guard let expected = try? Satochip.twoFactorApproval(signingContext: Data(d[0 ..< 66]), key: twoFactorKey),
                  Data(d[66 ..< 88]) == expected
            else { return (Data(), 0x9C0B) }
        }
        guard let blob = staged, verifyBlob(blob) else { return (Data(), 0x9C44) }
        // From here on the applet clears its buffer on every exit.
        defer { staged = nil }
        guard let plaintext = SatochipEmulator.cbcNoPadding(CCOperation(kCCDecrypt), key: nonceEncryptionKey,
                                                            iv: blob.subdata(in: blob.startIndex + 112 ..< blob.startIndex + 128),
                                                            input: blob.prefix(112))
        else { return (Data(), 0x6F00) }
        let p = Array(plaintext)
        let id = UInt16(p[97]) << 8 | UInt16(p[98])
        guard let slot = validIDs.firstIndex(of: id), id != 0 else { return (Data(), 0x9C47) }
        validIDs[slot] = 0
        let (key, status) = signingKey(p1)
        guard let key, let secret = key.privateKey else { return (Data(), status) }
        guard Data(p[64 ..< 97]) == key.publicKey else { return (Data(), 0x9C45) }
        do {
            var k1 = try Secp256k1.ScalarModN(Data(p[0 ..< 32]))
            var k2 = try Secp256k1.ScalarModN(Data(p[32 ..< 64]))
            if d[64] == 0x01 {
                k1 = k1.negated
                k2 = k2.negated
            }
            var sk = try Secp256k1.ScalarModN(secret)
            if d[65] == 0x00 { sk = sk.negated }
            let b = try Secp256k1.ScalarModN(reducing: Data(d[0 ..< 32]))
            let ea = try Secp256k1.ScalarModN(reducing: Data(d[32 ..< 64]))
            return ((k1 + b * k2 + ea * sk).bytes, 0x9000)
        } catch {
            return (Data(), 0x6F00)
        }
    }

    private func setTwoFactor(_ data: Data) -> (Data, UInt16) {
        guard twoFactorKey == nil else { return (Data(), 0x9C18) }
        guard data.count >= 28 else { return (Data(), 0x6700) }
        twoFactorKey = data.prefix(20)
        return (Data(), 0x9000)
    }

    // MARK: - Encodings

    private func statusBytes() -> Data {
        Data([0, 16, 0, 1, isSetUp ? pinTriesLeft : 0, isSetUp ? pukTriesLeft : 0, 0, 0,
              twoFactorKey == nil ? 0 : 1, master == nil ? 0 : 1, isSetUp ? 1 : 0, 1, 0, 0, nostrPolicy, 0,
              musig2Policy, 0])
    }

    private func blobMAC(_ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: nonceMACKey)).prefix(16))
    }

    private func verifyBlob(_ blob: Data) -> Bool {
        blob.count == 144 && blobMAC(blob.prefix(128)) == blob.suffix(16)
    }

    private func sized(_ value: Data) -> Data {
        Data([UInt8(value.count >> 8), UInt8(value.count & 0xFF)]) + value
    }

    private func sw(_ word: UInt16) -> Data { Data([UInt8(word >> 8), UInt8(word & 0xFF)]) }

    /// DER for (r, s) = (1, 1): well formed, never a valid signature.
    static let placeholderSignature = Data([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01])

    static func random(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
    }

    static func randomKey() -> Secp256k1.PrivateKey {
        while true {
            if let key = try? Secp256k1.PrivateKey(random(32)) { return key }
        }
    }

    static func cbcNoPadding(_ operation: CCOperation, key: Data, iv: Data, input: Data) -> Data? {
        var output = Data(count: input.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), 0, keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress, inBytes.baseAddress, input.count, out.baseAddress, out.count, &moved)
                    }
                }
            }
        }
        return status == kCCSuccess && moved == input.count ? output : nil
    }
}

/// A status word as an Error, for the emulator's parsers.
struct SatochipStatus: Error {
    let word: UInt16
    init(_ word: UInt16) { self.word = word }
}
