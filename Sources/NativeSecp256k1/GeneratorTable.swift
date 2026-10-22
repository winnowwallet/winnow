import Foundation

/// Fixed-base precomputation for k·G. For each of the 64 four-bit windows w
/// of a scalar, the table holds the affine points j·2^(4w)·G for j in 1...15,
/// so multiplying the generator costs at most 64 mixed additions instead of
/// 256 doublings and up to 256 additions. The table is built once on first
/// use, in about a millisecond, and occupies 960 points (61 KB).
///
/// Variable-time: window values index the table and zero windows are skipped.
enum GeneratorTable {
    static let windowBits = 4
    static let windows = 64
    static let entriesPerWindow = 15

    /// Entry `window * entriesPerWindow + (digit − 1)` is digit·2^(4·window)·G.
    static let points: [AffinePoint] = build()

    /// k·G for 0 ≤ k < n; infinity for k = 0.
    static func multiply(_ scalar: Scalar) -> JacobianPoint {
        var accumulator = JacobianPoint.infinity
        for window in 0 ..< windows {
            let digit = Int(scalar.value.bits(from: window * windowBits, count: windowBits))
            if digit != 0 {
                accumulator = accumulator.adding(points[window * entriesPerWindow + digit - 1])
            }
        }
        return accumulator
    }

    private static func build() -> [AffinePoint] {
        // The window bases 2^(4w)·G, then every multiple of each base. All of
        // them are finite: the largest, 15·2^252·G, has a scalar below n.
        var bases: [JacobianPoint] = []
        bases.reserveCapacity(windows)
        var base = JacobianPoint(Curve.generator)
        for _ in 0 ..< windows {
            bases.append(base)
            for _ in 0 ..< windowBits { base = base.doubled() }
        }
        var multiples: [JacobianPoint] = []
        multiples.reserveCapacity(windows * entriesPerWindow)
        for affineBase in batchAffine(bases) {
            var accumulator = JacobianPoint(affineBase)
            multiples.append(accumulator)
            for _ in 2 ... entriesPerWindow {
                accumulator = accumulator.adding(affineBase)
                multiples.append(accumulator)
            }
        }
        return batchAffine(multiples)
    }

    /// Converts finite Jacobian points to affine with a single field
    /// inversion (Montgomery's trick): prefix products of the Z coordinates,
    /// one inversion, then peel the individual inverses off from the end.
    static func batchAffine(_ points: [JacobianPoint]) -> [AffinePoint] {
        var prefix: [FieldElement] = []
        prefix.reserveCapacity(points.count)
        var running = FieldElement.one
        for point in points {
            running = running * point.z
            prefix.append(running)
        }
        var inverse = running.inverse()
        var reversed: [AffinePoint] = []
        reversed.reserveCapacity(points.count)
        for index in stride(from: points.count - 1, through: 0, by: -1) {
            let zInverse = index == 0 ? inverse : inverse * prefix[index - 1]
            inverse = inverse * points[index].z
            let zInverse2 = zInverse.squared()
            reversed.append(AffinePoint(x: points[index].x * zInverse2,
                                        y: points[index].y * zInverse2 * zInverse))
        }
        return reversed.reversed()
    }
}
