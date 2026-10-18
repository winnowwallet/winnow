import Foundation

extension Miniscript {
    /// The type system of Bitcoin Core's miniscript (`src/script/miniscript.h`):
    /// one base type among `B`, `V`, `K`, `W`; the correctness properties
    /// `z o n d u`; the malleability properties `e f s m`; `x`, an expensive
    /// verify; and the timelock classes `g h i j k`. Written as string literals
    /// of letters, the way Core writes its `_mst` literals, so `compute` below
    /// reads like the reference tables it is ported from.
    public struct Properties: OptionSet, Sendable, Hashable, ExpressibleByStringLiteral,
        CustomStringConvertible {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        /// The nineteen letters, in bit order.
        static let letters: [Character] = Array("BVKWzondufesmxghijk")

        /// `"Bzud"`: a set of letters. A letter outside the nineteen is a
        /// programming error, never an input error, so it traps.
        public init(_ letters: String) {
            var raw: UInt32 = 0
            for letter in letters {
                guard let bit = Self.letters.firstIndex(of: letter) else {
                    preconditionFailure("unknown miniscript property \(letter)")
                }
                raw |= 1 << UInt32(bit)
            }
            self.init(rawValue: raw)
        }

        public init(stringLiteral value: String) {
            self.init(value)
        }

        public var description: String {
            String(Self.letters.enumerated().compactMap {
                rawValue & (1 << UInt32($0.offset)) != 0 ? $0.element : nil
            })
        }

        /// Core's `<<`: every property in `required` is present.
        public func has(_ required: Properties) -> Bool { isSuperset(of: required) }

        /// Core's `.If(condition)`: this set when `condition` holds, else nothing.
        func when(_ condition: Bool) -> Properties { condition ? self : [] }

        static func & (lhs: Properties, rhs: Properties) -> Properties { lhs.intersection(rhs) }
        static func | (lhs: Properties, rhs: Properties) -> Properties { lhs.union(rhs) }
    }
}

// MARK: - Core's ComputeType

extension Miniscript.Properties {
    /// BIP68 `SEQUENCE_LOCKTIME_TYPE_FLAG`: a relative lock counted in 512-second units.
    static let sequenceTypeFlag: UInt32 = 1 << 22
    /// BIP65: an absolute lock at or above this value is a time, below it a height.
    static let locktimeThreshold: UInt32 = 500_000_000

    /// Core's `ComputeType` followed by `SanitizeType`: the properties of a
    /// fragment from its children's, its `k`, and the script context. Every arm
    /// is the reference table's formula; the comments there explain each term.
    static func compute(_ fragment: Miniscript.Fragment, subs: [Self], k: UInt32,
                        context: Miniscript.Context) -> Self {
        let x = subs.count > 0 ? subs[0] : []
        let y = subs.count > 1 ? subs[1] : []
        let z = subs.count > 2 ? subs[2] : []
        let computed: Self
        switch fragment {
        case .pkK: computed = "Konudemsxk"
        case .pkH: computed = "Knudemsxk"
        case .older:
            computed = Self("g").when(k & sequenceTypeFlag != 0)
                | Self("h").when(k & sequenceTypeFlag == 0) | "Bzfmxk"
        case .after:
            computed = Self("i").when(k >= locktimeThreshold)
                | Self("j").when(k < locktimeThreshold) | "Bzfmxk"
        case .sha256, .ripemd160, .hash256, .hash160: computed = "Bonudmk"
        case .just1: computed = "Bzufmxk"
        case .just0: computed = "Bzudemsxk"
        case .wrapA: computed = Self("W").when(x.has("B")) | (x & "ghijk") | (x & "udfems") | "x"
        case .wrapS: computed = Self("W").when(x.has("Bo")) | (x & "ghijk") | (x & "udfemsx")
        case .wrapC: computed = Self("B").when(x.has("K")) | (x & "ghijk") | (x & "ondfem") | "us"
        case .wrapD:
            // `d:` is `u` under tapscript only: MINIMALIF is consensus there and policy in P2WSH.
            computed = Self("B").when(x.has("Vz")) | Self("o").when(x.has("z")) | Self("e").when(x.has("f"))
                | (x & "ghijk") | (x & "ms") | Self("u").when(context == .tapscript) | "ndx"
        case .wrapV: computed = Self("V").when(x.has("B")) | (x & "ghijk") | (x & "zonms") | "fx"
        case .wrapJ:
            computed = Self("B").when(x.has("Bn")) | Self("e").when(x.has("f"))
                | (x & "ghijk") | (x & "oums") | "ndx"
        case .wrapN: computed = (x & "ghijk") | (x & "Bzondfems") | "ux"
        case .andV: computed = andV(x, y)
        case .andB: computed = andB(x, y)
        case .orB: computed = orB(x, y)
        case .orD: computed = orD(x, y)
        case .orC: computed = orC(x, y)
        case .orI: computed = orI(x, y)
        case .andOr: computed = andOr(x, y, z)
        case .multi: computed = "Bnudemsk"
        case .multiA: computed = "Budemsk"
        case .thresh: computed = thresh(subs: subs, k: k)
        }
        return sanitized(computed)
    }

