import Foundation
import NativeSecp256k1
import P256K

/// One fuzz input, sliced into fixed-size fields (zero-padded when short),
/// fed to the native secp256k1 module and to libsecp256k1 through P256K.
/// The invariant: both backends accept or reject every operation together
/// and, when they accept, produce the same bytes, parity bit or verdict.
enum NativeSecp256k1Exercise {
    struct Fields {
        let secret: Data
        let tweak: Data
        let point: Data
        let message: Data
        let auxiliaryRand: Data
        let signature: Data
        let x: Data

        init(_ data: Data) {
            var cursor = data.startIndex
            func take(_ count: Int) -> Data {
                let available = min(count, data.endIndex - cursor)
                var field = Data(data[cursor ..< cursor + available])
                cursor += available
                field.append(Data(repeating: 0, count: count - available))
                return field
            }
            secret = take(32)
            tweak = take(32)
            point = take(33)
            message = take(32)
            auxiliaryRand = take(32)
            signature = take(64)
            x = take(32)
        }
    }

    static func run(_ data: Data) throws {
        let fields = Fields(data)
        try comparePrivateKeys(fields)
        try comparePublicKeys(fields)
        try compareXOnlyKeys(fields)
        try compareVerification(fields)
    }

    private static func comparePrivateKeys(_ fields: Fields) throws {
        let native = try? Secp256k1.PrivateKey(fields.secret)
        let reference = try? P256K.Signing.PrivateKey(dataRepresentation: fields.secret)
        try require((native == nil) == (reference == nil), "private key acceptance differs")
        guard let native, let reference else { return }
        try require(native.publicKey.compressed == reference.publicKey.dataRepresentation, "public key differs")

        let plain = try? native.adding(fields.tweak).bytes
        let plainReference = try? reference.add([UInt8](fields.tweak)).dataRepresentation
        try require(plain == plainReference, "private tweak differs")

        let schnorr = try P256K.Schnorr.PrivateKey(dataRepresentation: fields.secret)
        let xOnly = try? native.addingXOnly(fields.tweak).bytes
        let xOnlyReference = try? schnorr.add([UInt8](fields.tweak)).dataRepresentation
        try require(xOnly == xOnlyReference, "x-only private tweak differs")

        let signature = try Secp256k1.Schnorr.sign(message: fields.message, privateKey: native,
                                                   auxiliaryRand: fields.auxiliaryRand)
        var message = [UInt8](fields.message)
        var auxiliaryRand = [UInt8](fields.auxiliaryRand)
        let referenceSignature = try schnorr.signature(message: &message, auxiliaryRand: &auxiliaryRand)
        try require(signature == referenceSignature.dataRepresentation, "signature differs")
    }

    private static func comparePublicKeys(_ fields: Fields) throws {
        let native = try? Secp256k1.PublicKey(compressed: fields.point)
        let reference = try? P256K.Signing.PublicKey(dataRepresentation: fields.point, format: .compressed)
        try require((native == nil) == (reference == nil), "public key acceptance differs")
        guard let native, let reference else { return }
        try require(native.compressed == reference.dataRepresentation, "public key encoding differs")
        let tweaked = try? native.adding(fields.tweak).compressed
        let tweakedReference = try? reference.add([UInt8](fields.tweak), format: .compressed).dataRepresentation
        try require(tweaked == tweakedReference, "public tweak differs")
    }

    private static func compareXOnlyKeys(_ fields: Fields) throws {
        let native = try? Secp256k1.XOnlyKey(fields.x).adding(fields.tweak)
        let reference = try? P256K.Schnorr.XonlyKey(dataRepresentation: fields.x).add([UInt8](fields.tweak))
        try require((native == nil) == (reference == nil), "x-only tweak acceptance differs")
        guard let native, let reference else { return }
        try require(native.x == Data(reference.bytes), "x-only tweak differs")
        try require(native.parity == reference.parity, "x-only tweak parity differs")
    }

    private static func compareVerification(_ fields: Fields) throws {
        let native = Secp256k1.Schnorr.verify(signature: fields.signature, message: fields.message,
                                              publicKey: fields.x)
        var reference = false
        if let parsed = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: fields.signature) {
            var message = [UInt8](fields.message)
            reference = P256K.Schnorr.XonlyKey(dataRepresentation: fields.x).isValid(parsed, for: &message)
        }
        try require(native == reference, "verification verdict differs")
    }
}
