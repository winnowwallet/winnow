@testable import NativeSecp256k1

/// The arithmetic NativeSecp256k1 used before Tools/Proofs generated it
/// (Integer256.swift, FieldElement.swift, Scalar.swift and Point.swift at
/// 47c788d), kept apart from renaming so `NativeSecp256k1GeneratedTests` can
/// compare the two. The limb arithmetic uses nothing generated, only
/// Integer256's limbs and comparison; the point formulas and the
/// square-and-multiply exponentiation are written over FieldElement, so they
/// check the generated formulas and chains, not the field.
enum HandWritten {
    // MARK: - Integer256

    static func add(_ a: Integer256, _ b: Integer256) -> (partialValue: Integer256, overflow: Bool) {
        var carry: UInt64 = 0
        let r0 = addLimb(a.l0, b.l0, &carry)
        let r1 = addLimb(a.l1, b.l1, &carry)
        let r2 = addLimb(a.l2, b.l2, &carry)
        let r3 = addLimb(a.l3, b.l3, &carry)
        return (Integer256(l0: r0, l1: r1, l2: r2, l3: r3), carry != 0)
    }

    static func subtract(_ a: Integer256, _ b: Integer256) -> (partialValue: Integer256, overflow: Bool) {
        var borrow: UInt64 = 0
        let r0 = subLimb(a.l0, b.l0, &borrow)
        let r1 = subLimb(a.l1, b.l1, &borrow)
        let r2 = subLimb(a.l2, b.l2, &borrow)
        let r3 = subLimb(a.l3, b.l3, &borrow)
        return (Integer256(l0: r0, l1: r1, l2: r2, l3: r3), borrow != 0)
    }

    static func addLimb(_ a: UInt64, _ b: UInt64, _ carry: inout UInt64) -> UInt64 {
        let (sum, first) = a.addingReportingOverflow(b)
        let (total, second) = sum.addingReportingOverflow(carry)
        carry = (first ? 1 : 0) + (second ? 1 : 0)
        return total
    }

    static func subLimb(_ a: UInt64, _ b: UInt64, _ borrow: inout UInt64) -> UInt64 {
        let (difference, first) = a.subtractingReportingOverflow(b)
        let (total, second) = difference.subtractingReportingOverflow(borrow)
        borrow = (first ? 1 : 0) + (second ? 1 : 0)
        return total
    }

    static func multiply(_ a: Integer256, _ b: Integer256) -> (high: Integer256, low: Integer256) {
        var column = Column()
        column.add(a.l0, b.l0)
        let r0 = column.shift()
        column.add(a.l0, b.l1); column.add(a.l1, b.l0)
        let r1 = column.shift()
        column.add(a.l0, b.l2); column.add(a.l1, b.l1); column.add(a.l2, b.l0)
        let r2 = column.shift()
        column.add(a.l0, b.l3); column.add(a.l1, b.l2); column.add(a.l2, b.l1); column.add(a.l3, b.l0)
        let r3 = column.shift()
        column.add(a.l1, b.l3); column.add(a.l2, b.l2); column.add(a.l3, b.l1)
        let r4 = column.shift()
        column.add(a.l2, b.l3); column.add(a.l3, b.l2)
        let r5 = column.shift()
        column.add(a.l3, b.l3)
        let r6 = column.shift()
        let r7 = column.shift()
        return (Integer256(l0: r4, l1: r5, l2: r6, l3: r7), Integer256(l0: r0, l1: r1, l2: r2, l3: r3))
    }

    static func square(_ a: Integer256) -> (high: Integer256, low: Integer256) {
        var column = Column()
        column.add(a.l0, a.l0)
        let r0 = column.shift()
        column.addDoubled(a.l0, a.l1)
        let r1 = column.shift()
        column.addDoubled(a.l0, a.l2); column.add(a.l1, a.l1)
        let r2 = column.shift()
        column.addDoubled(a.l0, a.l3); column.addDoubled(a.l1, a.l2)
        let r3 = column.shift()
        column.addDoubled(a.l1, a.l3); column.add(a.l2, a.l2)
        let r4 = column.shift()
        column.addDoubled(a.l2, a.l3)
        let r5 = column.shift()
        column.add(a.l3, a.l3)
        let r6 = column.shift()
        let r7 = column.shift()
        return (Integer256(l0: r4, l1: r5, l2: r6, l3: r7), Integer256(l0: r0, l1: r1, l2: r2, l3: r3))
    }

