import Foundation

/// A miniscript: the structured spending policy a `tr()` leaf or a `wsh()`
/// body holds, as Bitcoin Core defines it (`src/script/miniscript.h`, the
/// reference this is ported from, and held to by its vectors in
/// `MiniscriptTests`). Parsing, typing, compiling to the exact script bytes
/// and printing the canonical text live here; satisfying one is a later step.
///
/// A node is Core's `Node`: a fragment, its `k` (a threshold or a lock
/// value), its keys, its hash preimage commitment, its children, and the
/// context it compiles in, since `multi` exists only in P2WSH, `multi_a` only
/// in tapscript, and a key is 33 bytes in one and 32 in the other. The
/// properties and resource figures are computed once, at construction.
public struct Miniscript: Sendable, Equatable {
    /// The script a miniscript compiles into: a BIP342 tapscript leaf or a
    /// BIP141 P2WSH witness script.
    public enum Context: Sendable, Equatable {
        case tapscript
        case p2wsh
    }

    /// Core's `Fragment`. `pk()` and `pkh()` are `c:pk_k` and `c:pk_h`;
    /// `t:`, `l:`, `u:` and `and_n()` are `and_v(X,1)`, `or_i(0,X)`,
    /// `or_i(X,0)` and `andor(X,Y,0)`, so no case exists for them.
    public enum Fragment: Sendable, Equatable {
        case just0, just1
        case pkK, pkH
        case older, after
        case sha256, hash256, ripemd160, hash160
        case andV, andB, andOr
        case orB, orC, orD, orI
        case thresh
        case multi, multiA
        case wrapA, wrapS, wrapC, wrapD, wrapV, wrapJ, wrapN
    }

    /// Why a miniscript is refused as a spending policy, in the order Core
    /// reports them.
    public enum Problem: Sendable, Equatable {
        /// No valid type, or longer than the context allows.
        case invalid
        /// A third party could alter a valid witness (no `m`).
        case malleable
        /// Some satisfaction needs no signature at all (no `s`).
        case noSignature
        /// One path mixes a height lock with a time lock (no `k`).
        case timelockMix
        /// The same key appears twice.
        case duplicateKeys
        /// A satisfaction can exceed the opcode or stack limits.
        case resourceLimits
        /// No satisfaction exists at all.
        case unsatisfiable
    }

    public let fragment: Fragment
    /// The threshold of `thresh`, `multi` and `multi_a`; the value of `older`
    /// and `after`; zero elsewhere.
    public let k: UInt32
    public let keys: [Descriptor.KeyExpression]
    /// The 32-byte (`sha256`, `hash256`) or 20-byte (`ripemd160`, `hash160`) hash.
    public let data: Data
    public let subs: [Miniscript]
    public let context: Context
    public let properties: Properties
    /// The length of the compiled script, without compiling it.
    public let scriptLength: Int
    let ops: Ops
    let stackSize: StackSize

    /// The most nested a fragment may be, wrappers counted. Core bounds only
    /// the script's length, which allows thousands of levels; this parser is
    /// recursive descent, and a bound is what makes a hostile string an error
    /// rather than a stack exhaustion, as `Parser.maximumTreeDepth` is for
    /// the taproot tree. The value is measured, not chosen: a debug build
    /// parses 96 levels on a 512 KB thread stack, the smallest a test or an
    /// app thread gets, and the bound is half of that. Real policies are
    /// nowhere near it; Liana's deepest templates sit under thirty.
    public static let maximumDepth = 48

    /// Builds a node whose arity, `k` and keys the parser has already checked.
    init(fragment: Fragment, k: UInt32 = 0, keys: [Descriptor.KeyExpression] = [], data: Data = Data(),
         subs: [Miniscript] = [], context: Context) {
        self.fragment = fragment
        self.k = k
        self.keys = keys
        self.data = data
        self.subs = subs
        self.context = context
        let subProperties = subs.map(\.properties)
        properties = Properties.compute(fragment, subs: subProperties, k: k, context: context)
        scriptLength = Self.scriptLength(fragment, firstSub: subProperties.first ?? [],
                                         subsLength: subs.reduce(0) { $0 + $1.scriptLength }, k: k,
                                         subCount: subs.count, keyCount: keys.count, context: context)
        ops = Self.ops(fragment, subs: subs, k: k, keyCount: keys.count)
        stackSize = Self.stackSize(fragment, subs: subs, k: k, keyCount: keys.count)
    }

