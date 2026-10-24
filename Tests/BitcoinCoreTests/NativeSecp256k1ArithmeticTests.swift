import Foundation
import NativeSecp256k1
import Testing
import TestSupport
import WalletCore

/// The public group arithmetic MuSig2 is built on: scalars modulo n that may
/// be zero, point sums that may be infinity, and points times scalars. The
/// group laws are the oracle here; the BIP327 vectors in MuSig2Tests check
/// the same operations against the specification's answers.
@Suite("Native secp256k1 arithmetic")
struct NativeSecp256k1ArithmeticTests {
    static let order = Data(hex: "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")!

    static func scalar(_ rng: inout SeededRandom) throws -> Secp256k1.ScalarModN {
        try Secp256k1.ScalarModN(reducing: Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }))
    }

    @Test("scalars accept zero and values below n, and refuse n and wrong lengths")
    func scalarParsing() throws {
        #expect(try Secp256k1.ScalarModN(Data(count: 32)).isZero)
        #expect(try Secp256k1.ScalarModN(Data(count: 31) + Data([1])) == .one)
        #expect(throws: Secp256k1Error.invalidScalar) { try Secp256k1.ScalarModN(Self.order) }
        #expect(throws: Secp256k1Error.invalidScalar) { try Secp256k1.ScalarModN(Data(count: 31)) }
        #expect(throws: Secp256k1Error.invalidScalar) { try Secp256k1.ScalarModN(reducing: Data(count: 33)) }
        // Reducing n gives zero; reducing n + 1 gives one.
        #expect(try Secp256k1.ScalarModN(reducing: Self.order).isZero)
        var nPlusOne = Self.order
        nPlusOne[nPlusOne.index(before: nPlusOne.endIndex)] &+= 1
        #expect(try Secp256k1.ScalarModN(reducing: nPlusOne) == .one)
    }

    @Test("scalar addition, negation and multiplication obey the field laws")
    func scalarLaws() throws {
        var rng = SeededRandom(state: 0xA51_7E5)
        #expect(Secp256k1.ScalarModN.zero.negated == .zero)
        for _ in 0 ..< 32 {
            let a = try Self.scalar(&rng), b = try Self.scalar(&rng), c = try Self.scalar(&rng)
            #expect((a + a.negated).isZero)
            #expect(a + b == b + a)
            #expect(a * b == b * a)
            #expect(a * (b + c) == a * b + a * c)
            #expect(a * .one == a)
            #expect((a * .zero).isZero)
            #expect(try Secp256k1.ScalarModN(a.bytes) == a)
        }
    }

    @Test("point sums, negation and scalar multiples agree with generator multiples")
    func pointLaws() throws {
        var rng = SeededRandom(state: 0x9017_75)
        #expect(Secp256k1.PublicKey.generatorMultiple(.zero) == nil)
        #expect(Secp256k1.PublicKey.sum([]) == nil)
        for _ in 0 ..< 16 {
            let a = try Self.scalar(&rng), b = try Self.scalar(&rng), k = try Self.scalar(&rng)
            let p = try #require(Secp256k1.PublicKey.generatorMultiple(a))
            let q = try #require(Secp256k1.PublicKey.generatorMultiple(b))
            // (a + b)·G = a·G + b·G, and P + (−P) is infinity.
            #expect(p.adding(q) == Secp256k1.PublicKey.generatorMultiple(a + b))
            #expect(p.adding(p.negated) == nil)
            #expect(Secp256k1.PublicKey.sum([p, q, p.negated]) == q)
            // P + P doubles, and k·(a·G) = (k·a)·G.
            #expect(p.adding(p) == p.multiplied(by: .one + .one))
            #expect(p.multiplied(by: k) == Secp256k1.PublicKey.generatorMultiple(k * a))
            #expect(p.multiplied(by: .zero) == nil)
            // k·(P + Q) = k·P + k·Q.
            let sum = try #require(p.adding(q))
            let kp = try #require(p.multiplied(by: k)), kq = try #require(q.multiplied(by: k))
            #expect(sum.multiplied(by: k) == kp.adding(kq))
            // The negation of a point is its compressed twin with the other prefix.
            #expect(p.negated.compressed.dropFirst() == p.compressed.dropFirst())
            #expect(p.negated.compressed.first != p.compressed.first)
        }
    }
}
