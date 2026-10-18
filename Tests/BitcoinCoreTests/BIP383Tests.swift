import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// BIP383 `multi`/`sortedmulti` vectors parsed from bip-0383.mediawiki. Only
/// the `wsh()` rows are Winnow's; bare and `sh()`-wrapped multisig is refused
/// as an unknown top level.
@Suite("BIP383 multi/sortedmulti")
struct BIP383Tests {
    @Test("vector block parsed")
    func parsed() throws {
        let vectors = try Vectors.descriptorVectors("bip-0383.mediawiki", in: .module)
        #expect(vectors.valid.count == 9)
        #expect(vectors.valid.filter { $0.descriptor.hasPrefix("wsh(") }.map(\.scripts.count) == [3, 1])
        #expect(vectors.invalid.count == 4)
    }

    @Test("wsh(multi) descriptors derive the expected scriptPubKeys; other top levels are refused")
    func validDescriptors() throws {
        for (text, scripts) in try Vectors.descriptorVectors("bip-0383.mediawiki", in: .module).valid {
            guard text.hasPrefix("wsh(") else {
                #expect((try? Descriptor(text)) == nil, "accepted: \(text)")
                continue
            }
            let descriptor = try Descriptor(text)
            for (index, expected) in scripts.enumerated() {
                let outputs = try descriptor.derived(index: UInt32(index))
                #expect(outputs.count == 1)
                #expect(outputs[0].scriptPubKey == Data(hex: expected), "\(text) @ \(index)")
            }
            #expect(try Descriptor(descriptor.serialized()) == descriptor)
        }
    }

    @Test("invalid descriptors are rejected at parse or derive time")
    func invalidDescriptors() throws {
        for text in try Vectors.descriptorVectors("bip-0383.mediawiki", in: .module).invalid {
            #expect((try? Descriptor(text).derived(index: 0)) == nil, "accepted: \(text)")
        }
    }

    @Test("the OP_CHECKMULTISIG template matches the BIP383 text")
    func scriptTemplate() throws {
        let keys = [Data([0x02] + Data(repeating: 0x11, count: 32)), Data([0x03] + Data(repeating: 0x22, count: 32))]
        let script = try Multisig.legacyScript(threshold: 1, compressedKeys: keys, sorted: false)
        var expected = Data([0x51])
        for key in keys {
            expected.append(0x21)
            expected.append(key)
        }
        expected.append(contentsOf: [0x52, 0xAE])
        #expect(script.bytes == expected)
        // sortedmulti orders the compressed keys first.
        let sorted = try Multisig.legacyScript(threshold: 1, compressedKeys: keys.reversed(), sorted: true)
        #expect(sorted.bytes == expected)
        // Twenty-one keys is one past the consensus limit.
        let many = (0 ..< 21).map { Data([0x02, UInt8($0 + 1)] + Data(repeating: 0, count: 31)) }
        #expect(throws: MultisigError.tooManyKeys) {
            _ = try Multisig.legacyScript(threshold: 1, compressedKeys: many, sorted: false)
        }
    }
}
