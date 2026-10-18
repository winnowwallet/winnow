import Foundation

// MARK: - Compiling

extension Miniscript {
    /// Core's `ToScript`, byte for byte. `keyBytes` resolves a key expression
    /// to its 33-byte compressed public key; the compiler pushes that in
    /// P2WSH and its 32-byte x-only form in tapscript, and hashes the same
    /// bytes for `pk_h`. A `v:` wrapper turns its child's last opcode into
    /// the VERIFY form where one exists and appends OP_VERIFY where none does
    /// (the child's `x` property).
    public func script(keyBytes: (Descriptor.KeyExpression) throws -> Data) throws -> Script {
        var script = Script(Data())
        try emit(into: &script, verify: false, keyBytes: keyBytes)
        return script
    }

    private func keyPush(_ key: Descriptor.KeyExpression,
                         keyBytes: (Descriptor.KeyExpression) throws -> Data) throws -> Data {
        let compressed = try keyBytes(key)
        guard compressed.count == 33 else { throw DescriptorError.invalidKey }
        return context == .tapscript ? Data(compressed.dropFirst()) : compressed
    }

    private func emit(into script: inout Script, verify: Bool,
                      keyBytes: (Descriptor.KeyExpression) throws -> Data) throws {
        switch fragment {
        case .pkK:
            script.appendPush(try keyPush(keys[0], keyBytes: keyBytes))
        case .pkH:
            script.appendOpcode(Script.Op.dup)
            script.appendOpcode(Script.Op.hash160)
            script.appendPush(Hash160.hash(try keyPush(keys[0], keyBytes: keyBytes)))
            script.appendOpcode(Script.Op.equalVerify)
        case .older:
            script.appendScriptNumber(Int(k))
            script.appendOpcode(Script.Op.checkSequenceVerify)
        case .after:
            script.appendScriptNumber(Int(k))
            script.appendOpcode(Script.Op.checkLockTimeVerify)
        case .sha256: emitHash(into: &script, opcode: Script.Op.sha256, verify: verify)
        case .ripemd160: emitHash(into: &script, opcode: Script.Op.ripemd160, verify: verify)
        case .hash256: emitHash(into: &script, opcode: Script.Op.hash256, verify: verify)
        case .hash160: emitHash(into: &script, opcode: Script.Op.hash160, verify: verify)
        case .just1: script.appendScriptNumber(1)
        case .just0: script.appendScriptNumber(0)
        case .multi: try emitMulti(into: &script, verify: verify, keyBytes: keyBytes)
        case .multiA: try emitMultiA(into: &script, verify: verify, keyBytes: keyBytes)
        case .thresh:
            try subs[0].emit(into: &script, verify: false, keyBytes: keyBytes)
            for sub in subs.dropFirst() {
                try sub.emit(into: &script, verify: false, keyBytes: keyBytes)
                script.appendOpcode(Script.Op.add)
            }
            script.appendScriptNumber(Int(k))
            script.appendOpcode(verify ? Script.Op.equalVerify : Script.Op.equal)
        default:
            try emitCombinator(into: &script, verify: verify, keyBytes: keyBytes)
        }
    }

    /// `OP_SIZE <32> OP_EQUALVERIFY <hash op> <hash> OP_EQUAL(VERIFY)`.
    private func emitHash(into script: inout Script, opcode: UInt8, verify: Bool) {
        script.appendOpcode(Script.Op.size)
        script.appendScriptNumber(32)
        script.appendOpcode(Script.Op.equalVerify)
        script.appendOpcode(opcode)
        script.appendPush(data)
        script.appendOpcode(verify ? Script.Op.equalVerify : Script.Op.equal)
    }

    /// `<k> <key_1> … <key_n> <n> OP_CHECKMULTISIG(VERIFY)`.
    private func emitMulti(into script: inout Script, verify: Bool,
                           keyBytes: (Descriptor.KeyExpression) throws -> Data) throws {
        script.appendScriptNumber(Int(k))
        for key in keys { script.appendPush(try keyPush(key, keyBytes: keyBytes)) }
        script.appendScriptNumber(keys.count)
        script.appendOpcode(verify ? Script.Op.checkMultiSigVerify : Script.Op.checkMultiSig)
    }

    /// `<key_1> OP_CHECKSIG <key_i> OP_CHECKSIGADD … <k> OP_NUMEQUAL(VERIFY)`.
    private func emitMultiA(into script: inout Script, verify: Bool,
                            keyBytes: (Descriptor.KeyExpression) throws -> Data) throws {
        for (index, key) in keys.enumerated() {
            script.appendPush(try keyPush(key, keyBytes: keyBytes))
            script.appendOpcode(index == 0 ? Script.Op.checkSig : Script.Op.checkSigAdd)
        }
        script.appendScriptNumber(Int(k))
        script.appendOpcode(verify ? Script.Op.numEqualVerify : Script.Op.numEqual)
    }

