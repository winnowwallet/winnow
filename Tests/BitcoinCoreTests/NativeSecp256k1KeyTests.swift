import Foundation
import NativeSecp256k1
import Testing
import TestSupport
@testable import WalletCore

/// The native key types against recorded libsecp256k1 answers (see
/// Vectors/native-secp256k1/README.md): every accept/reject decision,
/// encoding, parity bit and tweak result must match, including the boundary
/// inputs that distinguish the rules. What the C library leaves to its
/// callers (wrong lengths) is checked directly.
@Suite("Native secp256k1 keys against recorded libsecp256k1 answers")
struct NativeSecp256k1KeyTests {
    struct PrivateKeyVector: Decodable {
        let name: String
        let secret: String
        let publicKey: String?
        let xOnly: String?
        let parity: Bool?
    }

    struct PublicKeyVector: Decodable {
        let name: String
        let input: String
        let compressed: String?
    }

    struct XOnlyPoint: Decodable {
        let x: String
        let parity: Bool
    }

    struct TweakVector: Decodable {
        let name: String
        let secret: String
        let tweak: String
        let privateTweak: String?
        let xOnlyPrivateTweak: String?
        let publicTweak: String?
        let xOnlyPublicTweak: XOnlyPoint?
    }

    struct XOnlyTweakResult: Decodable {
        let tweak: String
        let x: String?
        let parity: Bool?
    }

    struct XOnlyTweakVector: Decodable {
        let name: String
        let x: String
        let results: [XOnlyTweakResult]
    }

    static func fixture<T: Decodable>(_ name: String) throws -> T {
        try Vectors.decode(T.self, name + ".json", in: .module, subdirectory: "Vectors/native-secp256k1")
    }

    static func bytes(_ hex: String) throws -> Data {
        hex.isEmpty ? Data() : try #require(Data(hex: hex), "hex \(hex)")
    }

    // MARK: - Parsing and public keys

    @Test("private keys are accepted, rejected and expanded exactly like libsecp256k1")
    func privateKeys() throws {
        let vectors: [PrivateKeyVector] = try Self.fixture("private-keys")
        #expect(vectors.count == 17)
        var accepted = 0
        for vector in vectors {
            let secret = try Self.bytes(vector.secret)
            let native = try? Secp256k1.PrivateKey(secret)
            #expect((native == nil) == (vector.publicKey == nil), "accept/reject \(vector.name)")
            guard let native, let publicKey = vector.publicKey, let xOnly = vector.xOnly, let parity = vector.parity
            else { continue }
            accepted += 1
            #expect(native.bytes == secret, "\(vector.name)")
            #expect(native.publicKey.compressed.hex == publicKey, "\(vector.name)")
            #expect(native.xOnlyKey.x.hex == xOnly, "\(vector.name)")
            #expect(native.xOnlyKey.parity == parity, "parity \(vector.name)")
            #expect(native.publicKey.xOnlyKey == native.xOnlyKey, "\(vector.name)")
        }
        // Eight derived secrets, 1 and n − 1; zero, n, n + 1, all ones and the wrong lengths are refused.
        #expect(accepted == 10)
    }

    @Test("compressed public keys parse identically, including junk prefixes and lengths")
    func publicKeys() throws {
        let vectors: [PublicKeyVector] = try Self.fixture("public-keys")
        #expect(vectors.count == 55)
        var accepted = 0
        for vector in vectors {
            let input = try Self.bytes(vector.input)
            let native = try? Secp256k1.PublicKey(compressed: input)
            #expect((native == nil) == (vector.compressed == nil), "accept/reject \(vector.name)")
            guard let native, let compressed = vector.compressed else { continue }
            accepted += 1
            #expect(native.compressed.hex == compressed, "\(vector.name)")
            #expect(native.compressed == input, "\(vector.name)")
        }
        #expect(accepted == 12)
    }

    // MARK: - Tweaks

