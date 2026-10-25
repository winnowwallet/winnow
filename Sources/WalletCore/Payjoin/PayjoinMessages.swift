import Foundation
import P256K

/// BIP 77's two end-to-end encrypted messages, 7,168 bytes each so the
/// directory cannot tell them apart: Message A (sender → receiver, HPKE
/// Base mode, `PjV2MsgA`) carries the sender's 33-byte reply key and the
/// Original PSBT; Message B (receiver → sender, HPKE Auth mode under the
/// receiver key, `PjV2MsgB`) carries the Proposal PSBT. The HPKE `enc` is
/// written as 64 ElligatorSwift bytes and the plaintext is zero-padded to
/// the fixed size, as the reference implementation does. Both directions
/// are here so a test receiver can answer the wallet.
///
/// Exercised by `PayjoinMessageTests`.
public enum PayjoinMessage {
    public enum Failure: Error, Equatable {
        case payloadTooLarge(actual: Int, max: Int)
        case wrongLength
        case invalidKey
    }

    public typealias Suite = HPKE.Suite<HPKE.Secp256k1, HPKE.ChaChaPolyAEAD>
    public typealias PrivateKey = HPKE.Secp256k1.PrivateKey
    public typealias PublicKey = HPKE.Secp256k1.PublicKey

    public static let messageBytes = 7_168
    static let ellswiftBytes = 64
    static let tagBytes = 16
    static let replyKeyBytes = 33
    /// 7,168 − 64 − 33 − 16.
    public static let plaintextABytes = messageBytes - ellswiftBytes - replyKeyBytes - tagBytes
    /// 7,168 − 64 − 16.
    public static let plaintextBBytes = messageBytes - ellswiftBytes - tagBytes
    static let infoA = Data("PjV2MsgA".utf8)
    static let infoB = Data("PjV2MsgB".utf8)

    /// Message A: `body` (the Original PSBT and parameters, or empty for a
    /// poll) to `receiverKey`, naming `replyKey` as where to answer.
    public static func encryptA(body: Data, replyKey: PublicKey, receiverKey: PublicKey) throws -> Data {
        let plaintext = HPKE.Secp256k1.compressed(replyKey) + (try padded(body, to: plaintextABytes))
        var (enc, context) = try Suite.setupSender(recipient: receiverKey, info: infoA)
        return try wireEncapsulation(enc) + context.seal(plaintext: plaintext)
    }

    /// Receiver side of Message A: the padded body and the sender's reply key.
    public static func decryptA(_ message: Data, receiverKey: PrivateKey) throws -> (body: Data, replyKey: PublicKey) {
        let (enc, ciphertext) = try splitWire(message)
        var context = try Suite.setupRecipient(enc: enc, recipient: receiverKey, info: infoA)
        let plaintext = try context.open(ciphertext: ciphertext)
        guard plaintext.count >= replyKeyBytes else { throw Failure.wrongLength }
        let replyKey = try HPKE.Secp256k1.publicKey(compressed: Data(plaintext.prefix(replyKeyBytes)))
        return (Data(plaintext.dropFirst(replyKeyBytes)), replyKey)
    }

    /// Message B: `body` (the Proposal PSBT or a JSON error) to the sender's
    /// reply key, authenticated by the receiver key the sender already holds.
    public static func encryptB(body: Data, receiverKey: PrivateKey, replyKey: PublicKey) throws -> Data {
        var (enc, context) = try Suite.setupAuthSender(recipient: replyKey, sender: receiverKey, info: infoB)
        return try wireEncapsulation(enc) + context.seal(plaintext: padded(body, to: plaintextBBytes))
    }

    /// Sender side of Message B: the padded body, or a failure when it was
    /// not sealed by `receiverKey` for this reply key.
    public static func decryptB(_ message: Data, receiverKey: PublicKey, replyKey: PrivateKey) throws -> Data {
        let (enc, ciphertext) = try splitWire(message)
        var context = try Suite.setupAuthRecipient(enc: enc, recipient: replyKey, sender: receiverKey, info: infoB)
        return try context.open(ciphertext: ciphertext)
    }

    /// Strips the zero padding a message body carries: everything after the
    /// last non-zero byte. Protocol bodies (base64 text, JSON) never end in
    /// a NUL.
    public static func unpadded(_ body: Data) -> Data {
        guard let last = body.lastIndex(where: { $0 != 0 }) else { return Data() }
        return Data(body[...last])
    }

    static func padded(_ body: Data, to length: Int) throws -> Data {
        guard body.count <= length else { throw Failure.payloadTooLarge(actual: body.count, max: length) }
        return body + Data(count: length - body.count)
    }

    /// The HPKE `enc` (65-byte uncompressed point) as ElligatorSwift bytes.
    static func wireEncapsulation(_ enc: Data) throws -> Data {
        let key = try HPKE.Secp256k1.deserialize(enc)
        return try ElligatorSwift.encode(publicKey: HPKE.Secp256k1.compressed(key))
    }

    static func splitWire(_ message: Data) throws -> (enc: Data, ciphertext: Data) {
        guard message.count == messageBytes else { throw Failure.wrongLength }
        let compressed = try ElligatorSwift.decode(Data(message.prefix(ellswiftBytes)))
        let key = try HPKE.Secp256k1.publicKey(compressed: compressed)
        return (HPKE.Secp256k1.serialize(key), Data(message.dropFirst(ellswiftBytes)))
    }
}
