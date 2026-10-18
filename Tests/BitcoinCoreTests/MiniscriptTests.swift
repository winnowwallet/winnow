import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// Bitcoin Core's miniscript vectors (`src/test/miniscript_tests.cpp` at
/// v31.0, extracted into `Vectors/core-miniscript-v31.0.json`), run the way
/// Core's own `Test()` runs each row: once under P2WSH and once under
/// tapscript. Validity, the malleability, signature and timelock-mix flags,
/// the script bytes where the row states them, and the canonical round trip.
@Suite("Miniscript")
struct MiniscriptTests {
    static let contexts: [Miniscript.Context] = [.p2wsh, .tapscript]

    /// Core's test keys are 33-byte compressed hex; the compiler itself drops
    /// the prefix under tapscript, as Core's test converter does.
    static func keyBytes(_ key: Descriptor.KeyExpression) throws -> Data {
        guard case let .single(single) = key, case let .publicKey(data) = single.base else {
            throw DescriptorError.invalidKey
        }
        return data.count == 32 ? Data([0x02]) + data : data
    }

    static func rows() throws -> [CoreMiniscriptVector] {
        try Vectors.coreMiniscript(in: .module)
    }

    @Test("vector file parsed")
    func parsed() throws {
        let rows = try Self.rows()
        #expect(rows.count == 97)
        #expect(rows.filter { $0.tapscript != nil }.count == 30)
        #expect(rows.filter { $0.p2wshScript != nil }.count == 37)
    }

    @Test("every row is valid or refused exactly as Core says", arguments: contexts)
    func validity(context: Miniscript.Context) throws {
        for row in try Self.rows() {
            let node = try? Miniscript(row.miniscript, context: context)
            #expect((node != nil) == row.isValid(in: context), "\(row.miniscript) under \(context)")
        }
    }

    @Test("valid rows carry Core's malleability, signature and timelock-mix flags", arguments: contexts)
    func flags(context: Miniscript.Context) throws {
        for row in try Self.rows() where row.isValid(in: context) {
            let node = try Miniscript(row.miniscript, context: context)
            #expect(node.isNonMalleable == row.modes.contains("TESTMODE_NONMAL"), Comment(rawValue: row.miniscript))
            #expect(node.needsSignature == row.modes.contains("TESTMODE_NEEDSIG"), Comment(rawValue: row.miniscript))
            #expect(node.mixesTimelocks == row.modes.contains("TESTMODE_TIMELOCKMIX"), Comment(rawValue: row.miniscript))
        }
    }

    @Test("valid rows compile to Core's bytes, at the length computed without compiling", arguments: contexts)
    func scripts(context: Miniscript.Context) throws {
        for row in try Self.rows() where row.isValid(in: context) {
            let node = try Miniscript(row.miniscript, context: context)
            let script = try node.script(keyBytes: Self.keyBytes)
            #expect(node.scriptLength == script.bytes.count, Comment(rawValue: row.miniscript))
            if let expected = row.expectedScript(in: context) {
                #expect(script.hex == expected, "\(row.miniscript) under \(context)")
            }
        }
    }

    @Test("valid rows print canonically and parse back equal", arguments: contexts)
    func roundTrip(context: Miniscript.Context) throws {
        for row in try Self.rows() where row.isValid(in: context) {
            let node = try Miniscript(row.miniscript, context: context)
            let text = node.description
            let again = try Miniscript(text, context: context)
            #expect(again == node, Comment(rawValue: row.miniscript))
            #expect(again.description == text, Comment(rawValue: row.miniscript))
        }
    }

    // MARK: - Rules beyond the vectors

    static let key = "03a34b99f22c790c4e36b2b3c2c35a36db06226e41c692fc82b8b56ac1c540c5bd"
    static let otherKey = "0260b2003c386519fc9eadf2b5cf124dd8eea4c4e68d5e154050a9346ea98ce600"
    static let nums = Taproot.unspendableInternalKey.hex

