import Foundation

/// Core's miniscript grammar, read with the descriptor's own cursor so a leaf
/// shares its key grammar (origins, extended keys, multipath, `musig()`).
extension Parser {
    /// A tapscript leaf or a P2WSH body: the four multisig forms Core keeps at
    /// the descriptor level (`multi_a`/`sortedmulti_a` under `tr()`,
    /// `multi`/`sortedmulti` under `wsh()`), or a miniscript. The dedicated
    /// forms are matched first, so `sortedmulti_a(…)` is never a fragment and
    /// `n:multi_a(…)` is always one.
    mutating func parseLeaf(context: Miniscript.Context) throws -> Descriptor.Leaf {
        let start = index
        let name = takeWhile { $0.isLetter || $0 == "_" }
        switch (name, context) {
        case ("multi_a", .tapscript):
            let (threshold, keys) = try parseMultisigArguments(context: context, maxKeys: Multisig.maxKeys)
            return .multiA(threshold: threshold, keys: keys)
        case ("sortedmulti_a", .tapscript):
            let (threshold, keys) = try parseMultisigArguments(context: context, maxKeys: Multisig.maxKeys)
            return .sortedMultiA(threshold: threshold, keys: keys)
        case ("multi", .p2wsh):
            let (threshold, keys) = try parseMultisigArguments(context: context, maxKeys: Multisig.maxLegacyKeys)
            return .multi(threshold: threshold, keys: keys)
        case ("sortedmulti", .p2wsh):
            let (threshold, keys) = try parseMultisigArguments(context: context, maxKeys: Multisig.maxLegacyKeys)
            return .sortedMulti(threshold: threshold, keys: keys)
        default:
            index = start
            let node = try parseMiniscript(context: context, depth: 0)
            guard node.isValidTopLevel else {
                throw DescriptorError.invalidMiniscript("not a valid top-level expression")
            }
            return .miniscript(node)
        }
    }

    /// `(k,KEY,…)`: a threshold in `1...n` over at most `maxKeys` keys.
    mutating func parseMultisigArguments(context: Miniscript.Context,
                                         maxKeys: Int) throws -> (Int, [Descriptor.KeyExpression]) {
        try expect("(")
        let threshold = try parseDecimal(or: .invalidThreshold)
        var keys: [Descriptor.KeyExpression] = []
        while consume(",") { keys.append(try parseLeafKey(context: context)) }
        try expect(")")
        guard threshold >= 1, Int(threshold) <= keys.count, keys.count <= maxKeys else {
            throw DescriptorError.invalidThreshold
        }
        return (Int(threshold), keys)
    }

    /// A key inside a leaf. Tapscript takes what `tr()` takes, `musig()` and
    /// x-only keys included; P2WSH takes neither (`ParsePubkeyInner` in Core).
    mutating func parseLeafKey(context: Miniscript.Context) throws -> Descriptor.KeyExpression {
        try parseKeyExpression(allowMusig: context == .tapscript, allowXOnly: context == .tapscript)
    }

    // MARK: - Miniscript

    /// Core's `FromString`: an optional run of wrapper letters and a colon,
    /// then a fragment. Wrappers apply from the one nearest the colon outward
    /// (`vc:pk_k(K)` is `v(c(pk_k(K)))`), and each counts toward the depth
    /// bound, so the bound holds on the tree that is built, not on the frames
    /// that build it.
    ///
    /// Recursion is three small frames per nesting level (this function, the
    /// table dispatch in `parseFragment`, and one arm), because a debug
    /// build's frame holds every temporary of a function at once:
    /// `Miniscript.maximumDepth` was set by measuring what a 512 KB thread
    /// stack holds, with room to spare.
    mutating func parseMiniscript(context: Miniscript.Context, depth: Int) throws -> Miniscript {
        let wrappers = try parseWrapperRun()
        let innerDepth = depth + wrappers.count + 1
        guard innerDepth <= Miniscript.maximumDepth else { throw DescriptorError.miniscriptTooDeep }
        var node = try parseFragment(context: context, depth: innerDepth)
        for letter in wrappers.reversed() {
            node = try Self.wrap(node, with: letter, context: context)
        }
        return node
    }

