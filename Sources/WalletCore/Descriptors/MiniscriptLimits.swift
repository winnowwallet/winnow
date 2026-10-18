import Foundation

/// The resource analysis Bitcoin Core runs on a miniscript before it will hold
/// one (`CalcOps`, `CalcStackSize`, `ComputeScriptLen` in `miniscript.h`):
/// how many non-push opcodes a satisfaction executes, how many stack items it
/// needs, and how long the script is, each in the script context's limits.
extension Miniscript {
    /// Core's `Ops`: the static opcode count plus the keys of any
    /// OP_CHECKMULTISIG a satisfaction (`sat`) or dissatisfaction (`dsat`)
    /// executes. `nil` means no such path exists (Core's invalid `MaxInt`).
    struct Ops: Equatable, Sendable {
        var count: UInt32
        var sat: UInt32?
        var dsat: UInt32?
    }

    /// Core's `SatInfo`: a set of execution traces, kept as the largest net
    /// stack decrease (`netDiff`) and the largest excursion above the final
    /// stack (`exec`) across them. `|` is the union of two sets, `+` their
    /// concatenation; an invalid value is the empty set.
    struct SatInfo: Equatable, Sendable {
        var valid: Bool
        var netDiff: Int32
        var exec: Int32

        init(_ netDiff: Int32, _ exec: Int32) {
            valid = true
            self.netDiff = netDiff
            self.exec = exec
        }

        private init() {
            valid = false
            netDiff = 0
            exec = 0
        }

        /// No trace at all.
        static let none = SatInfo()
        static let empty = SatInfo(0, 0)
        static let push = SatInfo(-1, 0)
        static let hash = SatInfo(0, 0)
        static let nop = SatInfo(0, 0)
        /// OP_IF or OP_NOTIF; OP_ELSE and OP_ENDIF have no stack effect.
        static let branch = SatInfo(1, 1)
        /// OP_BOOLAND, OP_BOOLOR, OP_ADD.
        static let binaryOp = SatInfo(1, 1)
        static let dup = SatInfo(-1, 0)
        static let equalVerify = SatInfo(2, 2)
        static let equal = SatInfo(1, 1)
        static let size = SatInfo(-1, 0)
        static let checkSig = SatInfo(1, 1)
        static let zeroNotEqual = SatInfo(0, 0)
        static let verify = SatInfo(1, 1)

        static func ifDup(nonzero: Bool) -> SatInfo { SatInfo(nonzero ? -1 : 0, 0) }

        static func | (a: SatInfo, b: SatInfo) -> SatInfo {
            if !a.valid { return b }
            if !b.valid { return a }
            return SatInfo(max(a.netDiff, b.netDiff), max(a.exec, b.exec))
        }

        static func + (a: SatInfo, b: SatInfo) -> SatInfo {
            if !a.valid || !b.valid { return .none }
            return SatInfo(a.netDiff + b.netDiff, max(b.exec, b.netDiff + a.exec))
        }
    }

    /// The traces that satisfy and dissatisfy one node.
    struct StackSize: Equatable, Sendable {
        var sat: SatInfo
        var dsat: SatInfo

        init(_ sat: SatInfo, _ dsat: SatInfo) {
            self.sat = sat
            self.dsat = dsat
        }

        init(both: SatInfo) {
            sat = both
            dsat = both
        }
    }

    /// The consensus opcode limit a P2WSH satisfaction must stay under.
    static let maxOps: UInt32 = 201
    /// The standardness limit on P2WSH witness stack items.
    static let maxP2WSHStackItems: Int32 = 100
    /// The consensus limit on the stack during tapscript execution.
    static let maxStackItems: Int32 = 1000
    /// The standardness limit on a P2WSH witness script.
    static let maxP2WSHScriptLength = 3600
    /// Core's bound for a tapscript leaf: a maximum-weight standard
    /// transaction (400,000) less the body of a one-in one-out transaction
    /// (378 weight) and the largest possible tapscript satisfaction (a
    /// 1,000-item stack of 65-byte items plus a full control block, 70,135
    /// bytes), less the compact size that length takes.
    static let maxTapscriptLength = 400_000 - 378 - 70_135 - 5

    static func maxScriptLength(_ context: Context) -> Int {
        context == .tapscript ? maxTapscriptLength : maxP2WSHScriptLength
    }

    static func plus(_ a: UInt32?, _ b: UInt32?) -> UInt32? {
        guard let a, let b else { return nil }
        return a + b
    }

