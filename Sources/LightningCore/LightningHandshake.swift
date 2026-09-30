import Foundation
import P256K

/// BOLT 8 Noise_XK. A single owner supplies complete acts (50/50/66 bytes).
/// This reference type deliberately isn't Sendable and exposes no state-cloning
/// API: a failed or completed transcript cannot resume and reuse key material.
public final class LightningHandshake {
    public enum Role { case initiator, responder }
    private enum Stage { case start, actOne, actTwo, actThree, closed }
    private var stage: Stage
    private let role: Role
    private var secret: Data, ephemeral: Data, remote: Data, remoteEphemeral = Data()
    private var chain: Data, transcript: Data, temporaryKey = Data()

    public convenience init(role: Role, localSecret: Data, remotePublicKey: Data? = nil) throws {
        let fresh = try P256K.Signing.PrivateKey().dataRepresentation
        try self.init(role: role, localSecret: localSecret, remotePublicKey: remotePublicKey, ephemeral: fresh)
    }
    // Test-only injection; not exposed to external callers.
    init(role: Role, localSecret: Data, remotePublicKey: Data?, ephemeral: Data) throws {
        let local = try ChannelKeys.publicKey(secret: localSecret)
        _ = try ChannelKeys.publicKey(secret: ephemeral)
        self.role = role; secret = localSecret; self.ephemeral = ephemeral
        if role == .initiator {
            guard let remotePublicKey else { throw LightningError.invalidKey }
            _ = try ChannelKeys.point(remotePublicKey)
            remote = remotePublicKey; stage = .start
        } else {
            guard remotePublicKey == nil else { throw LightningError.invalidKey }
            remote = Data(); stage = .actOne
        }
        chain = ChannelKeys.hash(Data("Noise_XK_secp256k1_ChaChaPoly_SHA256".utf8))
        transcript = ChannelKeys.hash(ChannelKeys.hash(chain + Data("lightning".utf8))
                                      + (role == .initiator ? remote : local))
    }

    public func start() throws -> Data {
        guard stage == .start else { throw LightningError.invalidState }
        do {
            let point = try ChannelKeys.publicKey(secret: ephemeral)
            mix(point); try mixKey(secret: ephemeral, point: remote)
            let tag = try NoiseCrypto.encrypt(Data(), key: temporaryKey, nonce: 0, associated: transcript)
            mix(tag); stage = .actTwo
            return Data([0]) + point + tag
        } catch { close(); throw error }
    }

    public func receive(_ act: Data) throws -> (reply: Data?, transport: LightningTransport?) {
        guard stage != .closed else { throw LightningError.closed }
        do {
            switch stage {
            case .actOne: return (try readOne(act), nil)
            case .actTwo:
                let reply = try readTwo(act)
                return (reply, finish())
            case .actThree:
                try readThree(act)
                return (nil, finish())
            default: throw LightningError.invalidState
            }
        } catch { close(); throw error }
    }

    public func close() {
        stage = .closed; secret = Data(); ephemeral = Data(); temporaryKey = Data(); chain = Data()
    }

    private func readOne(_ act: Data) throws -> Data {
        try check(act, length: 50)
        remoteEphemeral = Data(act.dropFirst().prefix(33))
        mix(remoteEphemeral); try mixKey(secret: secret, point: remoteEphemeral)
        _ = try NoiseCrypto.decrypt(Data(act.suffix(16)), key: temporaryKey, nonce: 0, associated: transcript)
        mix(Data(act.suffix(16)))
        let point = try ChannelKeys.publicKey(secret: ephemeral)
        mix(point); try mixKey(secret: ephemeral, point: remoteEphemeral)
        let tag = try NoiseCrypto.encrypt(Data(), key: temporaryKey, nonce: 0, associated: transcript)
        mix(tag); stage = .actThree
        return Data([0]) + point + tag
    }
    private func readTwo(_ act: Data) throws -> Data {
        try check(act, length: 50)
        remoteEphemeral = Data(act.dropFirst().prefix(33))
        mix(remoteEphemeral); try mixKey(secret: ephemeral, point: remoteEphemeral)
        _ = try NoiseCrypto.decrypt(Data(act.suffix(16)), key: temporaryKey, nonce: 0, associated: transcript)
        mix(Data(act.suffix(16)))
        let encrypted = try NoiseCrypto.encrypt(ChannelKeys.publicKey(secret: secret), key: temporaryKey,
                                                nonce: 1, associated: transcript)
        mix(encrypted); try mixKey(secret: secret, point: remoteEphemeral)
        let tag = try NoiseCrypto.encrypt(Data(), key: temporaryKey, nonce: 0, associated: transcript)
        return Data([0]) + encrypted + tag
    }
    private func readThree(_ act: Data) throws {
        try check(act, length: 66)
        let encrypted = Data(act.dropFirst().prefix(49))
        remote = try NoiseCrypto.decrypt(encrypted, key: temporaryKey, nonce: 1, associated: transcript)
        _ = try ChannelKeys.point(remote)
        mix(encrypted); try mixKey(secret: ephemeral, point: remote)
        _ = try NoiseCrypto.decrypt(Data(act.suffix(16)), key: temporaryKey, nonce: 0, associated: transcript)
    }
    private func finish() -> LightningTransport {
        let (first, second) = NoiseCrypto.hkdf(salt: chain, input: Data())
        let transport = LightningTransport(remotePublicKey: remote, chainingKey: chain,
            sendKey: role == .initiator ? first : second, receiveKey: role == .initiator ? second : first)
        close()
        return transport
    }
    private func mix(_ data: Data) { transcript = ChannelKeys.hash(transcript + data) }
    private func mixKey(secret: Data, point: Data) throws {
        (chain, temporaryKey) = NoiseCrypto.hkdf(salt: chain, input: try NoiseCrypto.ecdh(secret: secret, point: point))
    }
    private func check(_ act: Data, length: Int) throws {
        guard act.count == length, act.first == 0 else { throw LightningError.invalidMessage }
    }
}
