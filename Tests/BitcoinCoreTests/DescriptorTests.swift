import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// Descriptor engine round-trips (parse/serialize with recomputed checksum),
/// BIP389 multipath expansion, and a BIP388 policy-expanded descriptor sanity check.
@Suite("Descriptor engine")
struct DescriptorTests {
    /// Representative set: plain, tree, nested tree, wildcards, hardened steps,
    /// origins, musig, multipath.
    static let representatives = [
        "tr(a34b99f22c790c4e36b2b3c2c35a36db06226e41c692fc82b8b56ac1c540c5bd)",
        "tr(0260b2003c386519fc9eadf2b5cf124dd8eea4c4e68d5e154050a9346ea98ce600,pk(669b8afcec803a0d323e9a17f3ea8e68e8abe5a278020a929adbec52421adbd0))",
        "tr(50929b74c1a04954b78b4b6035e97a5e078a5a0f28ec96d547bfee9ace803ac0,{pk(669b8afcec803a0d323e9a17f3ea8e68e8abe5a278020a929adbec52421adbd0),{multi_a(2,0260b2003c386519fc9eadf2b5cf124dd8eea4c4e68d5e154050a9346ea98ce600,03a34b99f22c790c4e36b2b3c2c35a36db06226e41c692fc82b8b56ac1c540c5bd),sortedmulti_a(1,0260b2003c386519fc9eadf2b5cf124dd8eea4c4e68d5e154050a9346ea98ce600,03a34b99f22c790c4e36b2b3c2c35a36db06226e41c692fc82b8b56ac1c540c5bd)}})",
        "tr([deadbeef/86'/0'/0']xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/0/*)",
        "tr(xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/<0;1>/*,{pk(xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y/0/*),multi_a(2,xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/*,xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y/0/0/*)})",
        "rawtr(musig(02f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9,03dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659,023590a94e768f8e1815c2f24b4d80a8e3149316c3518ce7b7ad338368d038ca66))",
        "tr(musig(xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL,xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y)/0/*)",
        "tr(L4rK1yDtCWekvXuE6oXD9jCYfFNV2cWRpVuPLBcCU2z8TrisoyY1,multi_a(1,KzoAz5CanayRKex3fSLQ2BwJpN7U52gZvxMyk78nDMHuqrUxuSJy))",
        // Miniscript leaves: a threshold with a timelocked branch, and an owner key path with a timelocked heir leaf.
        "tr(50929b74c1a04954b78b4b6035e97a5e078a5a0f28ec96d547bfee9ace803ac0,thresh(2,pk(30a6069f344fb784a2b4c99540a91ee727c91e3a25ef6aae867d9c65b5f23529),s:pk(9918d400c1b8c3c478340a40117ced4054b6b58f48cdb3c89b836bdfee1f5766),adv:older(42)))",
        "tr(xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/<0;1>/*,{pk(xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y/<0;1>/*),and_v(v:pk(xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/<2;3>/*),older(52560))})",
        // P2WSH: sorted multisig, and BIP388's trust-minimised second factor.
        "wsh(sortedmulti(2,xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/<0;1>/*,xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y/<0;1>/*))",
        "wsh(and_v(v:pk(xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/<0;1>/*),or_d(pk(xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y/<0;1>/*),older(12960))))",
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

        // Mismatched multipath widths are invalid (BIP389).
        let mismatched = "tr(xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/<0;1>/*,{pk(xpub68NZiKmJWnxxS6aaHmn81bvJeTESw724CRDs6HbuccFQN9Ku14VQrADWgqbhhTHBaohPX4CjNLf9fq9MYo6oDaPPLPxSb7gwQN3ih19Zm4Y/<0;1;2>/*)})"
        #expect((try? Descriptor(mismatched)) == nil)

        // One multipath element per key expression (BIP389). A second one
        // used to parse and then trap on derivation, because the choice count
        // comes from the first element and indexed the narrower second.
        let doubled = "tr(xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/<0;1;2>/<0;1>/*)"
        #expect(throws: DescriptorError.invalidPath) { _ = try Descriptor(doubled) }
    }

    /// The expanded `Descriptor:` lines of the BIP's two Taproot examples: a
    /// `sortedmulti_a` leaf beside an `or_b` miniscript leaf, and a MuSig2 key
    /// path with three timelocked MuSig2 leaves.
    static func bip388TaprootDescriptors() throws -> [String] {
        let text = try Vectors.string("bip-0388.mediawiki", in: .module)
        return text.components(separatedBy: .newlines)
            .filter { $0.hasPrefix(" Descriptor: tr(") }
            .map { String($0.dropFirst(13)) }
    }

    @Test("BIP388's Taproot examples parse, derive, and round-trip with their miniscript leaves")
    func bip388PolicyDescriptors() throws {
        let texts = try Self.bip388TaprootDescriptors()
        #expect(texts.count == 3)
        #expect(texts.contains { $0.contains("or_b(pk(") })
        #expect(texts.contains { $0.contains("and_v(v:pk(musig(") })
        for text in texts {
            let descriptor = try Descriptor(text)
            #expect(descriptor.isRanged)
            let outputs = try descriptor.derived(index: 5)
            #expect(outputs.count == 2, Comment(rawValue: text))
            #expect(outputs[0].address.hasPrefix("bc1p"))
            #expect(try Descriptor(descriptor.serialized()) == descriptor)
            #expect(descriptor.serialized().hasPrefix(text), "canonical text differs from the BIP's")
        }
    }

