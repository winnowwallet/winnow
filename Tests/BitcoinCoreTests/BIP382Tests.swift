import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// BIP382 vectors parsed from bip-0382.mediawiki. Winnow holds `wsh()` and
/// nothing else of the BIP: the `wpkh()` and `sh()` rows are refused as
/// unknown top levels, and the `wsh()` rows derive the BIP's scriptPubKeys.
@Suite("BIP382 wsh()")
struct BIP382Tests {
    @Test("vector block parsed")
    func parsed() throws {
        let vectors = try Vectors.descriptorVectors("bip-0382.mediawiki", in: .module)
        #expect(vectors.valid.count == 12)
        #expect(vectors.valid.filter { $0.descriptor.hasPrefix("wsh(") }.count == 4)
        #expect(vectors.invalid.count == 11)
    }

    @Test("wsh() descriptors derive the expected scriptPubKeys; other top levels are refused")
    func validDescriptors() throws {
        for (text, scripts) in try Vectors.descriptorVectors("bip-0382.mediawiki", in: .module).valid {
            guard text.hasPrefix("wsh(") else {
                #expect((try? Descriptor(text)) == nil, "accepted: \(text)")
                continue
            }
            let descriptor = try Descriptor(text)
            for (index, expected) in scripts.enumerated() {
                let outputs = try descriptor.derived(index: UInt32(index))
                #expect(outputs.count == 1)
                #expect(outputs[0].scriptPubKey == Data(hex: expected), "\(text) @ \(index)")
                let decoded = try SegwitAddress.decode(outputs[0].address, expectedHRP: "bc")
                #expect(decoded.version == 0)
                #expect(Data(decoded.program) == outputs[0].scriptPubKey.suffix(32))
            }
            #expect(try Descriptor(descriptor.serialized()) == descriptor)
        }
    }

    @Test("invalid descriptors are rejected at parse or derive time")
    func invalidDescriptors() throws {
        for text in try Vectors.descriptorVectors("bip-0382.mediawiki", in: .module).invalid {
            #expect((try? Descriptor(text).derived(index: 0)) == nil, "accepted: \(text)")
        }
    }
}