    /// The wrappers and the two- and three-child combinators. A `v:` child, a
    /// `s:` child and the second child of `and_v` are the ones a following
    /// OP_VERIFY can fold into (Core's `downfn`).
    private func emitCombinator(into script: inout Script, verify: Bool,
                                keyBytes: (Descriptor.KeyExpression) throws -> Data) throws {
        let x = subs[0]
        switch fragment {
        case .wrapA:
            script.appendOpcode(Script.Op.toAltStack)
            try x.emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.fromAltStack)
        case .wrapS:
            script.appendOpcode(Script.Op.swap)
            try x.emit(into: &script, verify: verify, keyBytes: keyBytes)
        case .wrapC:
            try x.emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(verify ? Script.Op.checkSigVerify : Script.Op.checkSig)
        case .wrapD:
            script.appendOpcode(Script.Op.dup)
            script.appendOpcode(Script.Op.opIf)
            try x.emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.endIf)
        case .wrapV:
            try x.emit(into: &script, verify: true, keyBytes: keyBytes)
            if x.properties.has("x") { script.appendOpcode(Script.Op.verify) }
        case .wrapJ:
            script.appendOpcode(Script.Op.size)
            script.appendOpcode(Script.Op.zeroNotEqual)
            script.appendOpcode(Script.Op.opIf)
            try x.emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.endIf)
        case .wrapN:
            try x.emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.zeroNotEqual)
        case .andV:
            try x.emit(into: &script, verify: false, keyBytes: keyBytes)
            try subs[1].emit(into: &script, verify: verify, keyBytes: keyBytes)
        case .andB:
            try x.emit(into: &script, verify: false, keyBytes: keyBytes)
            try subs[1].emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.boolAnd)
        case .orB:
            try x.emit(into: &script, verify: false, keyBytes: keyBytes)
            try subs[1].emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.boolOr)
        case .orD:
            try x.emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.ifDup)
            script.appendOpcode(Script.Op.notIf)
            try subs[1].emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.endIf)
        case .orC:
            try x.emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.notIf)
            try subs[1].emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.endIf)
        case .orI:
            script.appendOpcode(Script.Op.opIf)
            try x.emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.opElse)
            try subs[1].emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.endIf)
        case .andOr:
            try x.emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.notIf)
            try subs[2].emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.opElse)
            try subs[1].emit(into: &script, verify: false, keyBytes: keyBytes)
            script.appendOpcode(Script.Op.endIf)
        default:
            preconditionFailure("\(fragment) is not a combinator")
        }
    }
}

// MARK: - Printing

extension Miniscript: CustomStringConvertible {
    /// Core's `ToString`: the canonical text, with its sugar (`pk`, `pkh`,
    /// `t:`, `l:`, `u:`, `and_n`) and a colon between a run of wrappers and
    /// the fragment they wrap.
    public var description: String { serialized(wrapped: false) }

    private func serialized(wrapped: Bool) -> String {
        switch fragment {
        case .wrapA: return "a" + subs[0].serialized(wrapped: true)
        case .wrapS: return "s" + subs[0].serialized(wrapped: true)
        case .wrapC where subs[0].fragment == .pkK:
            return (wrapped ? ":" : "") + "pk(" + Serializer.serialize(subs[0].keys[0]) + ")"
        case .wrapC where subs[0].fragment == .pkH:
            return (wrapped ? ":" : "") + "pkh(" + Serializer.serialize(subs[0].keys[0]) + ")"
        case .wrapC: return "c" + subs[0].serialized(wrapped: true)
        case .wrapD: return "d" + subs[0].serialized(wrapped: true)
        case .wrapV: return "v" + subs[0].serialized(wrapped: true)
        case .wrapJ: return "j" + subs[0].serialized(wrapped: true)
        case .wrapN: return "n" + subs[0].serialized(wrapped: true)
        case .andV where subs[1].fragment == .just1: return "t" + subs[0].serialized(wrapped: true)
        case .orI where subs[0].fragment == .just0: return "l" + subs[1].serialized(wrapped: true)
        case .orI where subs[1].fragment == .just0: return "u" + subs[0].serialized(wrapped: true)
        default: return (wrapped ? ":" : "") + plainText
        }
    }

    /// The fragment by name, children unwrapped.
    private var plainText: String {
        let children = subs.map { $0.serialized(wrapped: false) }
        let keyTexts = keys.map(Serializer.serialize)
        switch fragment {
        case .pkK: return "pk_k(\(keyTexts[0]))"
        case .pkH: return "pk_h(\(keyTexts[0]))"
        case .after: return "after(\(k))"
        case .older: return "older(\(k))"
        case .hash256: return "hash256(\(data.hex))"
        case .hash160: return "hash160(\(data.hex))"
        case .sha256: return "sha256(\(data.hex))"
        case .ripemd160: return "ripemd160(\(data.hex))"
        case .just1: return "1"
        case .just0: return "0"
        case .andV: return "and_v(\(children[0]),\(children[1]))"
        case .andB: return "and_b(\(children[0]),\(children[1]))"
        case .orB: return "or_b(\(children[0]),\(children[1]))"
        case .orD: return "or_d(\(children[0]),\(children[1]))"
        case .orC: return "or_c(\(children[0]),\(children[1]))"
        case .orI: return "or_i(\(children[0]),\(children[1]))"
        case .andOr where subs[2].fragment == .just0: return "and_n(\(children[0]),\(children[1]))"
        case .andOr: return "andor(\(children[0]),\(children[1]),\(children[2]))"
        case .multi: return "multi(\(([String(k)] + keyTexts).joined(separator: ",")))"
        case .multiA: return "multi_a(\(([String(k)] + keyTexts).joined(separator: ",")))"
        case .thresh: return "thresh(\(([String(k)] + children).joined(separator: ",")))"
        case .wrapA, .wrapS, .wrapC, .wrapD, .wrapV, .wrapJ, .wrapN:
            preconditionFailure("wrappers print as letters")
        }
    }
}