    static func multiply(_ a: Integer256, by multiplier: UInt64) -> (high: UInt64, low: Integer256) {
        var carry: UInt64 = 0
        let r0 = mulAdd(a.l0, multiplier, &carry)
        let r1 = mulAdd(a.l1, multiplier, &carry)
        let r2 = mulAdd(a.l2, multiplier, &carry)
        let r3 = mulAdd(a.l3, multiplier, &carry)
        return (carry, Integer256(l0: r0, l1: r1, l2: r2, l3: r3))
    }

    private static func mulAdd(_ a: UInt64, _ m: UInt64, _ carry: inout UInt64) -> UInt64 {
        let (high, low) = a.multipliedFullWidth(by: m)
        let (sum, overflow) = low.addingReportingOverflow(carry)
        carry = high &+ (overflow ? 1 : 0)
        return sum
    }

    private struct Column {
        var c0: UInt64 = 0
        var c1: UInt64 = 0
        var c2: UInt64 = 0

        mutating func add(_ a: UInt64, _ b: UInt64) {
            let (high, low) = a.multipliedFullWidth(by: b)
            accumulate(high: high, low: low)
        }

        mutating func addDoubled(_ a: UInt64, _ b: UInt64) {
            let (high, low) = a.multipliedFullWidth(by: b)
            accumulate(high: high, low: low)
            accumulate(high: high, low: low)
        }

        private mutating func accumulate(high: UInt64, low: UInt64) {
            let (s0, o0) = c0.addingReportingOverflow(low)
            let (s1, o1) = c1.addingReportingOverflow(high)
            let (s1b, o1b) = s1.addingReportingOverflow(o0 ? 1 : 0)
            c0 = s0
            c1 = s1b
            c2 = c2 &+ (o1 ? 1 : 0) &+ (o1b ? 1 : 0)
        }

        mutating func shift() -> UInt64 {
            let result = c0
            c0 = c1
            c1 = c2
            c2 = 0
            return result
        }
    }

    // MARK: - Field: values below p

    static let p = Integer256(l0: 0xFFFF_FFFE_FFFF_FC2F, l1: .max, l2: .max, l3: .max)
    static let fold: UInt64 = 0x1_0000_03D1
    static let foldValue = Integer256(l0: fold, l1: 0, l2: 0, l3: 0)

    static func fieldReducing(_ integer: Integer256) -> Integer256 {
        integer < p ? integer : subtract(integer, p).partialValue
    }

    static func fieldAdd(_ a: Integer256, _ b: Integer256) -> Integer256 {
        let (sum, carry) = add(a, b)
        guard carry else { return fieldReducing(sum) }
        return add(sum, foldValue).partialValue
    }

    static func fieldSubtract(_ a: Integer256, _ b: Integer256) -> Integer256 {
        let (difference, borrow) = subtract(a, b)
        guard borrow else { return difference }
        return subtract(difference, foldValue).partialValue
    }

    static func fieldMultiply(_ a: Integer256, _ b: Integer256) -> Integer256 {
        let (high, low) = multiply(a, b)
        return fieldReduce(high: high, low: low)
    }

    static func fieldSquare(_ a: Integer256) -> Integer256 {
        let (high, low) = square(a)
        return fieldReduce(high: high, low: low)
    }

    static func fieldNegate(_ a: Integer256) -> Integer256 {
        a.isZero ? a : subtract(p, a).partialValue
    }

