import CryptoKit
import Foundation
import P256K

enum NoiseCrypto {
    static func ecdh(secret: Data, point: Data) throws -> Data {
        _ = try ChannelKeys.point(point)
        let key = try P256K.KeyAgreement.PrivateKey(dataRepresentation: secret)
        let peer = try P256K.KeyAgreement.PublicKey(dataRepresentation: point)
        return ChannelKeys.hash(Data(key.sharedSecretFromKeyAgreement(with: peer, format: .compressed).bytes))
    }
    static func hkdf(salt: Data, input: Data) -> (Data, Data) {
        let result = HKDF<CryptoKit.SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: input),
            salt: salt, info: Data(), outputByteCount: 64)
        let bytes = result.withUnsafeBytes { Data($0) }
        return (Data(bytes.prefix(32)), Data(bytes.suffix(32)))
    }
    static func encrypt(_ data: Data, key: Data, nonce: UInt64, associated: Data = Data()) throws -> Data {
        let box = try ChaChaPoly.seal(data, using: SymmetricKey(data: key),
                                     nonce: iv(nonce), authenticating: associated)
        return box.ciphertext + box.tag
    }
    static func decrypt(_ data: Data, key: Data, nonce: UInt64, associated: Data = Data()) throws -> Data {
        guard data.count >= 16 else { throw LightningError.invalidMessage }
        let box = try ChaChaPoly.SealedBox(nonce: iv(nonce), ciphertext: data.dropLast(16), tag: data.suffix(16))
        do { return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: associated) }
        catch { throw LightningError.authenticationFailed }
    }
    private static func iv(_ value: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        Swift.withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }
}
