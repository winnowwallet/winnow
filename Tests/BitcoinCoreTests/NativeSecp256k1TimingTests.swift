import Foundation
@testable import NativeSecp256k1
import Testing
import TestSupport
@testable import WalletCore

/// Opt-in timing of the native module. Not a correctness test and never run
/// by default: it prints microseconds per operation and asserts nothing. Run
/// a release build with
/// `WINNOW_TIMING=1 swift test -c release --filter NativeSecp256k1TimingTests`.
/// The libsecp256k1 column in the module README was measured once, on
/// 2026-10-19, through the since-removed swift-secp256k1 wrapper.
@Suite("Native secp256k1 timing", .enabled(if: ProcessInfo.processInfo.environment["WINNOW_TIMING"] != nil))
struct NativeSecp256k1TimingTests {
    static func random32(_ rng: inout SeededRandom) -> Data {
        Data((0 ..< 32).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
    }

    static func measure(_ label: String, iterations: Int = 200, _ body: () throws -> Void) rethrows {
        let start = ContinuousClock.now
        for _ in 0 ..< iterations { try body() }
        let elapsed = ContinuousClock.now - start
        let micros = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
        print(String(format: "timing %-34@ %8.1f µs/op", label, micros / Double(iterations)))
    }

    @Test("native module, microseconds per operation")
    func timings() throws {
        var rng = SeededRandom(state: 0x71E)
        let secrets = (0 ..< 200).map { _ in Self.random32(&rng) }
        let tweaks = (0 ..< 200).map { _ in Self.random32(&rng) }
        let messages = (0 ..< 200).map { _ in Self.random32(&rng) }
        let keys = try secrets.map { try Secp256k1.PrivateKey($0) }
        let publics = keys.map(\.publicKey)
        let aux = Data(repeating: 0, count: 32)
        var index = 0
        func next() -> Int { index = (index + 1) % 200; return index }

        try Self.measure("native k·G") { _ = try Secp256k1.PrivateKey(secrets[next()]).publicKey.compressed }
        try Self.measure("native public tweak (BIP32 child)") {
            let i = next()
            _ = try Secp256k1.PublicKey(compressed: publics[i].compressed).adding(tweaks[i]).compressed
        }
        try Self.measure("native x-only tweak (taptweak)") {
            let i = next()
            _ = try Secp256k1.XOnlyKey(publics[i].xOnlyKey.x).adding(tweaks[i])
        }
        try Self.measure("native sign (with self-verify)") {
            let i = next()
            _ = try Secp256k1.Schnorr.sign(message: messages[i], privateKey: keys[i], auxiliaryRand: aux)
        }
        let signatures = try (0 ..< 200).map {
            try Secp256k1.Schnorr.sign(message: messages[$0], privateKey: keys[$0], auxiliaryRand: aux)
        }
        Self.measure("native verify") {
            let i = next()
            _ = Secp256k1.Schnorr.verify(signature: signatures[i], message: messages[i], publicKey: publics[i].xOnlyKey.x)
        }
        Self.measure("native field inverse", iterations: 2000) {
            _ = FieldElement(reducing: Integer256(l0: rng.next(), l1: rng.next(), l2: rng.next(), l3: 0)).inverse()
        }
        Self.measure("native field multiply", iterations: 200_000) {
            _ = Curve.generator.x * Curve.generator.y
        }
    }
}
