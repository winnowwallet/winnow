import CommonCrypto
import CryptoKit
import Foundation
import NativeSecp256k1

extension Satochip {
    /// The two keys both ends derive from the ECDH x-coordinate s:
    /// HMAC-SHA1(s, "sc_key") truncated to an AES-128 key, and
    /// HMAC-SHA1(s, "sc_mac") for the command MAC (SecureChannel.java initiate).
    public struct ChannelKeys: Sendable, Equatable {
        public let encryption: Data
        public let mac: Data

        public init(sharedX: Data) {
            let key = SymmetricKey(data: sharedX)
            encryption = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data("sc_key".utf8), using: key).prefix(16))
            mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: Data("sc_mac".utf8), using: key))
        }

        /// HMAC-SHA1 under the MAC key, as commands carry it.
        public func authenticationCode(_ data: Data) -> Data {
            Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: mac)))
        }
    }

    /// x(k·P) for a peer that sent only P's x coordinate: both lifts of x give
    /// the same x(k·P), so the peer's parity is not needed. Variable-time in k,
    /// like the rest of the native module; k is a single-use channel key.
    public static func sharedX(privateKey: Secp256k1.PrivateKey, peerX: Data) throws -> Data {
        guard peerX.count == 32, let peer = try? Secp256k1.PublicKey(compressed: Data([0x02]) + peerX),
              let scalar = try? Secp256k1.ScalarModN(privateKey.bytes),
              let product = peer.multiplied(by: scalar)
        else { throw SatochipError.malformedResponse("secure channel key") }
        return Data(product.compressed.dropFirst())
    }

    /// AES-128-CBC with PKCS#7 padding, the channel's cipher (CommonCrypto:
    /// CryptoKit has no CBC mode).
    public enum AESCBC {
        public static func encrypt(key: Data, iv: Data, plaintext: Data) throws -> Data {
            try crypt(CCOperation(kCCEncrypt), key: key, iv: iv, input: plaintext)
        }

        public static func decrypt(key: Data, iv: Data, ciphertext: Data) throws -> Data {
            try crypt(CCOperation(kCCDecrypt), key: key, iv: iv, input: ciphertext)
        }

        private static func crypt(_ operation: CCOperation, key: Data, iv: Data, input: Data) throws -> Data {
            guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
                throw SatochipError.malformedResponse("AES key or IV length")
            }
            var output = Data(count: input.count + kCCBlockSizeAES128)
            var moved = 0
            let status = output.withUnsafeMutableBytes { out in
                input.withUnsafeBytes { inBytes in
                    key.withUnsafeBytes { keyBytes in
                        iv.withUnsafeBytes { ivBytes in
                            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                    keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                    inBytes.baseAddress, input.count, out.baseAddress, out.count, &moved)
                        }
                    }
                }
            }
            guard status == kCCSuccess else { throw SatochipError.malformedResponse("AES-CBC status \(status)") }
            return output.prefix(moved)
        }
    }

    /// The client end of the card's mandatory secure channel. Commands go as
    /// [IV | len | AES-CBC(apdu) | 0x0014 | HMAC-SHA1] inside a 0x82 APDU; the
    /// IV's last four bytes are a counter that must be odd and grow. Responses
    /// come back as [IV | len | ciphertext] without a MAC: the card does not
    /// authenticate them, so their content is checked where it matters (a
    /// partial signature is verified before use).
    public struct SecureChannel: Sendable {
        /// The card's identity key x coordinate, unauthenticated: this client
        /// does not check the card's ECDSA signatures (docs/satochip-musig2.md).
        public let cardAuthentikeyX: Data
        let keys: ChannelKeys
        private(set) var counter: UInt32 = 1

        /// INIT_SECURE_CHANNEL (0x81) with the 65-byte uncompressed key.
        public static func openingCommand(ephemeral: Secp256k1.PrivateKey) -> Data {
            Data([0xB0, 0x81, 0x00, 0x00, 65]) + ephemeral.publicKey.uncompressed
        }

        /// Reads the card's answer: [0x0020 | x(card key) | len | sig | len |
        /// sig by authentikey | 0x0020 | x(authentikey)].
        public init(ephemeral: Secp256k1.PrivateKey, response: Data) throws {
            var reader = Reader(response)
            let cardX = try reader.sized(exactly: 32)
            _ = try reader.sized()
            _ = try reader.sized()
            cardAuthentikeyX = try reader.sized(exactly: 32)
            keys = ChannelKeys(sharedX: try Satochip.sharedX(privateKey: ephemeral, peerX: cardX))
        }

        /// Wraps a plain command [CLA INS P1 P2 Lc data] in a 0x82 APDU.
        public mutating func wrap(_ command: Data, random: Data? = nil) throws -> Data {
            let random = random ?? MuSig.randomBytes(12)
            guard random.count == 12, counter < UInt32.max - 2 else { throw SatochipError.secureChannelLost }
            var iv = random
            withUnsafeBytes(of: counter.bigEndian) { iv.append(contentsOf: $0) }
            counter += 2
            let ciphertext = try AESCBC.encrypt(key: keys.encryption, iv: iv, plaintext: command)
            var body = iv
            body.append(contentsOf: [UInt8(ciphertext.count >> 8), UInt8(ciphertext.count & 0xFF)])
            body.append(ciphertext)
            let code = keys.authenticationCode(body)
            body.append(contentsOf: [0x00, UInt8(code.count)])
            body.append(code)
            guard body.count <= 255 else { throw SatochipError.commandTooLong }
            return Data([0xB0, 0x82, 0x00, 0x00, UInt8(body.count)]) + body
        }

        /// Decrypts a wrapped response; an empty response stays empty.
        public func unwrap(_ data: Data) throws -> Data {
            guard !data.isEmpty else { return Data() }
            guard data.count >= 18 else { throw SatochipError.malformedResponse("wrapped response of \(data.count) bytes") }
            let bytes = Data(data)
            let size = Int(bytes[16]) << 8 | Int(bytes[17])
            guard bytes.count == 18 + size, size % 16 == 0 else {
                throw SatochipError.malformedResponse("wrapped response length")
            }
            return try AESCBC.decrypt(key: keys.encryption, iv: bytes.prefix(16), ciphertext: bytes.suffix(size))
        }
    }

    /// Reads the card's [size(2) | bytes] fields.
    struct Reader {
        private let bytes: [UInt8]
        private(set) var offset = 0

        init(_ data: Data) { bytes = Array(data) }

        var remaining: Int { bytes.count - offset }

        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, remaining >= count else { throw SatochipError.malformedResponse("short response") }
            defer { offset += count }
            return Data(bytes[offset ..< offset + count])
        }

        mutating func sized(exactly expected: Int? = nil) throws -> Data {
            let header = try take(2)
            let size = Int(header[header.startIndex]) << 8 | Int(header[header.startIndex + 1])
            if let expected, size != expected { throw SatochipError.malformedResponse("field of \(size) bytes") }
            return try take(size)
        }
    }
}