    /// `or_b(0,a:0)` is valid, non-malleable and needs a signature by the type
    /// rules, and no witness satisfies it; Core refuses it as a descriptor
    /// for that reason alone.
    @Test("a sane but unsatisfiable miniscript is refused as unsatisfiable")
    func unsatisfiable() throws {
        let node = try Miniscript("or_b(0,a:0)", context: .p2wsh)
        #expect(node.isSane)
        #expect(!node.isSatisfiable)
        #expect(throws: DescriptorError.unsafeMiniscript(.unsatisfiable, "or_b(0,a:0)")) {
            _ = try Descriptor("wsh(or_b(0,a:0))")
        }
    }

    @Test("Core's refusal reasons are named")
    func reasons() throws {
        // Every path needs a signature: a bare lock has none.
        #expect(throws: DescriptorError.unsafeMiniscript(.noSignature, "older(1)")) {
            _ = try Descriptor("wsh(older(1))")
        }
        // A height lock and a time lock on one path.
        let mixed = "and_b(older(1),a:older(4194305))"
        #expect(throws: DescriptorError.unsafeMiniscript(.timelockMix, mixed)) {
            _ = try Descriptor("wsh(and_b(\(mixed),s:pk(\(Self.key))))")
        }
        // A branch that needs no signature at all.
        #expect(throws: DescriptorError.unsafeMiniscript(.noSignature, "or_i(older(1),pk(\(Self.key)))")) {
            _ = try Descriptor("wsh(or_i(older(1),pk(\(Self.key))))")
        }
        // Malleable: a third party can pick either lock branch, and the fault is
        // reported on that subexpression, not the whole script.
        let malleable = "or_i(older(1),older(4252898))"
        #expect(throws: DescriptorError.unsafeMiniscript(.malleable, malleable)) {
            _ = try Descriptor("wsh(j:and_b(multi(2,\(Self.key),\(Self.otherKey)),s:\(malleable)))")
        }
    }

    @Test("the same key twice is refused, compared as the key the script holds")
    func duplicates() throws {
        let xonly = String(Self.key.dropFirst(2))
        // Under tapscript 02K, 03K and K all compile to the same 32 bytes.
        #expect(throws: DescriptorError.unsafeMiniscript(.duplicateKeys, "and_v(v:pk(\(Self.key)),pk(\(xonly)))")) {
            _ = try Descriptor("tr(\(Self.nums),and_v(v:pk(\(Self.key)),pk(\(xonly))))")
        }
        #expect(throws: Never.self) {
            _ = try Descriptor("tr(\(Self.nums),and_v(v:pk(\(Self.key)),pk(\(Self.otherKey))))")
        }
        // Under P2WSH a relabelled origin does not make a second key.
        let xpub = "xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL"
        #expect(throws: DescriptorError.self) {
            _ = try Descriptor("wsh(and_v(v:pk([deadbeef/1]\(xpub)/0),pk(\(xpub)/0)))")
        }
    }

    @Test("context rules: multi and multi_a, x-only keys, musig and sorted forms")
    func contextRules() {
        #expect(throws: DescriptorError.self) { _ = try Miniscript("multi(1,\(Self.key))", context: .tapscript) }
        #expect(throws: DescriptorError.self) { _ = try Miniscript("multi_a(1,\(Self.key))", context: .p2wsh) }
        #expect(throws: Never.self) { _ = try Miniscript("multi(1,\(Self.key))", context: .p2wsh) }
        #expect(throws: Never.self) { _ = try Miniscript("multi_a(1,\(Self.key))", context: .tapscript) }
        // A 32-byte key means nothing under wsh(); musig() is a Taproot construction.
        let xonly = String(Self.key.dropFirst(2))
        #expect(throws: DescriptorError.invalidKey) { _ = try Descriptor("wsh(pk(\(xonly)))") }
        #expect(throws: DescriptorError.self) { _ = try Descriptor("wsh(pk(musig(\(Self.key),\(Self.otherKey))))") }
        #expect(throws: Never.self) { _ = try Descriptor("tr(\(Self.nums),pk(\(xonly)))") }
        // sortedmulti is a descriptor-level form in Core, never a fragment.
        #expect(throws: DescriptorError.unknownExpression("sortedmulti_a")) {
            _ = try Descriptor("tr(\(Self.nums),and_v(v:sortedmulti_a(1,\(Self.key)),pk(\(Self.otherKey))))")
        }
        #expect(throws: DescriptorError.invalidMiniscript("vv: wrapper")) {
            _ = try Miniscript("vv:pk(\(Self.key))", context: .tapscript)
        }
    }

    @Test("a relative lock past 65,535 blocks is Core's warning, not a refusal")
    func largeLock() throws {
        let descriptor = try Descriptor("tr(\(Self.nums),and_v(v:pk(\(Self.key)),older(70000)))")
        #expect(descriptor.serialized().contains("older(70000)"))
        #expect(throws: DescriptorError.self) { _ = try Miniscript("older(0)", context: .tapscript) }
        #expect(throws: DescriptorError.self) { _ = try Miniscript("after(2147483648)", context: .tapscript) }
    }

    @Test("the script length bounds are Core's")
    func limits() {
        #expect(Miniscript.maxScriptLength(.p2wsh) == 3600)
        #expect(Miniscript.maxScriptLength(.tapscript) == 329_482)
    }

    @Test("a leaf-top multisig is a descriptor form; the same name inside a fragment is miniscript")
    func leafPrecedence() throws {
        let plain = try Descriptor("tr(\(Self.nums),multi_a(1,\(Self.key)))")
        guard case let .tr(_, .some(.leaf(leaf))) = plain.expression else { Issue.record("not a leaf"); return }
        #expect(leaf == .multiA(threshold: 1, keys: leaf.keys))
        let wrapped = try Descriptor("tr(\(Self.nums),n:multi_a(1,\(Self.key)))")
        guard case let .tr(_, .some(.leaf(.miniscript(node)))) = wrapped.expression else {
            Issue.record("not a miniscript leaf"); return
        }
        #expect(node.fragment == .wrapN)
        #expect(node.subs[0].fragment == .multiA)
        #expect(plain.serialized() != wrapped.serialized())
    }
}