    // MARK: - Liana

    /// Liana's inheritance template, as its own tests print it, checksum
    /// included: the owner in the key path, the heir in a leaf after 52,560
    /// blocks (`liana/src/descriptors/mod.rs` at wizardsardine/liana master,
    /// 2026-10-18).
    static let lianaTaprootInheritance = "tr([abcdef01]xpub6Eze7yAT3Y1wGrnzedCNVYDXUqa9NmHVWck5emBaTbXtURbe1NWZbK9bsz1TiVE7Cz341PMTfYgFw1KdLWdzcM1UMFTcdQfCYhhXZ2HJvTW/<0;1>/*,and_v(v:pk([abcdef01]xpub688Hn4wScQAAiYJLPg9yH27hUpfZAUnmJejRQBCiwfP5PEDzjWMNW1wChcninxr5gyavFqbbDjdV1aK5USJz8NDVjUy7FRQaaqqXHh5SbXe/<0;1>/*),older(52560)))#0mt7e93c"

    /// A Liana Taproot wallet with its deterministically derived unspendable
    /// internal key (the BIP341 NUMS point inside an xpub whose chain code
    /// hashes the leaf keys), a 2-of-2 primary leaf and a 1-of-2 recovery
    /// leaf after 65,535 blocks; the checksum is Liana's.
    static let lianaTaprootUnspendable = "tr(tpubD6NzVbkrYhZ4WUdbVsXDYBCXS8EPSYG1cAN9g4uP6uLQHMHXRvHSFkQBXy7MBeAvV8PDVJJ4o3AwYMKJHp45ci2g69UCAKteVSAJ61CnGEV/<0;1>/*,{and_v(v:pk([9e1c1983/48'/1'/0'/2']tpubDEWCLCMncbStq4BLXkQUAPqzzrh2tQUgYeQPt4NrB5D7gRraMyGbRqzPTmQGvqfdaFsXDVGSQBRgfXuNjDyfU626pxSjpQZszFNY6CzogxK/<2;3>/*),older(65535)),multi_a(2,[9e1c1983/48'/1'/0'/2']tpubDEWCLCMncbStq4BLXkQUAPqzzrh2tQUgYeQPt4NrB5D7gRraMyGbRqzPTmQGvqfdaFsXDVGSQBRgfXuNjDyfU626pxSjpQZszFNY6CzogxK/<0;1>/*,[3b1913e1/48'/1'/0'/2']tpubDFeZ2ezf4VUuTnjdhxJ1DKhLa2t6vzXZNz8NnEgeT2PN4pPqTCTeWUcaxKHPJcf1C8WzkLA71zSjDwuo4zqu4kkiL91ZUmJydC8f1gx89wM/<0;1>/*)})#ee0r4tw5"

    /// Liana's P2WSH inheritance descriptor and the one address its tests
    /// assert, receive index 11 on mainnet.
    static let lianaWSHInheritance = "wsh(andor(pk([abcdef01]tpubDEN9WSToTyy9ZQfaYqSKfmVqmq1VVLNtYfj3Vkqh67et57eJ5sTKZQBkHqSwPUsoSskJeaYnPttHe2VrkCsKA27kUaN9SDc5zhqeLzKa1rr/<0;1>/*),older(10000),pk([abcdef01]tpubD8LYfn6njiA2inCoxwM7EuN3cuLVcaHAwLYeups13dpevd3nHLRdK9NdQksWXrhLQVxcUZRpnp5CkJ1FhE61WRAsHxDNAkvGkoQkAeWDYjV/<0;1>/*)))#2qj59a9y"

    @Test("Liana's Taproot templates parse, keep Liana's checksum, and derive receive and change")
    func lianaTaproot() throws {
        for text in [Self.lianaTaprootInheritance, Self.lianaTaprootUnspendable] {
            let descriptor = try Descriptor(text)
            #expect(descriptor.serialized() == text)
            let outputs = try descriptor.derived(index: 0, network: .testnet)
            #expect(outputs.count == 2)
            #expect(outputs[0].address.hasPrefix("tb1p"))
            #expect(outputs[0] != outputs[1])
        }
    }

    @Test("Liana's P2WSH inheritance descriptor derives the address Liana asserts")
    func lianaWSH() throws {
        let descriptor = try Descriptor(Self.lianaWSHInheritance)
        #expect(descriptor.serialized() == Self.lianaWSHInheritance)
        let outputs = try descriptor.derived(index: 11)
        #expect(outputs.count == 2)
        #expect(outputs[0].address == "bc1q26gtczlz03u6juf5cxppapk4sr4fyz53s3g4zs2cgactcahqv6yqc2t8e6")
        guard case .wsh = descriptor.expression else { Issue.record("not wsh"); return }
    }
}
