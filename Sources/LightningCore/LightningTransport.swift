import Foundation

/// Authenticated BOLT 8 frames, with independent directional key rotation.
/// One actor/connection must own this non-Sendable object and preserve write
/// ordering. Ciphertext may be replayed on the same socket after a short write;
/// callers must never call encrypt again to regenerate part of a frame.
public final class LightningTransport {
    public let remotePublicKey: Data
    public private(set) var isClosed = false
    private var sender: Cipher, receiver: Cipher
    private var buffered = Data()
    private var expectedLength: Int?

    init(remotePublicKey: Data, chainingKey: Data, sendKey: Data, receiveKey: Data) {
        self.remotePublicKey = remotePublicKey
        sender = Cipher(chain: chainingKey, key: sendKey)
        receiver = Cipher(chain: chainingKey, key: receiveKey)
    }

    public func encrypt(_ message: Data) throws -> Data {
        guard !isClosed else { throw LightningError.closed }
        guard message.count <= 65535 else { throw LightningError.invalidMessage }
        do {
            let size = UInt16(message.count)
            let length = Data([UInt8(size >> 8), UInt8(size & 0xff)])
            return try sender.encrypt(length) + sender.encrypt(message)
        } catch { close(); throw error }
    }

    /// Accept arbitrary socket fragmentation. Bound each read; callers can
    /// feed larger application buffers in chunks. No plaintext leaves until its
    /// own authentication succeeds. Any malformed frame closes both directions.
    public func receive(_ bytes: Data) throws -> [Data] {
        guard !isClosed else { throw LightningError.closed }
        guard bytes.count <= 131_072 else { close(); throw LightningError.invalidMessage }
        buffered.append(bytes)
        do {
            var messages: [Data] = []
            while let next = try readMessage() { messages.append(next) }
            return messages
        } catch { close(); throw error }
    }

    public func close() {
        isClosed = true; buffered = Data(); expectedLength = nil
        sender = Cipher(chain: Data(), key: Data()); receiver = sender
    }

    private func readMessage() throws -> Data? {
        if expectedLength == nil {
            guard buffered.count >= 18 else { return nil }
            let length = try receiver.decrypt(take(18))
            guard length.count == 2 else { throw LightningError.invalidMessage }
            expectedLength = Int(length[length.startIndex]) << 8 | Int(length[length.startIndex + 1])
        }
        guard let size = expectedLength, buffered.count >= size + 16 else { return nil }
        let message = try receiver.decrypt(take(size + 16))
        expectedLength = nil
        return message
    }
    private func take(_ count: Int) -> Data {
        let result = Data(buffered.prefix(count))
        buffered.removeFirst(count)
        return result
    }

    private struct Cipher {
        var chain: Data, key: Data
        var nonce: UInt64 = 0
        mutating func encrypt(_ bytes: Data) throws -> Data {
            let result = try NoiseCrypto.encrypt(bytes, key: key, nonce: nonce)
            advance()
            return result
        }
        mutating func decrypt(_ bytes: Data) throws -> Data {
            let result = try NoiseCrypto.decrypt(bytes, key: key, nonce: nonce)
            advance()
            return result
        }
        mutating func advance() {
            nonce += 1
            if nonce == 1000 {
                (chain, key) = NoiseCrypto.hkdf(salt: chain, input: key)
                nonce = 0
            }
        }
    }
}
