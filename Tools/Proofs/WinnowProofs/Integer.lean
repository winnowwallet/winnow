import WinnowProofs.Machine

/-!
# 256-bit integer programs

`Integer256` in `Sources/NativeSecp256k1`: addition and subtraction with the
carry or borrow out, and the full 512-bit product and square by product
scanning. `IntegerSpec.lean` proves what each computes.
-/

namespace Winnow

section Programs

variable {m : Type → Type} [Monad m] {W : Type} [Lit W] [Machine m W]

/-- a + b and the carry out. -/
def add256 (a b : U256 W) : m (U256 W × W) := do
  let r0 ← adds a.l0 b.l0
  let r1 ← addc a.l1 b.l1 r0.2
  let r2 ← addc a.l2 b.l2 r1.2
  let r3 ← addc a.l3 b.l3 r2.2
  pure (⟨r0.1, r1.1, r2.1, r3.1⟩, r3.2)

/-- a − b and the borrow out. -/
def sub256 (a b : U256 W) : m (U256 W × W) := do
  let r0 ← subs a.l0 b.l0
  let r1 ← subb a.l1 b.l1 r0.2
  let r2 ← subb a.l2 b.l2 r1.2
  let r3 ← subb a.l3 b.l3 r2.2
  pure (⟨r0.1, r1.1, r2.1, r3.1⟩, r3.2)

/-- `a &+ b` where the sum is known not to wrap; the lemma takes that as a
hypothesis, so each use carries its own bound argument. -/
def addExact (a b : W) : m W := add a b

/-- x·k for a constant k, as (high, low). -/
def mulLit (x : W) (k : Nat) : m (W × W) := mul x (lit k)

/-- A column holding one word. -/
def Column.ofWord (x : W) : Column W := ⟨x, lit 0, lit 0⟩

/-- A column holding one product. -/
def Column.start (p : W × W) : Column W := ⟨p.2, p.1, lit 0⟩

/-- The column after its low word is emitted: the carries move down. -/
def Column.shift (c : Column W) : Column W := ⟨c.c1, c.c2, lit 0⟩

/-- Adds a 128-bit (high, low) pair to a column. The top word takes the
carry with a wrapping add: the theorems below show it never wraps. -/
def Column.accumulate (c : Column W) (p : W × W) : m (Column W) := do
  let s0 ← adds c.c0 p.2
  let s1 ← addc c.c1 p.1 s0.2
  let s2 ← add c.c2 s1.2
  pure ⟨s0.1, s1.1, s2⟩

/-- Adds x·y to a column. -/
def Column.mulAdd (c : Column W) (x y : W) : m (Column W) := do
  let p ← mul x y
  c.accumulate p

/-- Adds 2·x·y to a column: the product once, accumulated twice. -/
def Column.mulAdd2 (c : Column W) (x y : W) : m (Column W) := do
  let p ← mul x y
  let c ← c.accumulate p
  c.accumulate p

/-- The 512-bit product as (high, low), by product scanning. -/
def mul256 (a b : U256 W) : m (U256 W × U256 W) := do
  let c := Column.start (← mul a.l0 b.l0)
  let r0 := c.c0
  let c ← c.shift.mulAdd a.l0 b.l1
  let c ← c.mulAdd a.l1 b.l0
  let r1 := c.c0
  let c ← c.shift.mulAdd a.l0 b.l2
  let c ← c.mulAdd a.l1 b.l1
  let c ← c.mulAdd a.l2 b.l0
  let r2 := c.c0
  let c ← c.shift.mulAdd a.l0 b.l3
  let c ← c.mulAdd a.l1 b.l2
  let c ← c.mulAdd a.l2 b.l1
  let c ← c.mulAdd a.l3 b.l0
  let r3 := c.c0
  let c ← c.shift.mulAdd a.l1 b.l3
  let c ← c.mulAdd a.l2 b.l2
  let c ← c.mulAdd a.l3 b.l1
  let r4 := c.c0
  let c ← c.shift.mulAdd a.l2 b.l3
  let c ← c.mulAdd a.l3 b.l2
  let r5 := c.c0
  let c ← c.shift.mulAdd a.l3 b.l3
  pure (⟨r4, r5, c.c0, c.c1⟩, ⟨r0, r1, r2, r3⟩)

/-- The 512-bit square as (high, low): each cross product is formed once
and accumulated twice (ten multiplications, not sixteen). -/
def sqr256 (a : U256 W) : m (U256 W × U256 W) := do
  let c := Column.start (← mul a.l0 a.l0)
  let r0 := c.c0
  let c ← c.shift.mulAdd2 a.l0 a.l1
  let r1 := c.c0
  let c ← c.shift.mulAdd2 a.l0 a.l2
  let c ← c.mulAdd a.l1 a.l1
  let r2 := c.c0
  let c ← c.shift.mulAdd2 a.l0 a.l3
  let c ← c.mulAdd2 a.l1 a.l2
  let r3 := c.c0
  let c ← c.shift.mulAdd2 a.l1 a.l3
  let c ← c.mulAdd a.l2 a.l2
  let r4 := c.c0
  let c ← c.shift.mulAdd2 a.l2 a.l3
  let r5 := c.c0
  let c ← c.shift.mulAdd a.l3 a.l3
  pure (⟨r4, r5, c.c0, c.c1⟩, ⟨r0, r1, r2, r3⟩)

/-- The 320-bit product with one limb, as (high limb, low four limbs). -/
def mul256x64 (a : U256 W) (k : W) : m (W × U256 W) := do
  let p0 ← mul a.l0 k
  let p1 ← mul a.l1 k
  let p2 ← mul a.l2 k
  let p3 ← mul a.l3 k
  let r1 ← adds p1.2 p0.1
  let r2 ← addc p2.2 p1.1 r1.2
  let r3 ← addc p3.2 p2.1 r2.2
  let top ← add p3.1 r3.2
  pure (top, ⟨p0.2, r1.1, r2.1, r3.1⟩)

end Programs

end Winnow
