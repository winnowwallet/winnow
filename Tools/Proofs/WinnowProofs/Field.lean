import WinnowProofs.Integer

/-!
# Field programs: arithmetic modulo p = 2^256 − 2^32 − 977

`FieldElement` in `Sources/NativeSecp256k1`. Every result is canonical, in
[0, p). Reduction uses 2^256 ≡ R (mod p) with R = 2^32 + 977 = 2^256 − p:
a word that spills past 2^256 is multiplied by R and added back.
`FieldSpec.lean` proves what each program computes.
-/

namespace Winnow

namespace Field

/-- 2^256 − p. -/
def R : Nat := 0x1000003D1

/-- The field prime. -/
def P : Nat := 2 ^ 256 - R

/-- p's low limb; its other three limbs are all ones. -/
def P0 : Nat := 0xFFFFFFFEFFFFFC2F

def allOnes : Nat := 0xFFFFFFFFFFFFFFFF

section Programs

variable {m : Type → Type} [Monad m] {W : Type} [Lit W] [Machine m W]

/-- Four 0/1-flag selects: `x` when the flag is 1, `y` when it is 0. -/
def select256 (f : W) (x y : U256 W) : m (U256 W) := do
  let r0 ← select f x.l0 y.l0
  let r1 ← select f x.l1 y.l1
  let r2 ← select f x.l2 y.l2
  let r3 ← select f x.l3 y.l3
  pure ⟨r0, r1, r2, r3⟩

/-- x·R as (high, low). -/
def mulR (x : W) : m (W × W) := mul x (lit R)

/-- Step 1 of reduction: lo + R·hi, as four limbs and a top word. -/
def foldHigh (hi lo : U256 W) : m (U256 W × W) := do
  let m0 ← mulR hi.l0
  let m1 ← mulR hi.l1
  let m2 ← mulR hi.l2
  let m3 ← mulR hi.l3
  let u ← add256 lo ⟨m0.2, m1.2, m2.2, m3.2⟩
  let v ← add256 u.1 ⟨lit 0, m0.1, m1.1, m2.1⟩
  let t ← addExact m3.1 u.2
  let t ← addExact t v.2
  pure (v.1, t)

/-- Step 2: t + R·top, as four limbs and a carry out. -/
def foldTop (t : U256 W) (top : W) : m (U256 W × W) := do
  let e ← mulR top
  add256 t ⟨e.2, e.1, lit 0, lit 0⟩

/-- Step 3: v + R·c for a carry c of 0 or 1. -/
def foldCarry (v : U256 W) (c : W) : m (U256 W) := do
  let f ← select c (lit R) (lit 0)
  let w ← add256 v ⟨f, lit 0, lit 0, lit 0⟩
  pure w.1

/-- Any 256-bit value modulo p: w + R carries out exactly when w ≥ p, and
then its low 256 bits are w − p. -/
def canonical (w : U256 W) : m (U256 W) := do
  let y ← add256 w ⟨lit R, lit 0, lit 0, lit 0⟩
  select256 y.2 y.1 w

/-- A 512-bit value `2^256·hi + lo` modulo p. -/
def reduce (hi lo : U256 W) : m (U256 W) := do
  let t ← foldHigh hi lo
  let v ← foldTop t.1 t.2
  let w ← foldCarry v.1 v.2
  canonical w

/-- a·b mod p. -/
def mulMod (a b : U256 W) : m (U256 W) := do
  let p ← mul256 a b
  reduce p.1 p.2

/-- a² mod p. -/
def sqrMod (a : U256 W) : m (U256 W) := do
  let p ← sqr256 a
  reduce p.1 p.2

/-- a + b mod p for a, b < p: subtract p (add R) when the sum carried or
reached p. -/
def addMod (a b : U256 W) : m (U256 W) := do
  let s ← add256 a b
  let y ← add256 s.1 ⟨lit R, lit 0, lit 0, lit 0⟩
  let f ← or s.2 y.2
  select256 f y.1 s.1

/-- a − b mod p for a, b < p: add p back when the difference borrowed. -/
def subMod (a b : U256 W) : m (U256 W) := do
  let d ← sub256 a b
  let q0 ← select d.2 (lit P0) (lit 0)
  let q1 ← select d.2 (lit allOnes) (lit 0)
  let r ← add256 d.1 ⟨q0, q1, q1, q1⟩
  pure r.1

/-- −a mod p for a < p. -/
def negMod (a : U256 W) : m (U256 W) :=
  subMod ⟨lit 0, lit 0, lit 0, lit 0⟩ a

end Programs

end Field

end Winnow
