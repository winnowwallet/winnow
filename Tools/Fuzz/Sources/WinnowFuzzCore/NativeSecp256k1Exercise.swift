import Foundation
import NativeSecp256k1

/// One fuzz input, sliced into fixed-size fields (zero-padded when short),
/// fed to the native secp256k1 module. The build links no second curve
/// implementation, so the invariants are the module's own algebra: the
/// private and public forms of every operation accept, reject and compute
/// alike; acceptance follows the BIP340 range rules; nothing traps; a fresh
/// signature verifies under its own key and under nothing else; malformed
/// lengths never verify. Byte-for-byte agreement with libsecp256k1 is the
/// recorded-vector suites' job (Tests/BitcoinCoreTests/NativeSecp256k1*Tests).
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

    /// The group order n, big-endian: the bound every secret and tweak must stay below.
    private static let order = Data([
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B, 0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
    ])

    /// Numeric comparison of 32 big-endian bytes against n.
    private static func isBelowOrder(_ bytes: Data) -> Bool {
        bytes.count == 32 && bytes.lexicographicallyPrecedes(order)
    }

    static func run(_ data: Data) throws {
        let fields = Fields(data)
        try checkPrivateKey(fields)
        try checkPublicKey(fields)
        try checkXOnlyKey(fields)
        try checkVerification(fields)
    }

    private static func checkPrivateKey(_ fields: Fields) throws {
        let key = try? Secp256k1.PrivateKey(fields.secret)
        let inRange = isBelowOrder(fields.secret) && fields.secret.contains { $0 != 0 }
        try require((key != nil) == inRange, "private key acceptance differs from the BIP340 range rule")
        guard let key else { return }
        try require(key.bytes == fields.secret, "private key bytes changed")

        let publicKey = key.publicKey
        let reparsed = try? Secp256k1.PublicKey(compressed: publicKey.compressed)
        try require(reparsed?.compressed == publicKey.compressed, "public key does not round-trip")
        try require(publicKey.xOnlyKey == key.xOnlyKey, "x-only key differs between private and public forms")
        try require(publicKey.compressed.first == (key.xOnlyKey.parity ? 0x03 : 0x02), "parity disagrees with the prefix")
        try require(publicKey.compressed.dropFirst() == key.xOnlyKey.x, "x-only key is not the compressed x")
        try require((try? Secp256k1.XOnlyKey(key.xOnlyKey.x))?.x == key.xOnlyKey.x, "x-only key does not parse")

        // Tweaking the secret agrees with tweaking the point it generates.
        let tweakAccepted = isBelowOrder(fields.tweak)
        let tweakedSecret = try? key.adding(fields.tweak)
        let tweakedPublic = try? publicKey.adding(fields.tweak)
        try require((tweakedSecret == nil) == (tweakedPublic == nil), "private and public tweak acceptance differ")
        try require(tweakAccepted || tweakedSecret == nil, "a tweak of n or more was accepted")
        if let tweakedSecret, let tweakedPublic {
            try require(tweakedSecret.publicKey.compressed == tweakedPublic.compressed, "private and public tweaks differ")
        }
        let xOnlySecret = try? key.addingXOnly(fields.tweak)
        let xOnlyPublic = try? key.xOnlyKey.adding(fields.tweak)
        try require((xOnlySecret == nil) == (xOnlyPublic == nil), "x-only private and public tweak acceptance differ")
        if let xOnlySecret, let xOnlyPublic {
            try require(xOnlySecret.xOnlyKey.x == xOnlyPublic.x && xOnlySecret.xOnlyKey.parity == xOnlyPublic.parity,
                        "x-only private and public tweaks differ")
        }

        try checkSigning(fields, key: key)
    }

    private static func checkSigning(_ fields: Fields, key: Secp256k1.PrivateKey) throws {
        let x = key.xOnlyKey.x
        let signature = try Secp256k1.Schnorr.sign(message: fields.message, privateKey: key,
                                                   auxiliaryRand: fields.auxiliaryRand)
        try require(signature.count == 64, "signature is not 64 bytes")
        try require(Secp256k1.Schnorr.verify(signature: signature, message: fields.message, publicKey: x),
                    "fresh signature does not verify")
        let again = try Secp256k1.Schnorr.sign(message: fields.message, privateKey: key, auxiliaryRand: fields.auxiliaryRand)
        try require(again == signature, "signing is not deterministic")

        // Any change to the signature, the message or the key breaks it.
        var mutated = signature
        let byte = Int(fields.tweak[fields.tweak.startIndex]) % 64
        mutated[mutated.startIndex + byte] ^= UInt8(1 << (Int(fields.tweak[fields.tweak.startIndex + 1]) % 8))
        try require(!Secp256k1.Schnorr.verify(signature: mutated, message: fields.message, publicKey: x),
                    "a mutated signature verified")
        try require(!Secp256k1.Schnorr.verify(signature: signature, message: fields.message + Data([0]), publicKey: x),
                    "a signature verified for an extended message")
        if let other = try? key.adding(fields.tweak).xOnlyKey.x, other != x {
            try require(!Secp256k1.Schnorr.verify(signature: signature, message: fields.message, publicKey: other),
                        "a signature verified under another key")
        }
    }

    private static func checkPublicKey(_ fields: Fields) throws {
        let parsed = try? Secp256k1.PublicKey(compressed: fields.point)
        let prefix = fields.point.first
        let x = fields.point.dropFirst()
        if prefix != 0x02, prefix != 0x03 {
            try require(parsed == nil, "a compressed key with a bad prefix parsed")
        }
        // The compressed parser and the x-only parser agree on which x values lie on the curve.
        let evenPoint = try? Secp256k1.PublicKey(compressed: Data([0x02]) + x)
        let xOnly = try? Secp256k1.XOnlyKey(x)
        try require((evenPoint == nil) == (xOnly == nil), "compressed and x-only acceptance differ")
        guard let parsed else { return }
        try require(parsed.compressed == fields.point, "compressed encoding is not canonical")
        try require(parsed.xOnlyKey.x == x, "x-only key is not the compressed x")
        try require(parsed.xOnlyKey.parity == (prefix == 0x03), "parity disagrees with the prefix")
        try require((try? parsed.adding(Data(repeating: 0, count: 32)))?.compressed == parsed.compressed,
                    "a zero tweak changed the key")
        // On the even point, tweaking as a point and as an x-only key agree.
        if let evenPoint, let tweakedPoint = try? evenPoint.adding(fields.tweak) {
            let tweakedXOnly = try? xOnly?.adding(fields.tweak)
            try require(tweakedXOnly?.x == tweakedPoint.xOnlyKey.x && tweakedXOnly?.parity == tweakedPoint.xOnlyKey.parity,
                        "point and x-only tweaks differ")
        }
    }

    private static func checkXOnlyKey(_ fields: Fields) throws {
        let xOnly = try? Secp256k1.XOnlyKey(fields.x)
        let asPoint = try? Secp256k1.PublicKey(compressed: Data([0x02]) + fields.x)
        try require((xOnly == nil) == (asPoint == nil), "x-only and compressed acceptance differ")
        guard let xOnly, let asPoint else { return }
        try require(!xOnly.parity && xOnly.x == fields.x, "lift_x is not the even point")
        try require(asPoint.xOnlyKey == xOnly, "x-only key differs from the even point's")
        let tweaked = try? xOnly.adding(fields.tweak)
        let tweakedPoint = try? asPoint.adding(fields.tweak)
        try require((tweaked == nil) == (tweakedPoint == nil), "x-only and compressed tweak acceptance differ")
        try require(isBelowOrder(fields.tweak) || tweaked == nil, "a tweak of n or more was accepted")
        if let tweaked, let tweakedPoint {
            try require(tweaked.x == tweakedPoint.xOnlyKey.x && tweaked.parity == tweakedPoint.xOnlyKey.parity,
                        "x-only and compressed tweaks differ")
        }
    }

    private static func checkVerification(_ fields: Fields) throws {
        let verdict = Secp256k1.Schnorr.verify(signature: fields.signature, message: fields.message, publicKey: fields.x)
        if (try? Secp256k1.XOnlyKey(fields.x)) == nil {
            try require(!verdict, "a signature verified under an invalid key")
        }
        try require(!Secp256k1.Schnorr.verify(signature: fields.signature.prefix(63), message: fields.message,
                                              publicKey: fields.x), "a 63-byte signature verified")
        try require(!Secp256k1.Schnorr.verify(signature: fields.signature + Data([0]), message: fields.message,
                                              publicKey: fields.x), "a 65-byte signature verified")
        try require(!Secp256k1.Schnorr.verify(signature: fields.signature, message: fields.message,
                                              publicKey: fields.x.prefix(31)), "a 31-byte key verified")
        // The seed corpus carries a valid signature: once something verifies,
        // every change to it, its message or its key must stop it verifying.
        guard verdict else { return }
        for byte in [0, 31, 32, 63] {
            var mutated = fields.signature
            mutated[mutated.startIndex + byte] ^= 0x01
            try require(!Secp256k1.Schnorr.verify(signature: mutated, message: fields.message, publicKey: fields.x),
                        "a mutated valid signature still verified")
        }
        try require(!Secp256k1.Schnorr.verify(signature: fields.signature, message: fields.message + Data([0]),
                                              publicKey: fields.x), "a valid signature verified for an extended message")
        var otherKey = fields.x
        otherKey[otherKey.startIndex + 31] ^= 0x01
        try require(!Secp256k1.Schnorr.verify(signature: fields.signature, message: fields.message, publicKey: otherKey),
                    "a valid signature verified under a changed key")
    }
}
