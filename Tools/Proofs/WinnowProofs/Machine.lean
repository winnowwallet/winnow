/-!
# The straight-line word machine

A program is a Lean definition polymorphic in a `Machine`: a monad `m` and a
word type `W` with the operations below and nothing else. A program cannot
inspect a word, so it cannot branch on one: every program is straight-line.

Two interpretations exist. `Id` over `BitVec 64` (this file) is the
evaluator the theorems are about; `Printer` over Swift expressions
(`Swift.lean`) is the code generator. Each evaluator operation is written
as the composition of the Swift standard-library calls the printer emits for
it, modelled in `Swift` below, so the per-operation gap between proof and
Swift is that model and nothing else.
-/

namespace Winnow

abbrev Word := BitVec 64

/-! ## Swift's `UInt64`, as modelled

These are the semantics this development assumes for the Swift calls the
printer emits. They are the documented standard-library behaviour. -/
namespace Swift

/-- `a.addingReportingOverflow(b)`: the wrapped sum, and whether it wrapped. -/
def addingReportingOverflow (a b : Word) : Word × Bool := (a + b, 2 ^ 64 ≤ a.toNat + b.toNat)

/-- `a.subtractingReportingOverflow(b)`: the wrapped difference, and whether it wrapped. -/
def subtractingReportingOverflow (a b : Word) : Word × Bool := (a - b, a.toNat < b.toNat)

/-- `a.multipliedFullWidth(by: b)`: the 128-bit product as (high, low). -/
def multipliedFullWidth (a b : Word) : Word × Word :=
  (BitVec.ofNat 64 (a.toNat * b.toNat / 2 ^ 64), a * b)

/-- `flag ? 1 : 0` at type `UInt64`. -/
def bit (b : Bool) : Word := if b then 1 else 0

end Swift

/-! ## The operations -/

/-- Constants. Separate from `Machine` so that pure code can name one. -/
class Lit (W : Type) where
  /-- The word with this value (taken modulo 2^64). -/
  lit : Nat → W

export Lit (lit)

/-- The operations a program may use. Carries, borrows and flags are words
holding small values. -/
class Machine (m : Type → Type) (W : outParam Type) where
  /-- `a + b` and the carry out (0 or 1). -/
  adds : W → W → m (W × W)
  /-- `a + b + c` and the carry out (the number of wraps, 0 to 2). -/
  addc : W → W → W → m (W × W)
  /-- `a − b` and the borrow out (0 or 1). -/
  subs : W → W → m (W × W)
  /-- `a − b − c` and the borrow out (the number of wraps, 0 to 2). -/
  subb : W → W → W → m (W × W)
  /-- The 128-bit product `a × b` as (high, low). -/
  mul : W → W → m (W × W)
  /-- `a &+ b`, wrapping modulo 2^64. -/
  add : W → W → m W
  /-- Bitwise `a | b`; used to combine 0/1 flags. -/
  or : W → W → m W
  /-- `x` when the flag is 1 and `y` when it is 0, by masking with `0 &- flag`. -/
  select : W → W → W → m W

export Machine (adds addc subs subb mul add or select)

/-! ## The evaluator -/

namespace Eval

def adds (a b : Word) : Word × Word :=
  let r := Swift.addingReportingOverflow a b
  (r.1, Swift.bit r.2)

def addc (a b c : Word) : Word × Word :=
  let r := Swift.addingReportingOverflow a b
  let s := Swift.addingReportingOverflow r.1 c
  (s.1, Swift.bit r.2 + Swift.bit s.2)

def subs (a b : Word) : Word × Word :=
  let r := Swift.subtractingReportingOverflow a b
  (r.1, Swift.bit r.2)

def subb (a b c : Word) : Word × Word :=
  let r := Swift.subtractingReportingOverflow a b
  let s := Swift.subtractingReportingOverflow r.1 c
  (s.1, Swift.bit r.2 + Swift.bit s.2)

def mul (a b : Word) : Word × Word := Swift.multipliedFullWidth a b

def add (a b : Word) : Word := a + b

def or (a b : Word) : Word := a ||| b

def select (f x y : Word) : Word := (x &&& (0 - f)) ||| (y &&& ~~~(0 - f))

end Eval

instance : Lit Word where
  lit k := BitVec.ofNat 64 k

instance : Machine Id Word where
  adds a b := Eval.adds a b
  addc a b c := Eval.addc a b c
  subs a b := Eval.subs a b
  subb a b c := Eval.subb a b c
  mul a b := Eval.mul a b
  add a b := Eval.add a b
  or a b := Eval.or a b
  select f x y := Eval.select f x y

/-! ## Limb groups -/

/-- Four little-endian limbs; `l0` is the least significant. -/
structure U256 (W : Type) where
  l0 : W
  l1 : W
  l2 : W
  l3 : W
deriving Inhabited

/-- The value of four limbs. -/
def U256.val (x : U256 Word) : Nat :=
  x.l0.toNat + 2 ^ 64 * x.l1.toNat + 2 ^ 128 * x.l2.toNat + 2 ^ 192 * x.l3.toNat

/-- A product-scanning column: `c0 + 2^64·c1 + 2^128·c2`. -/
structure Column (W : Type) where
  c0 : W
  c1 : W
  c2 : W

end Winnow