    /// Lowercase letters immediately followed by a colon, or nothing. A
    /// fragment name is never followed by a colon, so `pk(` and `and_v(`
    /// leave the cursor where it was. `vv` is refused as Core refuses it.
    private mutating func parseWrapperRun() throws -> [Character] {
        let start = index
        let run = takeWhile { ("a" ... "z").contains($0) }
        guard !run.isEmpty, consume(":") else {
            index = start
            return []
        }
        guard !run.contains("vv") else { throw DescriptorError.invalidMiniscript("vv: wrapper") }
        return Array(run)
    }

    private static func wrap(_ node: Miniscript, with letter: Character,
                             context: Miniscript.Context) throws -> Miniscript {
        switch letter {
        case "a": return Miniscript(fragment: .wrapA, subs: [node], context: context)
        case "s": return Miniscript(fragment: .wrapS, subs: [node], context: context)
        case "c": return Miniscript(fragment: .wrapC, subs: [node], context: context)
        case "d": return Miniscript(fragment: .wrapD, subs: [node], context: context)
        case "v": return Miniscript(fragment: .wrapV, subs: [node], context: context)
        case "j": return Miniscript(fragment: .wrapJ, subs: [node], context: context)
        case "n": return Miniscript(fragment: .wrapN, subs: [node], context: context)
        case "t":
            return Miniscript(fragment: .andV, subs: [node, Miniscript(fragment: .just1, context: context)],
                              context: context)
        case "l":
            return Miniscript(fragment: .orI, subs: [Miniscript(fragment: .just0, context: context), node],
                              context: context)
        case "u":
            return Miniscript(fragment: .orI, subs: [node, Miniscript(fragment: .just0, context: context)],
                              context: context)
        default: throw DescriptorError.invalidMiniscript("\(letter): wrapper")
        }
    }

    /// What a fragment name takes.
    private enum Form {
        case constant(Miniscript.Fragment)
        /// `pk_k`/`pk_h`, or their checked sugar `pk`/`pkh` (`c:` of the same).
        case key(Miniscript.Fragment, checked: Bool)
        case hash(Miniscript.Fragment, length: Int)
        case lock(Miniscript.Fragment)
        case multi(Miniscript.Fragment)
        case thresh
        /// `and_n(X,Y)` is `andor(X,Y,0)`.
        case andN
        case combinator(Miniscript.Fragment, arity: Int)
    }

    private static let forms: [String: Form] = [
        "0": .constant(.just0), "1": .constant(.just1),
        "pk": .key(.pkK, checked: true), "pkh": .key(.pkH, checked: true),
        "pk_k": .key(.pkK, checked: false), "pk_h": .key(.pkH, checked: false),
        "sha256": .hash(.sha256, length: 32), "hash256": .hash(.hash256, length: 32),
        "ripemd160": .hash(.ripemd160, length: 20), "hash160": .hash(.hash160, length: 20),
        "after": .lock(.after), "older": .lock(.older),
        "multi": .multi(.multi), "multi_a": .multi(.multiA),
        "thresh": .thresh, "and_n": .andN,
        "andor": .combinator(.andOr, arity: 3),
        "and_v": .combinator(.andV, arity: 2), "and_b": .combinator(.andB, arity: 2),
        "or_b": .combinator(.orB, arity: 2), "or_c": .combinator(.orC, arity: 2),
        "or_d": .combinator(.orD, arity: 2), "or_i": .combinator(.orI, arity: 2),
    ]

    /// One small frame per nesting level besides `parseMiniscript`'s: the
    /// table lookup here, and the arm functions below hold only their own
    /// temporaries, which is what keeps a deep expression inside a thread's stack.
    private mutating func parseFragment(context: Miniscript.Context, depth: Int) throws -> Miniscript {
        let name = takeWhile { $0.isLetter || $0.isNumber || $0 == "_" }
        guard let form = Self.forms[name] else { throw DescriptorError.unknownExpression(name) }
        switch form {
        case let .constant(fragment): return Miniscript(fragment: fragment, context: context)
        case let .key(fragment, checked): return try parseKeyFragment(fragment, checked: checked, context: context)
        case let .hash(fragment, length): return try parseHashFragment(fragment, length: length, context: context)
        case let .lock(fragment): return try parseTimelock(fragment, context: context)
        case let .multi(fragment): return try parseMultiFragment(fragment, context: context)
        case .thresh: return try parseThresh(context: context, depth: depth)
        case .andN: return try parseAndN(context: context, depth: depth)
        case let .combinator(fragment, arity):
            return try parseCombinator(fragment, arity: arity, context: context, depth: depth)
        }
    }

