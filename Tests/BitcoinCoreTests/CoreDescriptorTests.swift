import CryptoKit
import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// Bitcoin Core's descriptor rows (`src/test/descriptor_tests.cpp` at v31.0,
/// the `tr()` and `wsh()` ones, extracted into
/// `Vectors/core-taproot-descriptors-v31.0.json` and
/// `Vectors/core-wsh-descriptors-v31.0.json`): every row's private, public and
/// normalized text derives the scriptPubKeys Core lists, and every descriptor
/// Core refuses is refused here, at the parse or at the first derivation.
@Suite("Core descriptor vectors")
struct CoreDescriptorTests {
    static let files = ["core-taproot-descriptors-v31.0.json", "core-wsh-descriptors-v31.0.json"]

    @Test("vector files parsed", arguments: files)
    func parsed(file: String) throws {
        let vectors = try Vectors.coreDescriptors(file, in: .module)
        #expect(vectors.vectors.count == 15)
        #expect(vectors.unparsable.count >= 15)
    }

    /// A row with `DERIVE_HARDENED` has a hardened wildcard, so only its
    /// private form can be expanded; the public and normalized forms still
    /// parse and round-trip, as in Core's own test.
    @Test("private, public and normalized forms derive Core's scriptPubKeys", arguments: files)
    func derive(file: String) throws {
        for row in try Vectors.coreDescriptors(file, in: .module).vectors {
            let hardened = row.flags.contains("DERIVE_HARDENED")
            for text in [row.publicText, row.privateText, row.normalized] {
                let descriptor = try Descriptor(text)
                #expect(try Descriptor(descriptor.serialized()) == descriptor, Comment(rawValue: text))
                if hardened, text != row.privateText { continue }
                for (index, expected) in row.scriptPubKeys.enumerated() {
                    let outputs = try descriptor.derived(index: UInt32(index))
                    #expect(outputs.count == 1, Comment(rawValue: text))
                    #expect(outputs[0].scriptPubKey.hex == expected, "\(text) @ \(index)")
                }
            }
        }
    }

    @Test("a wsh() address is bech32 version 0 over the witness script's hash")
    func wshAddresses() throws {
        for row in try Vectors.coreDescriptors("core-wsh-descriptors-v31.0.json", in: .module).vectors
            where !row.flags.contains("DERIVE_HARDENED") {
            let descriptor = try Descriptor(row.publicText)
            let output = try descriptor.derived(index: 0)[0]
            let decoded = try SegwitAddress.decode(output.address, expectedHRP: "bc")
            #expect(decoded.version == 0)
            let script = try descriptor.resolvedWitnessScript(index: 0)
            #expect(Data(decoded.program) == Data(SHA256.hash(data: script.bytes)))
        }
    }

    @Test("Core's unparsable descriptors are refused", arguments: files)
    func unparsable(file: String) throws {
        for row in try Vectors.coreDescriptors(file, in: .module).unparsable {
            #expect((try? Descriptor(row.publicText).derived(index: 0)) == nil, "\(row.publicText): \(row.error)")
            #expect((try? Descriptor(row.privateText).derived(index: 0)) == nil, "\(row.privateText): \(row.error)")
        }
    }
}
