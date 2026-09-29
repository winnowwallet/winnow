import Foundation
import Testing
@testable import WalletCore

struct MultisigParserTests {
    @Test("Canonical thresholds above OP_16, including sign padding, round-trip", arguments: [17, 128])
    func canonicalPushedThreshold(_ threshold: Int) throws {
        let keys = Array(repeating: Data(repeating: 1, count: 32), count: threshold)
        let script = try Multisig.script(threshold: threshold, xonlyKeys: keys, sorted: false)
        let parsed = try #require(Multisig.parse(script))
        #expect(parsed.threshold == threshold); #expect(parsed.keys == keys)
    }
    @Test("Negative, nonminimal, truncated, and oversized arithmetic thresholds are refused")
    func malformedThresholds() throws {
        let script = try Multisig.script(threshold: 17,
            xonlyKeys: Array(repeating: Data(repeating: 1, count: 32), count: 17), sorted: false)
        let prefix = Data(script.bytes.dropLast(3))
        let oversized = Data([9]) + Data(repeating: 1, count: 9) + Data([0x9c])
        let trailers: [Data] = [Data([1, 0x91, 0x9c]), Data([2, 17, 0, 0x9c]),
                        Data([3, 17, 0x9c]), Data([0, 0x9c]), Data([0x51, 0, 0x9c]),
                        Data([5, 17, 0, 0, 0, 0, 0x9c]), oversized]
        for trailer in trailers {
            #expect(Multisig.parse(Script(prefix + trailer)) == nil)
        }
    }
}
