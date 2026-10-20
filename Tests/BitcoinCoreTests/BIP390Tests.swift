import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// BIP390 musig() descriptor vectors (from bip-0390.mediawiki) and BIP328
/// aggregate-key derivation vectors (from bip-0328.mediawiki). Key-path only:
/// the valid vectors with a script tree are refused.
@Suite("BIP390 musig()")
struct BIP390Tests {
    @Test("vector block parsed")
    func parsed() throws {
        let vectors = try Vectors.descriptorVectors("bip-0390.mediawiki", in: .module)
        #expect(vectors.valid.count == 6)
        #expect(vectors.valid.map(\.scripts.count) == [1, 1, 3, 3, 3, 1])
        #expect(vectors.invalid.count == 14)
    }

    /// This wallet holds Taproot key-path descriptors only, so the BIP's two
    /// valid vectors with a script tree (`tr(musig(...),pk(...))` and
    /// `tr(KEY,pk(musig(...)))`) are refused here rather than derived.
    static func hasScriptTree(_ text: String) -> Bool { text.contains(",pk(") }

    @Test("valid key-path musig descriptors produce the expected scriptPubKeys; script trees are refused")
    func validDescriptors() throws {
        let valid = try Vectors.descriptorVectors("bip-0390.mediawiki", in: .module).valid
        #expect(valid.filter { Self.hasScriptTree($0.descriptor) }.count == 2)
        for (text, scripts) in valid {
            if Self.hasScriptTree(text) {
                #expect((try? Descriptor(text)) == nil, "a script tree parsed: \(text)")
                continue
            }
            let descriptor = try Descriptor(text)
            #expect(try Descriptor(descriptor.serialized()) == descriptor, "round trip: \(text)")
            for (index, expected) in scripts.enumerated() {
                let outputs = try descriptor.derived(index: UInt32(index))
                #expect(outputs.count == 1)
                #expect(outputs[0].scriptPubKey == Data(hex: expected), "\(text) @ \(index)")
            }
        }
    }

    @Test("invalid musig descriptors are rejected at parse or derive time")
    func invalidDescriptors() throws {
        for text in try Vectors.descriptorVectors("bip-0390.mediawiki", in: .module).invalid {
            #expect((try? Descriptor(text).derived(index: 0)) == nil, "accepted: \(text)")
        }
    }

    /// BIP328: KeyAgg of the listed keys yields the aggregate pubkey, and the
    /// synthetic xpub (fixed chaincode) serializes as given.
    @Test("BIP328 aggregate pubkeys and synthetic xpubs")
    func bip328() throws {
        let text = try Vectors.string("bip-0328.mediawiki", in: .module)
        var vectors: [(aggregate: String, xpub: String, keys: [String])] = []
        for line in text.components(separatedBy: .newlines) {
            let tags = ttTags(in: line)
            guard !tags.isEmpty else { continue }
            if line.hasPrefix("* Aggregate pubkey") {
                vectors.append((tags[0], "", []))
            } else if line.hasPrefix("** Synthetic xpub") {
                vectors[vectors.count - 1].xpub = tags[0]
            } else if line.hasPrefix("*** <tt>") {
                vectors[vectors.count - 1].keys.append(tags[0])
            }
        }
        #expect(vectors.count == 3)
        #expect(vectors.map(\.keys.count) == [2, 3, 4])

        for (aggregate, xpub, keys) in vectors {
            let publicKeys = try keys.map { try #require(Data(hex: $0)) }
            let aggregated = try MuSig.aggregate(publicKeys) // listed order, no KeySort
            #expect(aggregated == Data(hex: aggregate))
            // KeySort must be a no-op on already sorted input and match BIP327 ordering.
            #expect(MuSig.keySort(publicKeys).count == publicKeys.count)
            let synthetic = try MuSig.syntheticExtendedKey(aggregatePublicKey: aggregated)
            #expect(synthetic.serialized() == xpub)
        }
    }
}