    /// Parses Core's miniscript grammar in `context`. Like Core's
    /// `FromString`, the result is a valid top-level expression or an error;
    /// whether it is also safe to hold funds is `problem(hasDuplicateKeys:)`.
    public init(_ text: String, context: Context) throws {
        var parser = Parser(text)
        let node = try parser.parseMiniscript(context: context, depth: 0)
        guard parser.atEnd else { throw DescriptorError.unexpectedCharacter(parser.peek()!) }
        guard node.isValidTopLevel else { throw DescriptorError.invalidMiniscript("not a valid top-level expression") }
        self = node
    }

    // MARK: - Core's checks

    /// A type exists and the script fits the context.
    public var isValid: Bool { !properties.isEmpty && scriptLength <= Self.maxScriptLength(context) }
    /// Valid, and of type `B`: a complete script, not a fragment of one.
    public var isValidTopLevel: Bool { isValid && properties.has("B") }
    public var isNonMalleable: Bool { properties.has("m") }
    public var needsSignature: Bool { properties.has("s") }
    public var mixesTimelocks: Bool { !properties.has("k") }

    /// The opcodes a non-malleable satisfaction executes, or nil when none exists.
    var opsNeeded: UInt32? {
        guard let sat = ops.sat else { return nil }
        return ops.count + sat
    }

    /// Anything but `V` leaves one element on the stack.
    private var leavesAnElement: Bool { !(properties & "BKW").isEmpty }

    /// The witness stack items a non-malleable satisfaction needs.
    var satisfactionStackItems: Int32? {
        guard stackSize.sat.valid else { return nil }
        return stackSize.sat.netDiff + (leavesAnElement ? 1 : 0)
    }

    /// The largest stack a non-malleable satisfaction reaches while executing.
    var executionStackItems: Int32? {
        guard stackSize.sat.valid else { return nil }
        return stackSize.sat.exec + (leavesAnElement ? 1 : 0)
    }

    /// Tapscript has no opcode limit; P2WSH has the consensus 201.
    public var withinOpsLimit: Bool {
        guard context == .p2wsh, let needed = opsNeeded else { return true }
        return needed <= Self.maxOps
    }

    /// P2WSH is bounded by the standard witness stack, tapscript by the
    /// consensus stack during execution.
    public var withinStackLimit: Bool {
        if context == .tapscript {
            guard let items = executionStackItems else { return true }
            return items <= Self.maxStackItems
        }
        guard let items = satisfactionStackItems else { return true }
        return items <= Self.maxP2WSHStackItems
    }

    /// Some satisfaction exists.
    public var isSatisfiable: Bool { satisfactionStackItems != nil }

    /// Core's `ValidSatisfactions`: a valid satisfaction is also a spendable one.
    public var withinResourceLimits: Bool { isValid && withinOpsLimit && withinStackLimit }

    /// Core's `IsSaneSubexpression` short of its duplicate-key check, which
    /// needs the keys resolved and is the descriptor's to make.
    public var isSaneSubexpression: Bool { withinResourceLimits && isNonMalleable && !mixesTimelocks }

    /// Core's `IsSane` short of the duplicate-key check: safe as a script on its own.
    public var isSane: Bool { isValidTopLevel && isSaneSubexpression && needsSignature }

    /// Every key, this node's first, then its children's in order.
    public var allKeys: [Descriptor.KeyExpression] { keys + subs.flatMap(\.allKeys) }

    /// Why this miniscript cannot hold funds, and the subexpression at fault,
    /// or nil when it is sane and satisfiable. `hasDuplicateKeys` is the
    /// descriptor's finding over the resolved keys.
    public func problem(hasDuplicateKeys: Bool) -> (problem: Problem, culprit: Miniscript)? {
        if let culprit = firstUnsafeSubexpression {
            return (culprit.localProblem, culprit)
        }
        if !isValidTopLevel { return (.invalid, self) }
        if !needsSignature { return (.noSignature, self) }
        if hasDuplicateKeys { return (.duplicateKeys, self) }
        if !isSatisfiable { return (.unsatisfiable, self) }
        return nil
    }

    /// The deepest, leftmost subexpression that is not sane, as Core's
    /// `FindInsaneSub` finds it.
    private var firstUnsafeSubexpression: Miniscript? {
        for sub in subs {
            if let found = sub.firstUnsafeSubexpression { return found }
        }
        return isSaneSubexpression ? nil : self
    }

    /// The first failing check of a subexpression, in Core's order.
    private var localProblem: Problem {
        if !isValid { return .invalid }
        if !isNonMalleable { return .malleable }
        if mixesTimelocks { return .timelockMix }
        return .resourceLimits
    }
}
