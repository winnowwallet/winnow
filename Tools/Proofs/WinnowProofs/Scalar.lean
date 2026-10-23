import WinnowProofs.Field

/-!
# Scalar programs: arithmetic modulo the group order n

`Scalar` in `Sources/NativeSecp256k1`. Every result is canonical, in [0, n).
Reduction uses 2^256 ≡ C (mod n) with C = 2^256 − n, a 129-bit constant
whose limbs are C0, C1 and 1. `ScalarSpec.lean` proves what each program
computes.
-/

namespace Winnow

namespace Scalar

/-- The group order. -/
def N : Nat := 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

/-- 2^256 − n. -/
def C : Nat := 2 ^ 256 - N

def C0 : Nat := 0x402DA1732FC9BEBF
def C1 : Nat := 0x4551231950B75FC4

/-- n's limbs. -/
def N0 : Nat := 0xBFD25E8CD0364141
def N1 : Nat := 0xBAAEDCE6AF48A03B
def N2 : Nat := 0xFFFFFFFFFFFFFFFE
def N3 : Nat := 0xFFFFFFFFFFFFFFFF

section Programs

variable {m : Type → Type} [Monad m] {W : Type} [Lit W] [Machine m W]

/-- C as four limbs. -/
def cLimbs : U256 W := ⟨lit C0, lit C1, lit 1, lit 0⟩

/-- Stage 1 of reduction: lo + C·hi (below 2^386), as four limbs and three
high words. -/
def foldHigh (hi lo : U256 W) : m (U256 W × W × W × W) := do
  let c ← (Column.ofWord lo.l0).mulAdd hi.l0 (lit C0)
  let r0 := c.c0
  let c ← c.shift.mulAdd hi.l0 (lit C1)
  let c ← c.mulAdd hi.l1 (lit C0)
  let c ← c.accumulate (lit 0, lo.l1)
  let r1 := c.c0
  let c ← c.shift.mulAdd hi.l1 (lit C1)
  let c ← c.mulAdd hi.l2 (lit C0)
  let c ← c.accumulate (lit 0, lo.l2)
  let c ← c.accumulate (lit 0, hi.l0)
  let r2 := c.c0
  let c ← c.shift.mulAdd hi.l2 (lit C1)
  let c ← c.mulAdd hi.l3 (lit C0)
  let c ← c.accumulate (lit 0, lo.l3)
  let c ← c.accumulate (lit 0, hi.l1)
  let r3 := c.c0
  let c ← c.shift.mulAdd hi.l3 (lit C1)
  let c ← c.accumulate (lit 0, hi.l2)
  let r4 := c.c0
  let c ← c.shift.accumulate (lit 0, hi.l3)
  pure (⟨r0, r1, r2, r3⟩, r4, c.c0, c.c1)

/-- Stage 2: mlo + C·(m4 + 2^64·m5 + 2^128·m6) with m6 ≤ 1, as four limbs
and a top word. -/
def foldMid (mlo : U256 W) (m4 m5 m6 : W) : m (U256 W × W) := do
  let c ← (Column.ofWord mlo.l0).mulAdd m4 (lit C0)
  let r0 := c.c0
  let c ← c.shift.mulAdd m4 (lit C1)
  let c ← c.mulAdd m5 (lit C0)
  let c ← c.accumulate (lit 0, mlo.l1)
  let r1 := c.c0
  let c ← c.shift.mulAdd m5 (lit C1)
  let c ← c.mulAdd m6 (lit C0)
  let c ← c.accumulate (lit 0, mlo.l2)
  let c ← c.accumulate (lit 0, m4)
  let r2 := c.c0
  let c ← c.shift.mulAdd m6 (lit C1)
  let c ← c.accumulate (lit 0, mlo.l3)
  let c ← c.accumulate (lit 0, m5)
  let r3 := c.c0
  let c ← c.shift.accumulate (lit 0, m6)
  pure (⟨r0, r1, r2, r3⟩, c.c0)

/-- Stage 3: p + C·top for a small top word, as four limbs and a carry. -/
def foldLow (p : U256 W) (top : W) : m (U256 W × W) := do
  let e0 ← mulLit top C0
  let e1 ← mulLit top C1
  let s1 ← adds e0.1 e1.2
  let s2 ← addExact e1.1 top
  let s2 ← addExact s2 s1.2
  add256 p ⟨e0.2, s1.1, s2, lit 0⟩

/-- q + 2^256·c modulo n, for a value below 2n: subtract n (add C) when
the value carried or reached n. -/
def reduceCarry (q : U256 W) (c : W) : m (U256 W) := do
  let y ← add256 q cLimbs
  let f ← or c y.2
  Field.select256 f y.1 q

/-- A 512-bit value `2^256·hi + lo` modulo n. -/
def reduce (hi lo : U256 W) : m (U256 W) := do
  let a ← foldHigh hi lo
  let b ← foldMid a.1 a.2.1 a.2.2.1 a.2.2.2
  let c ← foldLow b.1 b.2
  reduceCarry c.1 c.2

/-- Any 256-bit value modulo n: w + C carries out exactly when w ≥ n. -/
def canonical (w : U256 W) : m (U256 W) := do
  let y ← add256 w cLimbs
  Field.select256 y.2 y.1 w

/-- a·b mod n. -/
def mulMod (a b : U256 W) : m (U256 W) := do
  let p ← mul256 a b
  reduce p.1 p.2

/-- a + b mod n for a, b < n. -/
def addMod (a b : U256 W) : m (U256 W) := do
  let s ← add256 a b
  reduceCarry s.1 s.2

/-- a − b mod n for a, b < n: add n back when the difference borrowed. -/
def subMod (a b : U256 W) : m (U256 W) := do
  let d ← sub256 a b
  let q0 ← select d.2 (lit N0) (lit 0)
  let q1 ← select d.2 (lit N1) (lit 0)
  let q2 ← select d.2 (lit N2) (lit 0)
  let q3 ← select d.2 (lit N3) (lit 0)
  let r ← add256 d.1 ⟨q0, q1, q2, q3⟩
  pure r.1

/-- −a mod n for a < n. -/
def negMod (a : U256 W) : m (U256 W) :=
  subMod ⟨lit 0, lit 0, lit 0, lit 0⟩ a

end Programs

end Scalar

end Winnow