    @Test("private, x-only private, public and x-only public tweak-add match libsecp256k1, zero and overflow included")
    func tweaks() throws {
        let vectors: [TweakVector] = try Self.fixture("tweaks")
        #expect(vectors.count == 52)
        var plainCount = 0, xOnlyPlainCount = 0, publicCount = 0, xOnlyPublicCount = 0
        for vector in vectors {
            let key = try Secp256k1.PrivateKey(try Self.bytes(vector.secret))
            let tweak = try Self.bytes(vector.tweak)

            let plain = try? key.adding(tweak)
            #expect(plain?.bytes.hex == vector.privateTweak, "private tweak \(vector.name)")
            let xOnlyPlain = try? key.addingXOnly(tweak)
            #expect(xOnlyPlain?.bytes.hex == vector.xOnlyPrivateTweak, "x-only private tweak \(vector.name)")
            let publicSum = try? key.publicKey.adding(tweak)
            #expect(publicSum?.compressed.hex == vector.publicTweak, "public tweak \(vector.name)")
            let xOnlySum = try? key.xOnlyKey.adding(tweak)
            #expect(xOnlySum?.x.hex == vector.xOnlyPublicTweak?.x, "x-only public tweak \(vector.name)")
            #expect(xOnlySum?.parity == vector.xOnlyPublicTweak?.parity, "x-only public tweak parity \(vector.name)")

            // Tweaking the secret agrees with tweaking the point it generates.
            if let plain { plainCount += 1; #expect(plain.publicKey.compressed == publicSum?.compressed, "\(vector.name)") }
            if let publicSum { publicCount += 1; #expect(publicSum.compressed.hex == vector.publicTweak, "\(vector.name)") }
            if let xOnlyPlain {
                xOnlyPlainCount += 1
                #expect(xOnlyPlain.xOnlyKey.x == xOnlySum?.x && xOnlyPlain.xOnlyKey.parity == xOnlySum?.parity, "\(vector.name)")
            }
            if xOnlySum != nil { xOnlyPublicCount += 1 }

            // The refusal reasons the library folds into one return code.
            if vector.name.hasSuffix("-order") {
                #expect(throws: Secp256k1Error.invalidTweak) { try key.adding(tweak) }
                #expect(throws: Secp256k1Error.invalidTweak) { try key.addingXOnly(tweak) }
                #expect(throws: Secp256k1Error.invalidTweak) { try key.publicKey.adding(tweak) }
                #expect(throws: Secp256k1Error.invalidTweak) { try key.xOnlyKey.adding(tweak) }
            }
            if vector.name.hasSuffix("-order-minus-secret") {
                // n − d makes the plain sum zero and the public sum infinity.
                #expect(throws: Secp256k1Error.invalidResult) { try key.adding(tweak) }
                #expect(throws: Secp256k1Error.invalidResult) { try key.publicKey.adding(tweak) }
            }
            if vector.name.hasPrefix("infinity-") {
                // The negation of lift_x(x)'s discrete log: the x-only sums are zero and infinity.
                #expect(throws: Secp256k1Error.invalidResult) { try key.addingXOnly(tweak) }
                #expect(throws: Secp256k1Error.invalidResult) { try key.xOnlyKey.adding(tweak) }
            }
        }
        #expect(plainCount == 34 && publicCount == 34)
        #expect(xOnlyPlainCount == 36 && xOnlyPublicCount == 36)
    }

    @Test("x-only tweak-add matches xonly_pubkey_tweak_add in bytes and parity on 89 keys")
    func xOnlyTweaks() throws {
        let vectors: [XOnlyTweakVector] = try Self.fixture("xonly-tweaks")
        #expect(vectors.count == 89)
        var agreedValid = 0
        for vector in vectors {
            let x = try Self.bytes(vector.x)
            let parses = (try? Secp256k1.XOnlyKey(x)) != nil
            #expect(vector.results.count == 5, "\(vector.name)")
            for result in vector.results {
                let tweak = try Self.bytes(result.tweak)
                let native = try? Secp256k1.XOnlyKey(x).adding(tweak)
                #expect((native == nil) == (result.x == nil), "accept/reject \(vector.name) + \(result.tweak)")
                guard let native, let expectedX = result.x else { continue }
                agreedValid += 1
                #expect(native.x.hex == expectedX, "\(vector.name) + \(result.tweak)")
                #expect(native.parity == result.parity, "parity \(vector.name) + \(result.tweak)")
                #expect(parses, "\(vector.name)")
            }
        }
        // 43 valid fixture keys plus eight derived ones, each with the four tweaks below n.
        #expect(agreedValid == (43 + 8) * 4)
    }

    @Test("wrong lengths are refused by the rules the C API leaves to its callers")
    func wrongLengths() throws {
        let key = try Secp256k1.PrivateKey(Data(repeating: 0x42, count: 32))
        for length in [0, 31, 33, 64] {
            let tweak = Data(repeating: 1, count: length)
            #expect(throws: Secp256k1Error.invalidTweak) { try key.adding(tweak) }
            #expect(throws: Secp256k1Error.invalidTweak) { try key.addingXOnly(tweak) }
            #expect(throws: Secp256k1Error.invalidTweak) { try key.publicKey.adding(tweak) }
            #expect(throws: Secp256k1Error.invalidTweak) { try key.xOnlyKey.adding(tweak) }
            // Wrong lengths throw rather than trap, as the control-block path requires.
            #expect(throws: Secp256k1Error.invalidPublicKey) {
                try Secp256k1.XOnlyKey(Data(repeating: 0x7F, count: length))
            }
        }
    }

    @Test("uncompressed points round-trip and off-curve or malformed ones are refused")
    func uncompressedPoints() throws {
        let generator = try Secp256k1.PublicKey(uncompressed: Secp256k1.generatorUncompressed)
        #expect(generator.uncompressed == Secp256k1.generatorUncompressed)
        let compressedGenerator = try Self.bytes("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
        #expect(generator.compressed == compressedGenerator)
        var rng = SeededRandom(state: 0x0465)
        for _ in 0 ..< 32 {
            var secret = Data(capacity: 32)
            for _ in 0 ..< 4 {
                var word = rng.next().bigEndian
                withUnsafeBytes(of: &word) { secret.append(contentsOf: $0) }
            }
            let key = try Secp256k1.PrivateKey(secret).publicKey
            let parsed = try Secp256k1.PublicKey(uncompressed: key.uncompressed)
            #expect(parsed == key)
            #expect(parsed.compressed == key.compressed)
        }
        var offCurve = Secp256k1.generatorUncompressed
        offCurve[offCurve.startIndex + 64] ^= 0x01
        var wrongPrefix = Secp256k1.generatorUncompressed
        wrongPrefix[wrongPrefix.startIndex] = 0x02
        for junk in [offCurve, wrongPrefix, Secp256k1.generatorUncompressed.prefix(64),
                     Data([0x04]) + Data(repeating: 0xFF, count: 64)] {
            #expect(throws: Secp256k1Error.invalidPublicKey) { try Secp256k1.PublicKey(uncompressed: junk) }
        }
    }

    @Test("the BIP341 secret tweak matches the x-only public tweak")
    func secretAndPublicTweaksAgree() throws {
        var rng = SeededRandom(state: 0xB1B3)
        for _ in 0 ..< 64 {
            var secret = Data(capacity: 32)
            for _ in 0 ..< 4 {
                var word = rng.next().bigEndian
                withUnsafeBytes(of: &word) { secret.append(contentsOf: $0) }
            }
            let key = try Secp256k1.PrivateKey(secret)
            let tweak = TaggedSHA256.hash(tag: "TapTweak", message: key.xOnlyKey.x)
            let tweakedSecret = try key.addingXOnly(tweak)
            let tweakedPublic = try key.xOnlyKey.adding(tweak)
            #expect(tweakedSecret.xOnlyKey.x == tweakedPublic.x)
            #expect(tweakedSecret.xOnlyKey.parity == tweakedPublic.parity)
        }
    }
}