    /// Core's `SanitizeType`: a node without exactly one base type has no type.
    static func sanitized(_ properties: Self) -> Self {
        let bases = ["B", "V", "K", "W"].filter { properties.has(Self($0)) }.count
        if bases == 0 { return [] }
        assert(bases == 1, "miniscript base types conflict")
        return properties
    }

    /// Whether two subexpressions can sit on one satisfaction path without
    /// mixing a height lock with a time lock (relative `g`/`h`, absolute `i`/`j`).
    static func compatibleTimelocks(_ x: Self, _ y: Self) -> Bool {
        !((x.has("g") && y.has("h")) || (x.has("h") && y.has("g"))
            || (x.has("i") && y.has("j")) || (x.has("j") && y.has("i")))
    }

    static func andV(_ x: Self, _ y: Self) -> Self {
        (y & "KVB").when(x.has("V")) // B=V_x*B_y, V=V_x*V_y, K=V_x*K_y
            | (x & "n") | (y & "n").when(x.has("z")) // n=n_x+z_x*n_y
            | ((x | y) & "o").when((x | y).has("z")) // o=o_x*z_y+z_x*o_y
            | (x & y & "mz") // m=m_x*m_y, z=z_x*z_y
            | ((x | y) & "s") // s=s_x+s_y
            | Self("f").when(y.has("f") || x.has("s")) // f=f_y+s_x
            | (y & "ux") // u=u_y, x=x_y
            | ((x | y) & "ghij")
            | Self("k").when((x & y).has("k") && compatibleTimelocks(x, y))
    }

    static func andB(_ x: Self, _ y: Self) -> Self {
        (x & "B").when(y.has("W")) // B=B_x*W_y
            | ((x | y) & "o").when((x | y).has("z")) // o=o_x*z_y+z_x*o_y
            | (x & "n") | (y & "n").when(x.has("z")) // n=n_x+z_x*n_y
            | (x & y & "e").when((x & y).has("s")) // e=e_x*e_y*s_x*s_y
            | (x & y & "dzm") // d=d_x*d_y, z=z_x*z_y, m=m_x*m_y
            | Self("f").when((x & y).has("f") || x.has("sf") || y.has("sf")) // f=f_x*f_y+f_x*s_x+f_y*s_y
            | ((x | y) & "s") // s=s_x+s_y
            | "ux"
            | ((x | y) & "ghij")
            | Self("k").when((x & y).has("k") && compatibleTimelocks(x, y))
    }

    static func orB(_ x: Self, _ y: Self) -> Self {
        Self("B").when(x.has("Bd") && y.has("Wd")) // B=B_x*d_x*W_y*d_y
            | ((x | y) & "o").when((x | y).has("z")) // o=o_x*z_y+z_x*o_y
            | (x & y & "m").when((x | y).has("s") && (x & y).has("e")) // m=m_x*m_y*e_x*e_y*(s_x+s_y)
            | (x & y & "zse") // z=z_x*z_y, s=s_x*s_y, e=e_x*e_y
            | "dux"
            | ((x | y) & "ghij")
            | (x & y & "k")
    }

