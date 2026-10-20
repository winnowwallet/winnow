import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// Descriptor engine round-trips (parse/serialize with recomputed checksum),
/// BIP389 multipath expansion, and the forms the single-key engine refuses.
@Suite("Descriptor engine")
struct DescriptorTests {
    /// Representative set: x-only, compressed and WIF keys, raw output keys,
    /// hardened steps, origins, wildcards, multipath.
    static let representatives = [
        "tr(a34b99f22c790c4e36b2b3c2c35a36db06226e41c692fc82b8b56ac1c540c5bd)",
        "tr(0260b2003c386519fc9eadf2b5cf124dd8eea4c4e68d5e154050a9346ea98ce600)",
        "rawtr(a34b99f22c790c4e36b2b3c2c35a36db06226e41c692fc82b8b56ac1c540c5bd)",
        "tr([deadbeef/86'/0'/0']xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/0/*)",
        "tr(xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/<0;1>/*)",
        "rawtr([deadbeef/86'/0'/0']xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/<0;1>/*)",
        "tr(L4rK1yDtCWekvXuE6oXD9jCYfFNV2cWRpVuPLBcCU2z8TrisoyY1)",
    ]

    @Test("parse(serialize(x)) == x, with a recomputed valid checksum")
    func roundTrip() throws {
        for text in Self.representatives {
            let descriptor = try Descriptor(text)
            let serialized = descriptor.serialized()
            let checksum = try #require(serialized.split(separator: "#").last)
            #expect(DescriptorChecksum.verify(body: String(serialized.dropLast(9)), checksum: String(checksum)))
            #expect(try Descriptor(serialized) == descriptor, Comment(rawValue: text))
        }
    }

    @Test("hardened markers normalize to ' on serialization")
    func hardenedNormalization() throws {
        let descriptor = try Descriptor("tr([deadbeef/0h/1h]xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/3h/4h/5h/*h)")
        #expect(descriptor.serialized().hasPrefix("tr([deadbeef/0'/1']"))
        #expect(descriptor.serialized().contains("/3'/4'/5'/*'"))
    }

    @Test("BIP389 multipath expands to one output per choice")
    func multipath() throws {
        let text = "tr([73c5da0a/86'/0'/0']xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3VCECoY49yfdDEHGCtMMj92pReUsQ/<0;1>/*)"
        let descriptor = try Descriptor(text)
        #expect(descriptor.isRanged)
        let outputs = try descriptor.derived(index: 0)
        #expect(outputs.count == 2)
        #expect(outputs[0].scriptPubKey != outputs[1].scriptPubKey)

        // Choice 0 (receive) equals the BIP86 first address for this account key.
        #expect(outputs[0].address == TestScripts.bip86FirstMainnetAddress)

        // One multipath element per key expression (BIP389). A second one
        // used to parse and then trap on derivation, because the choice count
        // comes from the first element and indexed the narrower second.
        let doubled = "tr(xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/<0;1;2>/<0;1>/*)"
        #expect(throws: DescriptorError.invalidPath) { _ = try Descriptor(doubled) }
    }

    /// Script trees and multisig leaves belong to the shared-account Winnow.
    /// Here they are not a descriptor at all: the parser stops at the first
    /// character the key-path grammar does not expect, so nothing downstream
    /// can treat such text as a key it holds. Key-path `musig()` is accepted;
    /// BIP390Tests covers it.
    @Test("script trees and multisig leaves are refused at the parse")
    func multiKeyFormsRefused() {
        let xpub = "xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL"
        let other = "xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y"
        for text in [
            "tr(0260b2003c386519fc9eadf2b5cf124dd8eea4c4e68d5e154050a9346ea98ce600,pk(669b8afcec803a0d323e9a17f3ea8e68e8abe5a278020a929adbec52421adbd0))",
            "tr(\(xpub)/<0;1>/*,{pk(\(other)/0/*),multi_a(2,\(xpub)/*,\(other)/0/0/*)})",
            "tr(\(xpub)/<0;1>/*,sortedmulti_a(1,\(other)/0/*))",
            "tr(musig(\(xpub),\(other))/0/*,pk(\(other)/1/*))",
            "tr(musig(musig(\(xpub),\(other)))/0/*)",
            "pk(\(xpub)/0/*)",
            "multi_a(1,\(xpub)/0/*)",
        ] {
            #expect(throws: (any Error).self, Comment(rawValue: text)) { _ = try Descriptor(text) }
        }
    }
}