    /// `thresh(k,X1,…,Xn)` with at least one child and `k` in `1...n`.
    private mutating func parseThresh(context: Miniscript.Context, depth: Int) throws -> Miniscript {
        try expect("(")
        let threshold = try parseDecimal(or: .invalidThreshold)
        var subs: [Miniscript] = []
        while consume(",") { subs.append(try parseMiniscript(context: context, depth: depth)) }
        try expect(")")
        guard threshold >= 1, !subs.isEmpty, Int(threshold) <= subs.count else {
            throw DescriptorError.invalidThreshold
        }
        return Miniscript(fragment: .thresh, k: threshold, subs: subs, context: context)
    }

    /// `and_n(X,Y)` is `andor(X,Y,0)`.
    private mutating func parseAndN(context: Miniscript.Context, depth: Int) throws -> Miniscript {
        let pair = try parseCombinator(.andV, arity: 2, context: context, depth: depth)
        return Miniscript(fragment: .andOr, subs: pair.subs + [Miniscript(fragment: .just0, context: context)],
                          context: context)
    }

    /// `name(X,Y)` or `name(X,Y,Z)`.
    private mutating func parseCombinator(_ fragment: Miniscript.Fragment, arity: Int,
                                          context: Miniscript.Context, depth: Int) throws -> Miniscript {
        try expect("(")
        var subs = [try parseMiniscript(context: context, depth: depth)]
        while subs.count < arity {
            try expect(",")
            subs.append(try parseMiniscript(context: context, depth: depth))
        }
        try expect(")")
        return Miniscript(fragment: fragment, subs: subs, context: context)
    }

    private mutating func parseKeyFragment(_ fragment: Miniscript.Fragment, checked: Bool,
                                           context: Miniscript.Context) throws -> Miniscript {
        try expect("(")
        let key = try parseLeafKey(context: context)
        try expect(")")
        let inner = Miniscript(fragment: fragment, keys: [key], context: context)
        return checked ? Miniscript(fragment: .wrapC, subs: [inner], context: context) : inner
    }

    private mutating func parseHashFragment(_ fragment: Miniscript.Fragment, length: Int,
                                            context: Miniscript.Context) throws -> Miniscript {
        try expect("(")
        let hex = takeWhile(\.isHexDigit)
        try expect(")")
        guard hex.count == length * 2, let data = Data(hex: hex) else {
            throw DescriptorError.invalidMiniscript("hash length")
        }
        return Miniscript(fragment: fragment, data: data, context: context)
    }

    /// `older(n)` / `after(n)` with `n` in `1...0x7FFFFFFF` (BIP68/BIP65).
    private mutating func parseTimelock(_ fragment: Miniscript.Fragment,
                                        context: Miniscript.Context) throws -> Miniscript {
        try expect("(")
        let value = try parseDecimal(or: .invalidMiniscript("lock number"))
        try expect(")")
        guard value >= 1, value < 0x8000_0000 else { throw DescriptorError.invalidMiniscript("lock range") }
        return Miniscript(fragment: fragment, k: value, context: context)
    }

    /// `multi(k,KEY,…)` in P2WSH, `multi_a(k,KEY,…)` in tapscript; never the other way.
    private mutating func parseMultiFragment(_ fragment: Miniscript.Fragment,
                                             context: Miniscript.Context) throws -> Miniscript {
        let isMultiA = fragment == .multiA
        guard isMultiA == (context == .tapscript) else {
            throw DescriptorError.invalidMiniscript(isMultiA ? "multi_a outside tapscript" : "multi outside P2WSH")
        }
        let (threshold, keys) = try parseMultisigArguments(
            context: context, maxKeys: isMultiA ? Multisig.maxKeys : Multisig.maxLegacyKeys)
        return Miniscript(fragment: fragment, k: UInt32(threshold), keys: keys, context: context)
    }

    /// ASCII digits read as a 32-bit number: no sign, no overflow.
    private mutating func parseDecimal(or error: DescriptorError) throws -> UInt32 {
        let digits = takeWhile { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let value = UInt32(digits) else { throw error }
        return value
    }
}