    static func orD(_ x: Self, _ y: Self) -> Self {
        (y & "B").when(x.has("Bdu")) // B=B_y*B_x*d_x*u_x
            | (x & "o").when(y.has("z")) // o=o_x*z_y
            | (x & y & "m").when(x.has("e") && (x | y).has("s")) // m=m_x*m_y*e_x*(s_x+s_y)
            | (x & y & "zs") // z=z_x*z_y, s=s_x*s_y
            | (y & "ufde") // u=u_y, f=f_y, d=d_y, e=e_y
            | "x"
            | ((x | y) & "ghij")
            | (x & y & "k")
    }

    static func orC(_ x: Self, _ y: Self) -> Self {
        (y & "V").when(x.has("Bdu")) // V=V_y*B_x*u_x*d_x
            | (x & "o").when(y.has("z")) // o=o_x*z_y
            | (x & y & "m").when(x.has("e") && (x | y).has("s")) // m=m_x*m_y*e_x*(s_x+s_y)
            | (x & y & "zs") // z=z_x*z_y, s=s_x*s_y
            | "fx"
            | ((x | y) & "ghij")
            | (x & y & "k")
    }

    static func orI(_ x: Self, _ y: Self) -> Self {
        (x & y & "VBKufs") // V=V_x*V_y, B=B_x*B_y, K=K_x*K_y, u=u_x*u_y, f=f_x*f_y, s=s_x*s_y
            | Self("o").when((x & y).has("z")) // o=z_x*z_y
            | ((x | y) & "e").when((x | y).has("f")) // e=e_x*f_y+f_x*e_y
            | (x & y & "m").when((x | y).has("s")) // m=m_x*m_y*(s_x+s_y)
            | ((x | y) & "d") // d=d_x+d_y
            | "x"
            | ((x | y) & "ghij")
            | (x & y & "k")
    }

    static func andOr(_ x: Self, _ y: Self, _ z: Self) -> Self {
        (y & z & "BKV").when(x.has("Bdu")) // B=B_x*d_x*u_x*B_y*B_z, same for K and V
            | (x & y & z & "z") // z=z_x*z_y*z_z
            | ((x | (y & z)) & "o").when((x | (y & z)).has("z")) // o=o_x*z_y*z_z+z_x*o_y*o_z
            | (y & z & "u") // u=u_y*u_z
            | (z & "f").when(x.has("s") || y.has("f")) // f=(s_x+f_y)*f_z
            | (z & "d") // d=d_z
            | (z & "e").when(x.has("s") || y.has("f")) // e=e_z*(s_x+f_y)
            | (x & y & z & "m").when(x.has("e") && (x | y | z).has("s")) // m=m_x*m_y*m_z*e_x*(s_x+s_y+s_z)
            | (z & (x | y) & "s") // s=s_z*(s_x+s_y)
            | "x"
            | ((x | y | z) & "ghij")
            | Self("k").when((x & y & z).has("k") && compatibleTimelocks(x, y))
    }

    /// `thresh(k, X1, ..., Xn)`: `X1` is `Bdu`, the rest `Wdu`; the timelock
    /// classes accumulate across the children and a mix only matters when
    /// more than one child must be satisfied.
    static func thresh(subs: [Self], k: UInt32) -> Self {
        var allE = true
        var allM = true
        var args = 0
        var withSignature = 0
        var timelocks: Self = "k"
        for (index, sub) in subs.enumerated() {
            guard sub.has(index == 0 ? "Bdu" : "Wdu") else { return [] }
            if !sub.has("e") { allE = false }
            if !sub.has("m") { allM = false }
            if sub.has("s") { withSignature += 1 }
            args += sub.has("z") ? 0 : sub.has("o") ? 1 : 2
            let mixes = k > 1 && !compatibleTimelocks(timelocks, sub)
            timelocks = ((timelocks | sub) & "ghij") | Self("k").when((timelocks & sub).has("k") && !mixes)
        }
        let n = subs.count
        return "Bdu"
            | Self("z").when(args == 0) // z=all z
            | Self("o").when(args == 1) // o=all z except one o
            | Self("e").when(allE && withSignature == n) // e=all e and all s
            | Self("m").when(allE && allM && withSignature >= n - Int(k)) // m=all e, >=(n-k) s
            | Self("s").when(withSignature >= n - Int(k) + 1) // s= >=(n-k+1) s
            | timelocks
    }
}
