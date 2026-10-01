import Foundation
import Testing
@testable import WalletCore

/// The multi_a threshold cases HostileInputBoundsTests does not already pin.
struct MultisigParserTests {
    @Test("A threshold of 128 needs a sign-padding byte and still round-trips")
    func signPaddedThresholdRoundTrips() throws {
        let keys = Array(repeating: Data(repeating: 1, count: 32), count: 128)
        let script = try Multisig.script(threshold: 128, xonlyKeys: keys, sorted: false)
        let parsed = try #require(Multisig.parse(script))
        #expect(parsed.threshold == 128); #expect(parsed.keys == keys)
    }

    @Test("Truncated, zero, trailing-byte and oversized thresholds are refused")
    func malformedThresholds() throws {
        let script = try Multisig.script(threshold: 17,
            xonlyKeys: Array(repeating: Data(repeating: 1, count: 32), count: 17), sorted: false)
        let prefix = Data(script.bytes.dropLast(3))
        let oversized = Data([9]) + Data(repeating: 1, count: 9) + Data([0x9c])
        let trailers: [Data] = [Data([3, 17, 0x9c]), Data([0, 0x9c]), Data([0x51, 0, 0x9c]), oversized]
        for trailer in trailers {
            #expect(Multisig.parse(Script(prefix + trailer)) == nil)
        }
    }
}
