import Foundation

/// A 256-bit unsigned integer in four little-endian 64-bit limbs; `l0` is the
/// least significant. Plain integer arithmetic with no modulus, used by the
/// field and scalar types. Variable-time.
struct Integer256: Equatable, Hashable, Sendable {
    var l0: UInt64
    var l1: UInt64
    var l2: UInt64
    var l3: UInt64

    static let zero = Integer256(l0: 0, l1: 0, l2: 0, l3: 0)
    static let one = Integer256(l0: 1, l1: 0, l2: 0, l3: 0)

    init(l0: UInt64, l1: UInt64, l2: UInt64, l3: UInt64) {
        self.l0 = l0
        self.l1 = l1
        self.l2 = l2
        self.l3 = l3
    }

    /// Exactly 32 big-endian bytes; nil for any other length. The slice may
    /// start at any index.
    init?(bigEndian data: Data) {
        guard data.count == 32 else { return nil }
        let bytes = Array(data)
        func limb(_ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0 ..< 8 { value = value << 8 | UInt64(bytes[offset + index]) }
            return value
        }
        self.init(l0: limb(24), l1: limb(16), l2: limb(8), l3: limb(0))
    }

    /// The 32-byte big-endian encoding.
    var bigEndian: Data {
        var out = Data(capacity: 32)
        for limb in [l3, l2, l1, l0] {
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift)))
            }
        }
        return out
    }

    var isZero: Bool { (l0 | l1 | l2 | l3) == 0 }
    var isOdd: Bool { l0 & 1 == 1 }

    /// Limb `index` in 0...3.
    func limb(_ index: Int) -> UInt64 {
        switch index {
        case 0: return l0
        case 1: return l1
        case 2: return l2
        default: return l3
        }
    }

    /// Bit `index`, where 0 is the least significant; false outside 0..<256.
    func bit(_ index: Int) -> Bool {
        guard index >= 0, index < 256 else { return false }
        return (limb(index >> 6) >> UInt64(index & 63)) & 1 == 1
    }

    /// `width` bits (1...64) starting at bit `index`, as an integer. Bits past
    /// the top are zero.
    func bits(from index: Int, count width: Int) -> UInt64 {
        let limbIndex = index >> 6
        let offset = index & 63
        var value = limb(limbIndex) >> UInt64(offset)
        if offset + width > 64, limbIndex < 3 {
            value |= limb(limbIndex + 1) << UInt64(64 - offset)
        }
        return width == 64 ? value : value & ((1 << UInt64(width)) - 1)
    }

    // MARK: - Addition and subtraction

    func addingReportingOverflow(_ other: Integer256) -> (partialValue: Integer256, overflow: Bool) {
        var carry: UInt64 = 0
        let r0 = Self.addLimb(l0, other.l0, &carry)
        let r1 = Self.addLimb(l1, other.l1, &carry)
        let r2 = Self.addLimb(l2, other.l2, &carry)
        let r3 = Self.addLimb(l3, other.l3, &carry)
        return (Integer256(l0: r0, l1: r1, l2: r2, l3: r3), carry != 0)
    }

    func subtractingReportingOverflow(_ other: Integer256) -> (partialValue: Integer256, overflow: Bool) {
        var borrow: UInt64 = 0
        let r0 = Self.subLimb(l0, other.l0, &borrow)
        let r1 = Self.subLimb(l1, other.l1, &borrow)
        let r2 = Self.subLimb(l2, other.l2, &borrow)
        let r3 = Self.subLimb(l3, other.l3, &borrow)
        return (Integer256(l0: r0, l1: r1, l2: r2, l3: r3), borrow != 0)
    }

    /// `a + b + carry`, leaving the carry out (0 or 1) in `carry`. The two
    /// additions cannot both overflow: if the first does, its result is at
    /// most 2^64 − 2, so adding one more cannot.
    @inline(__always)
    static func addLimb(_ a: UInt64, _ b: UInt64, _ carry: inout UInt64) -> UInt64 {
        let (sum, first) = a.addingReportingOverflow(b)
        let (total, second) = sum.addingReportingOverflow(carry)
        carry = (first ? 1 : 0) + (second ? 1 : 0)
        return total
    }

    /// `a − b − borrow`, leaving the borrow out (0 or 1) in `borrow`.
    @inline(__always)
    static func subLimb(_ a: UInt64, _ b: UInt64, _ borrow: inout UInt64) -> UInt64 {
        let (difference, first) = a.subtractingReportingOverflow(b)
        let (total, second) = difference.subtractingReportingOverflow(borrow)
        borrow = (first ? 1 : 0) + (second ? 1 : 0)
        return total
    }

    // MARK: - Multiplication

    /// The full 512-bit product, by product scanning: each output limb is the
    /// column sum of the partial products that land on it.
    func multipliedFullWidth(by other: Integer256) -> (high: Integer256, low: Integer256) {
        var column = Column()
        column.add(l0, other.l0)
        let r0 = column.shift()
        column.add(l0, other.l1); column.add(l1, other.l0)
        let r1 = column.shift()
        column.add(l0, other.l2); column.add(l1, other.l1); column.add(l2, other.l0)
        let r2 = column.shift()
        column.add(l0, other.l3); column.add(l1, other.l2); column.add(l2, other.l1); column.add(l3, other.l0)
        let r3 = column.shift()
        column.add(l1, other.l3); column.add(l2, other.l2); column.add(l3, other.l1)
        let r4 = column.shift()
        column.add(l2, other.l3); column.add(l3, other.l2)
        let r5 = column.shift()
        column.add(l3, other.l3)
        let r6 = column.shift()
        let r7 = column.shift()
        return (Integer256(l0: r4, l1: r5, l2: r6, l3: r7), Integer256(l0: r0, l1: r1, l2: r2, l3: r3))
    }

    /// The 512-bit square: the cross products appear twice, so each is
    /// computed once and accumulated twice (ten multiplications, not sixteen).
    func squaredFullWidth() -> (high: Integer256, low: Integer256) {
        var column = Column()
        column.add(l0, l0)
        let r0 = column.shift()
        column.addDoubled(l0, l1)
        let r1 = column.shift()
        column.addDoubled(l0, l2); column.add(l1, l1)
        let r2 = column.shift()
        column.addDoubled(l0, l3); column.addDoubled(l1, l2)
        let r3 = column.shift()
        column.addDoubled(l1, l3); column.add(l2, l2)
        let r4 = column.shift()
        column.addDoubled(l2, l3)
        let r5 = column.shift()
        column.add(l3, l3)
        let r6 = column.shift()
        let r7 = column.shift()
        return (Integer256(l0: r4, l1: r5, l2: r6, l3: r7), Integer256(l0: r0, l1: r1, l2: r2, l3: r3))
    }

    /// The 320-bit product with a single limb.
    func multipliedFullWidth(by multiplier: UInt64) -> (high: UInt64, low: Integer256) {
        var carry: UInt64 = 0
        let r0 = Self.mulAdd(l0, multiplier, &carry)
        let r1 = Self.mulAdd(l1, multiplier, &carry)
        let r2 = Self.mulAdd(l2, multiplier, &carry)
        let r3 = Self.mulAdd(l3, multiplier, &carry)
        return (carry, Integer256(l0: r0, l1: r1, l2: r2, l3: r3))
    }

    /// `a × m + carry` as a limb, with the overflow left in `carry`. The high
    /// half of a 64×64 product is at most 2^64 − 2, so adding the carry bit
    /// cannot overflow.
    @inline(__always)
    private static func mulAdd(_ a: UInt64, _ m: UInt64, _ carry: inout UInt64) -> UInt64 {
        let (high, low) = a.multipliedFullWidth(by: m)
        let (sum, overflow) = low.addingReportingOverflow(carry)
        carry = high &+ (overflow ? 1 : 0)
        return sum
    }

    /// A three-limb accumulator for one output column of a product scan. At
    /// most four 128-bit partial products plus the carried-in limbs land on a
    /// column, so the top limb never exceeds a few bits.
    private struct Column {
        var c0: UInt64 = 0
        var c1: UInt64 = 0
        var c2: UInt64 = 0

        @inline(__always)
        mutating func add(_ a: UInt64, _ b: UInt64) {
            let (high, low) = a.multipliedFullWidth(by: b)
            accumulate(high: high, low: low)
        }

        /// Adds 2·a·b: the product once, accumulated twice.
        @inline(__always)
        mutating func addDoubled(_ a: UInt64, _ b: UInt64) {
            let (high, low) = a.multipliedFullWidth(by: b)
            accumulate(high: high, low: low)
            accumulate(high: high, low: low)
        }

        @inline(__always)
        private mutating func accumulate(high: UInt64, low: UInt64) {
            let (s0, o0) = c0.addingReportingOverflow(low)
            let (s1, o1) = c1.addingReportingOverflow(high)
            let (s1b, o1b) = s1.addingReportingOverflow(o0 ? 1 : 0)
            c0 = s0
            c1 = s1b
            c2 = c2 &+ (o1 ? 1 : 0) &+ (o1b ? 1 : 0)
        }

        /// Emits the finished column and moves the carries down one place.
        @inline(__always)
        mutating func shift() -> UInt64 {
            let result = c0
            c0 = c1
            c1 = c2
            c2 = 0
            return result
        }
    }
}

extension Integer256: Comparable {
    static func < (lhs: Integer256, rhs: Integer256) -> Bool {
        if lhs.l3 != rhs.l3 { return lhs.l3 < rhs.l3 }
        if lhs.l2 != rhs.l2 { return lhs.l2 < rhs.l2 }
        if lhs.l1 != rhs.l1 { return lhs.l1 < rhs.l1 }
        return lhs.l0 < rhs.l0
    }
}
