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

    // MARK: - Arithmetic
    //
    // The bodies are in Generated/GeneratedInteger256.swift, printed from
    // programs whose results Tools/Proofs proves exactly.

    func addingReportingOverflow(_ other: Integer256) -> (partialValue: Integer256, overflow: Bool) {
        let (sum, carry) = GeneratedInteger256.add(self, other)
        return (sum, carry != 0)
    }

    func subtractingReportingOverflow(_ other: Integer256) -> (partialValue: Integer256, overflow: Bool) {
        let (difference, borrow) = GeneratedInteger256.subtract(self, other)
        return (difference, borrow != 0)
    }

    /// The full 512-bit product.
    func multipliedFullWidth(by other: Integer256) -> (high: Integer256, low: Integer256) {
        GeneratedInteger256.multiply(self, other)
    }

    /// The 512-bit square.
    func squaredFullWidth() -> (high: Integer256, low: Integer256) {
        GeneratedInteger256.square(self)
    }

    /// The 320-bit product with a single limb.
    func multipliedFullWidth(by multiplier: UInt64) -> (high: UInt64, low: Integer256) {
        GeneratedInteger256.multiply(self, multiplier)
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