    static func either(_ a: UInt32?, _ b: UInt32?) -> UInt32? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }

    // MARK: - CalcOps

    static func ops(_ fragment: Fragment, subs: [Miniscript], k: UInt32, keyCount: Int) -> Ops {
        let x = subs.count > 0 ? subs[0].ops : Ops(count: 0, sat: nil, dsat: nil)
        let y = subs.count > 1 ? subs[1].ops : Ops(count: 0, sat: nil, dsat: nil)
        let z = subs.count > 2 ? subs[2].ops : Ops(count: 0, sat: nil, dsat: nil)
        let keys = UInt32(keyCount)
        switch fragment {
        case .just1: return Ops(count: 0, sat: 0, dsat: nil)
        case .just0: return Ops(count: 0, sat: nil, dsat: 0)
        case .pkK: return Ops(count: 0, sat: 0, dsat: 0)
        case .pkH: return Ops(count: 3, sat: 0, dsat: 0)
        case .older, .after: return Ops(count: 1, sat: 0, dsat: nil)
        case .sha256, .ripemd160, .hash256, .hash160: return Ops(count: 4, sat: 0, dsat: nil)
        case .andV: return Ops(count: x.count + y.count, sat: plus(x.sat, y.sat), dsat: nil)
        case .andB:
            return Ops(count: 1 + x.count + y.count, sat: plus(x.sat, y.sat), dsat: plus(x.dsat, y.dsat))
        case .orB:
            return Ops(count: 1 + x.count + y.count,
                       sat: either(plus(x.sat, y.dsat), plus(y.sat, x.dsat)), dsat: plus(x.dsat, y.dsat))
        case .orD:
            return Ops(count: 3 + x.count + y.count,
                       sat: either(x.sat, plus(y.sat, x.dsat)), dsat: plus(x.dsat, y.dsat))
        case .orC:
            return Ops(count: 2 + x.count + y.count, sat: either(x.sat, plus(y.sat, x.dsat)), dsat: nil)
        case .orI:
            return Ops(count: 3 + x.count + y.count, sat: either(x.sat, y.sat), dsat: either(x.dsat, y.dsat))
        case .andOr:
            return Ops(count: 3 + x.count + y.count + z.count,
                       sat: either(plus(y.sat, x.sat), plus(x.dsat, z.sat)), dsat: plus(x.dsat, z.dsat))
        case .multi: return Ops(count: 1, sat: keys, dsat: keys)
        case .multiA: return Ops(count: keys + 1, sat: 0, dsat: 0)
        case .wrapS, .wrapC, .wrapN: return Ops(count: 1 + x.count, sat: x.sat, dsat: x.dsat)
        case .wrapA: return Ops(count: 2 + x.count, sat: x.sat, dsat: x.dsat)
        case .wrapD: return Ops(count: 3 + x.count, sat: x.sat, dsat: 0)
        case .wrapJ: return Ops(count: 4 + x.count, sat: x.sat, dsat: 0)
        case .wrapV:
            return Ops(count: x.count + (subs[0].properties.has("x") ? 1 : 0), sat: x.sat, dsat: nil)
        case .thresh: return threshOps(subs: subs, k: k)
        }
    }

    /// `sats[j]` is the largest multisig key count over the traces reaching
    /// `j` satisfied children; one child at a time, as Core does.
    private static func threshOps(subs: [Miniscript], k: UInt32) -> Ops {
        var count: UInt32 = 0
        var sats: [UInt32?] = [0]
        for sub in subs {
            count += sub.ops.count + 1
            var next: [UInt32?] = [plus(sats[0], sub.ops.dsat)]
            for j in 1 ..< sats.count {
                next.append(either(plus(sats[j], sub.ops.dsat), plus(sats[j - 1], sub.ops.sat)))
            }
            next.append(plus(sats[sats.count - 1], sub.ops.sat))
            sats = next
        }
        return Ops(count: count, sat: sats[Int(k)], dsat: sats[0])
    }

    // MARK: - CalcStackSize

    static func stackSize(_ fragment: Fragment, subs: [Miniscript], k: UInt32, keyCount: Int) -> StackSize {
        let x = subs.count > 0 ? subs[0].stackSize : StackSize(both: .none)
        let y = subs.count > 1 ? subs[1].stackSize : StackSize(both: .none)
        let z = subs.count > 2 ? subs[2].stackSize : StackSize(both: .none)
        let n = Int32(keyCount)
        switch fragment {
        case .just0: return StackSize(.none, .push)
        case .just1: return StackSize(.push, .none)
        case .older, .after: return StackSize(.push + .nop, .none)
        case .pkK: return StackSize(both: .push)
        case .pkH: return StackSize(both: .dup + .hash + .push + .equalVerify)
        case .sha256, .ripemd160, .hash256, .hash160:
            return StackSize(.size + .push + .equalVerify + .hash + .push + .equal, .none)
        case .andOr:
            return StackSize((x.sat + .branch + y.sat) | (x.dsat + .branch + z.sat),
                             x.dsat + .branch + z.dsat)
        case .andV: return StackSize(x.sat + y.sat, .none)
        case .andB: return StackSize(x.sat + y.sat + .binaryOp, x.dsat + y.dsat + .binaryOp)
        case .orB:
            return StackSize(((x.sat + y.dsat) | (x.dsat + y.sat)) + .binaryOp,
                             x.dsat + y.dsat + .binaryOp)
        case .orC: return StackSize((x.sat + .branch) | (x.dsat + .branch + y.sat), .none)
        case .orD:
            return StackSize((x.sat + .ifDup(nonzero: true) + .branch)
                | (x.dsat + .ifDup(nonzero: false) + .branch + y.sat),
                x.dsat + .ifDup(nonzero: false) + .branch + y.dsat)
        case .orI: return StackSize(.branch + (x.sat | y.sat), .branch + (x.dsat | y.dsat))
        // multi starts with k+1 items (a 0 plus k signatures), reaches n+k+3
        // after the key pushes, k and n, and ends with one.
        case .multi: return StackSize(both: SatInfo(Int32(k), Int32(k) + n + 2))
        // multi_a starts with n signatures, reaches one more after the first
        // key push, and ends with one.
        case .multiA: return StackSize(both: SatInfo(n - 1, n))
        case .wrapA, .wrapN, .wrapS: return x
        case .wrapC: return StackSize(x.sat + .checkSig, x.dsat + .checkSig)
        case .wrapD: return StackSize(.dup + .branch + x.sat, .dup + .branch)
        case .wrapV: return StackSize(x.sat + .verify, .none)
        case .wrapJ:
            return StackSize(.size + .zeroNotEqual + .branch + x.sat, .size + .zeroNotEqual + .branch)
        case .thresh: return threshStackSize(subs: subs, k: k)
        }
    }

    /// `sats[j]` is the trace set reaching `j` satisfied children; an OP_ADD
    /// follows every child but the first, then the push of `k` and OP_EQUAL.
    private static func threshStackSize(subs: [Miniscript], k: UInt32) -> StackSize {
        var sats: [SatInfo] = [.empty]
        for (index, sub) in subs.enumerated() {
            let add: SatInfo = index > 0 ? .binaryOp : .empty
            var next = [sats[0] + sub.stackSize.dsat + add]
            for j in 1 ..< sats.count {
                next.append(((sats[j] + sub.stackSize.dsat) | (sats[j - 1] + sub.stackSize.sat)) + add)
            }
            next.append(sats[sats.count - 1] + sub.stackSize.sat + add)
            sats = next
        }
        return StackSize(sats[Int(k)] + .push + .equal, sats[0] + .push + .equal)
    }

    // MARK: - ComputeScriptLen

    /// The compiled length of a fragment from its children's, without keys:
    /// a key is 33 bytes in P2WSH and 32 in tapscript, each pushed.
    static func scriptLength(_ fragment: Fragment, firstSub: Properties, subsLength: Int, k: UInt32,
                             subCount: Int, keyCount: Int, context: Context) -> Int {
        let number = Script.numberLength(Int(k))
        switch fragment {
        case .just1, .just0: return 1
        case .pkK: return context == .tapscript ? 33 : 34
        case .pkH: return 3 + 21
        case .older, .after: return 1 + number
        case .hash256, .sha256: return 4 + 2 + 33
        case .hash160, .ripemd160: return 4 + 2 + 21
        case .multi: return 1 + Script.numberLength(keyCount) + number + 34 * keyCount
        case .multiA: return (1 + 32 + 1) * keyCount + number + 1
        case .andV: return subsLength
        case .wrapV: return subsLength + (firstSub.has("x") ? 1 : 0)
        case .wrapS, .wrapC, .wrapN, .andB, .orB: return subsLength + 1
        case .wrapA, .orC: return subsLength + 2
        case .wrapD, .orD, .orI, .andOr: return subsLength + 3
        case .wrapJ: return subsLength + 4
        case .thresh: return subsLength + subCount + number
        }
    }
}