    static func fieldReduce(high: Integer256, low: Integer256) -> Integer256 {
        let (highFold, lowFold) = multiply(high, by: fold)
        let (total, overflow) = add(low, lowFold)
        let extra = highFold &+ (overflow ? 1 : 0)

        let (extraHigh, extraLow) = extra.multipliedFullWidth(by: fold)
        var carry: UInt64 = 0
        let r0 = addLimb(total.l0, extraLow, &carry)
        let r1 = addLimb(total.l1, extraHigh, &carry)
        let r2 = addLimb(total.l2, 0, &carry)
        let r3 = addLimb(total.l3, 0, &carry)
        var result = Integer256(l0: r0, l1: r1, l2: r2, l3: r3)
        if carry != 0 {
            result = add(result, foldValue).partialValue
        }
        return fieldReducing(result)
    }

    // MARK: - Scalar: values below n

    static let n = Integer256(l0: 0xBFD2_5E8C_D036_4141, l1: 0xBAAE_DCE6_AF48_A03B,
                              l2: 0xFFFF_FFFF_FFFF_FFFE, l3: .max)

    static func scalarReducing(_ integer: Integer256) -> Integer256 {
        integer < n ? integer : subtract(integer, n).partialValue
    }

    static func scalarAdd(_ a: Integer256, _ b: Integer256) -> Integer256 {
        let (sum, carry) = add(a, b)
        guard carry || sum >= n else { return sum }
        return subtract(sum, n).partialValue
    }

    static func scalarNegate(_ a: Integer256) -> Integer256 {
        a.isZero ? a : subtract(n, a).partialValue
    }

    static func scalarSubtract(_ a: Integer256, _ b: Integer256) -> Integer256 {
        scalarAdd(a, scalarNegate(b))
    }

    /// The binary method the module used: 256 doublings and up to 256 additions.
    static func scalarMultiply(_ a: Integer256, _ b: Integer256) -> Integer256 {
        var accumulator = Integer256.zero
        for index in stride(from: 255, through: 0, by: -1) {
            accumulator = scalarAdd(accumulator, accumulator)
            if b.bit(index) { accumulator = scalarAdd(accumulator, a) }
        }
        return accumulator
    }

    // MARK: - Points and exponentiation, over FieldElement

    /// dbl-2009-l as JacobianPoint.doubled() wrote it.
    static func double(_ x: FieldElement, _ y: FieldElement, _ z: FieldElement)
        -> (FieldElement, FieldElement, FieldElement) {
        let a = x.squared()
        let b = y.squared()
        let c = b.squared()
        let xPlusB = (x + b).squared()
        let d = twice(xPlusB - a - c)
        let e = a + a + a
        let f = e.squared()
        let x3 = f - twice(d)
        let y3 = e * (d - x3) - twice(twice(twice(c)))
        let z3 = twice(y * z)
        return (x3, y3, z3)
    }

    /// madd-2007-bl as JacobianPoint.adding(_:) wrote it, with H and r.
    static func addMixed(_ x: FieldElement, _ y: FieldElement, _ z: FieldElement,
                         _ qx: FieldElement, _ qy: FieldElement)
        -> (FieldElement, FieldElement, FieldElement, FieldElement, FieldElement) {
        let z1z1 = z.squared()
        let u2 = qx * z1z1
        let s2 = qy * z * z1z1
        let h = u2 - x
        let r = twice(s2 - y)
        let hh = h.squared()
        let i = twice(twice(hh))
        let j = h * i
        let v = x * i
        let x3 = r.squared() - j - twice(v)
        let y3 = r * (v - x3) - twice(y * j)
        let z3 = (z + h).squared() - z1z1 - hh
        return (x3, y3, z3, h, r)
    }

    private static func twice(_ a: FieldElement) -> FieldElement { a + a }

    /// a^(p−2) by square-and-multiply, as FieldElement.inverse() computed it.
    static func inverse(_ a: FieldElement) -> FieldElement {
        a.pow(Integer256(l0: 0xFFFF_FFFE_FFFF_FC2D, l1: .max, l2: .max, l3: .max))
    }

    /// a^((p+1)/4) by square-and-multiply, as FieldElement.squareRoot() did.
    static func squareRootCandidate(_ a: FieldElement) -> FieldElement {
        a.pow(Integer256(l0: 0xFFFF_FFFF_BFFF_FF0C, l1: .max, l2: .max, l3: 0x3FFF_FFFF_FFFF_FFFF))
    }
}
