import Foundation
import NativeSecp256k1
import P256K
import Testing
import TestSupport
@testable import WalletCore

/// The native key types against the pinned libsecp256k1 wrapper (`P256K`):
/// every accept/reject decision, encoding, parity bit and tweak result must
/// agree, including the boundary inputs that distinguish the rules.
@Suite("Native secp256k1 keys versus libsecp256k1")
struct NativeSecp256k1KeyTests {
    struct KeyVector: Decodable {
        let name: String
        let x: String
        let evenY: String?
    }

    static let orderHex = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"
    static let orderMinusOne = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140"
    static let zero32 = Data(repeating: 0, count: 32)
    static let one32 = Data(repeating: 0, count: 31) + Data([1])

    static func bytes(_ hex: String) throws -> Data {
        try #require(Data(hex: hex), "hex \(hex)")
    }

    static func random32(_ rng: inout SeededRandom) -> Data {
        var data = Data(capacity: 32)
        for _ in 0 ..< 4 {
            var word = rng.next().bigEndian
            withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// n − k as 32 bytes, for a 32-byte k below n.
    static func orderMinus(_ k: Data) throws -> Data {
        let order = try bytes(orderHex)
        var borrow = 0
        var result = [UInt8](repeating: 0, count: 32)
        for index in stride(from: 31, through: 0, by: -1) {
            let difference = Int(order[order.startIndex + index]) - Int(k[k.startIndex + index]) - borrow
            result[index] = UInt8(difference & 0xFF)
            borrow = difference < 0 ? 1 : 0
        }
        return Data(result)
    }

    static var boundaryKeys: [Data] {
        get throws {
            try [zero32, one32, bytes(orderMinusOne), bytes(orderHex),
                 bytes("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364142"),
                 Data(repeating: 0xFF, count: 32), Data(), Data(repeating: 1, count: 31),
                 Data(repeating: 1, count: 33)]
        }
    }

    // MARK: - Parsing and public keys

    @Test("private keys are accepted and rejected exactly like libsecp256k1")
    func privateKeyParsing() throws {
        var rng = SeededRandom(state: 0xA11CE)
        var inputs = try Self.boundaryKeys
        for _ in 0 ..< 128 { inputs.append(Self.random32(&rng)) }
        for input in inputs {
            let native = try? Secp256k1.PrivateKey(input)
            let reference = try? P256K.Signing.PrivateKey(dataRepresentation: input)
            #expect((native == nil) == (reference == nil), "accept/reject \(input.hex)")
            guard let native, let reference else { continue }
            #expect(native.bytes == input)
            #expect(native.publicKey.compressed == reference.publicKey.dataRepresentation, "\(input.hex)")
            let schnorr = try P256K.Schnorr.PrivateKey(dataRepresentation: input)
            #expect(native.xOnlyKey.x == Data(schnorr.xonly.bytes), "\(input.hex)")
            #expect(native.xOnlyKey.parity == schnorr.xonly.parity, "parity \(input.hex)")
            #expect(native.publicKey.xOnlyKey == native.xOnlyKey)
        }
    }

    @Test("compressed public keys parse identically, including junk prefixes")
    func publicKeyParsing() throws {
        var rng = SeededRandom(state: 0xB0B)
        var inputs: [Data] = []
        for _ in 0 ..< 96 {
            let x = Self.random32(&rng)
            for prefix: UInt8 in [0x00, 0x02, 0x03, 0x04, 0xFF] { inputs.append(Data([prefix]) + x) }
        }
        for key in try Self.boundaryKeys where key.count == 32 {
            inputs.append(Data([0x02]) + key)
            inputs.append(Data([0x03]) + key)
        }
        inputs.append(Data())
        inputs.append(Data([0x02]))
        inputs.append(Data([0x02]) + Data(repeating: 0, count: 33))
        var accepted = 0
        for input in inputs {
            let native = try? Secp256k1.PublicKey(compressed: input)
            let reference = try? P256K.Signing.PublicKey(dataRepresentation: input, format: .compressed)
            #expect((native == nil) == (reference == nil), "accept/reject \(input.hex)")
            guard let native, let reference else { continue }
            accepted += 1
            #expect(native.compressed == reference.dataRepresentation, "\(input.hex)")
            #expect(native.compressed == input)
        }
        #expect(accepted > 50)
    }

    // MARK: - Tweaks

    @Test("private tweak-add matches ec_seckey_tweak_add, including zero and overflow tweaks")
    func privateTweaks() throws {
        var rng = SeededRandom(state: 0x7EA4)
        for iteration in 0 ..< 96 {
            let secret = Self.random32(&rng)
            // Wrong-length tweaks are compared separately: the P256K wrapper reads
            // 32 bytes whatever the array length, so it cannot refuse them.
            let tweaks: [Data] = try [Self.random32(&rng), Self.zero32, Self.one32,
                                       Self.bytes(Self.orderMinusOne), Self.bytes(Self.orderHex),
                                       Self.orderMinus(secret)]
            let native = try Secp256k1.PrivateKey(secret)
            let reference = try P256K.Signing.PrivateKey(dataRepresentation: secret)
            let schnorrReference = try P256K.Schnorr.PrivateKey(dataRepresentation: secret)
            for tweak in tweaks {
                let plain = try? native.adding(tweak).bytes
                let plainReference = try? reference.add([UInt8](tweak)).dataRepresentation
                #expect(plain == plainReference, "plain tweak \(iteration) \(tweak.hex)")
                let xOnly = try? native.addingXOnly(tweak).bytes
                let xOnlyReference = try? schnorrReference.add([UInt8](tweak)).dataRepresentation
                #expect(xOnly == xOnlyReference, "x-only tweak \(iteration) \(tweak.hex)")
            }
            // n − d makes the plain sum zero: both refuse.
            #expect(throws: Secp256k1Error.invalidResult) { try native.adding(try Self.orderMinus(secret)) }
            #expect(throws: Secp256k1Error.invalidTweak) { try native.adding(try Self.bytes(Self.orderHex)) }
            #expect(throws: Secp256k1Error.invalidTweak) { try native.adding(Data(repeating: 0, count: 31)) }
        }
    }

    @Test("public tweak-add matches ec_pubkey_tweak_add, including the infinity case")
    func publicTweaks() throws {
        var rng = SeededRandom(state: 0x9B1C)
        for iteration in 0 ..< 96 {
            let secret = Self.random32(&rng)
            let native = try Secp256k1.PrivateKey(secret).publicKey
            let reference = try P256K.Signing.PublicKey(dataRepresentation: native.compressed, format: .compressed)
            let tweaks: [Data] = try [Self.random32(&rng), Self.zero32, Self.one32,
                                       Self.bytes(Self.orderMinusOne), Self.bytes(Self.orderHex),
                                       Self.orderMinus(secret)]
            #expect(throws: Secp256k1Error.invalidTweak) { try native.adding(Data(repeating: 0, count: 33)) }
            for tweak in tweaks {
                let sum = try? native.adding(tweak).compressed
                let sumReference = try? reference.add([UInt8](tweak), format: .compressed).dataRepresentation
                #expect(sum == sumReference, "public tweak \(iteration) \(tweak.hex)")
            }
            // K + (n − d)·G is infinity: both refuse.
            #expect(throws: Secp256k1Error.invalidResult) { try native.adding(try Self.orderMinus(secret)) }
            // Tweaking the public key agrees with tweaking the private key.
            let tweak = Self.random32(&rng)
            let viaSecret = try Secp256k1.PrivateKey(secret).adding(tweak).publicKey.compressed
            #expect(try native.adding(tweak).compressed == viaSecret)
        }
    }

    @Test("x-only tweak-add matches xonly_pubkey_tweak_add in bytes and parity")
    func xOnlyTweaks() throws {
        var rng = SeededRandom(state: 0x30A1)
        let vectors: [KeyVector] = try Vectors.decode([KeyVector].self, "xonly-validation.json", in: .module,
                                                      subdirectory: "Vectors/native-secp256k1")
        var xs: [Data] = try vectors.map { try Self.bytes($0.x) }
        for _ in 0 ..< 64 { xs.append(try Secp256k1.PrivateKey(Self.random32(&rng)).xOnlyKey.x) }
        xs.append(try Self.bytes("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f")) // p
        xs.append(try Self.bytes("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc30")) // p + 1
        xs.append(Data(repeating: 0xFF, count: 32))
        let tweaks: [Data] = try [Self.random32(&rng), Self.zero32, Self.one32,
                                   Self.bytes(Self.orderMinusOne), Self.bytes(Self.orderHex)]
        var agreedValid = 0
        for x in xs {
            let parses = (try? Secp256k1.XOnlyKey(x)) != nil
            for tweak in tweaks {
                let native = try? Secp256k1.XOnlyKey(x).adding(tweak)
                let reference = try? P256K.Schnorr.XonlyKey(dataRepresentation: x).add([UInt8](tweak))
                #expect((native == nil) == (reference == nil), "accept/reject \(x.hex) \(tweak.hex)")
                guard let native, let reference else { continue }
                agreedValid += 1
                #expect(native.x == Data(reference.bytes), "\(x.hex) + \(tweak.hex)")
                #expect(native.parity == reference.parity, "parity \(x.hex) + \(tweak.hex)")
                #expect(parses)
            }
        }
        // 167 valid fixture keys plus 64 random ones, each with the four tweaks below n.
        #expect(agreedValid == (167 + 64) * 4)
        // Wrong lengths throw rather than trap, as the control-block path requires.
        for length in [0, 31, 33, 64] {
            #expect(throws: Secp256k1Error.invalidPublicKey) {
                try Secp256k1.XOnlyKey(Data(repeating: 0x7F, count: length))
            }
        }
    }

    @Test("x-only tweak-add refuses an infinity result like libsecp256k1")
    func xOnlyTweakInfinity() throws {
        var rng = SeededRandom(state: 0x1F1F)
        for _ in 0 ..< 16 {
            let secret = Self.random32(&rng)
            let key = try Secp256k1.PrivateKey(secret)
            // lift_x(x) is the even-y point: k·G itself, or (n − k)·G when k·G has odd y.
            let evenSecret = try key.xOnlyKey.parity ? Self.orderMinus(secret) : secret
            let tweak = try Self.orderMinus(evenSecret)
            #expect(throws: Secp256k1Error.invalidResult) { try key.xOnlyKey.adding(tweak) }
            #expect(throws: (any Error).self) {
                try P256K.Schnorr.XonlyKey(dataRepresentation: key.xOnlyKey.x).add([UInt8](tweak))
            }
        }
    }

    @Test("the BIP341 secret tweak matches the x-only public tweak")
    func secretAndPublicTweaksAgree() throws {
        var rng = SeededRandom(state: 0xB1B3)
        for _ in 0 ..< 64 {
            let key = try Secp256k1.PrivateKey(Self.random32(&rng))
            let tweak = TaggedSHA256.hash(tag: "TapTweak", message: key.xOnlyKey.x)
            let tweakedSecret = try key.addingXOnly(tweak)
            let tweakedPublic = try key.xOnlyKey.adding(tweak)
            #expect(tweakedSecret.xOnlyKey.x == tweakedPublic.x)
            #expect(tweakedSecret.xOnlyKey.parity == tweakedPublic.parity)
        }
    }
}
