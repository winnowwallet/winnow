import Foundation
import NativeSecp256k1

public enum BIP86Error: Error, Equatable {
    /// The internal key is not 32 bytes or has no point on the curve.
    case invalidInternalKey
    /// The secret is not 32 bytes, is zero, or is not below the group order.
    case invalidPrivateKey
    /// The tweak produced an unusable key (probability about 2^-128).
    case tweakFailed
}

/// BIP86 single-key Taproot derivation: m/86'/coin'/account'/change/index.
public enum BIP86 {
    /// Derives the key at m/86'/coinType'/account'/change/index and returns its
    /// 32-byte Taproot internal x-only public key.
    public static func internalKey(from master: HDKey, coinType: UInt32 = 0,
                                   account: UInt32 = 0, change: UInt32 = 0, index: UInt32) throws -> Data {
        let key = try master.derived(path: "m/86'/\(coinType)'/\(account)'/\(change)/\(index)")
        return xonlyPublicKey(of: key)
    }

    /// The account-level extended key at m/86'/coinType'/account'.
    public static func accountKey(from master: HDKey, coinType: UInt32 = 0, account: UInt32 = 0) throws -> HDKey {
        try master.derived(path: "m/86'/\(coinType)'/\(account)'")
    }

    /// 32-byte x-only internal public key of any HD key.
    public static func xonlyPublicKey(of key: HDKey) -> Data {
        Data(key.publicKey.dropFirst())
    }

    /// BIP341 taptweak with no script tree: Q = P + H_taptweak(P)*G.
    public static func tweakedOutputKey(internalKey: Data) throws -> Data {
        guard let key = try? Secp256k1.XOnlyKey(internalKey) else { throw BIP86Error.invalidInternalKey }
        let tweak = TaggedHash.hash("TapTweak", key.x)
        guard let tweaked = try? key.adding(tweak) else { throw BIP86Error.tweakFailed }
        return tweaked.x
    }

    /// Tweaked private key matching `tweakedOutputKey` (key-path spending):
    /// the secret is negated first when its public key has an odd y.
    public static func tweakedPrivateKey(_ secret: Data) throws -> Data {
        guard let key = try? Secp256k1.PrivateKey(secret) else { throw BIP86Error.invalidPrivateKey }
        guard let tweaked = try? key.addingXOnly(tweak: { TaggedHash.hash("TapTweak", $0.x) }) else {
            throw BIP86Error.tweakFailed
        }
        return tweaked.bytes
    }

    /// BIP86 address: bech32m, witness v1, program = tweaked output key.
    public static func address(internalKey: Data, hrp: String = "bc") throws -> String {
        try SegwitAddress.encode(hrp: hrp, version: 1, program: tweakedOutputKey(internalKey: internalKey))
    }

    /// P2TR scriptPubKey: OP_1 <32-byte output key>.
    public static func scriptPubKey(internalKey: Data) throws -> Data {
        var script = Data([0x51, 0x20])
        script.append(try tweakedOutputKey(internalKey: internalKey))
        return script
    }
}
