/-!
# Curve programs: point formulas and exponentiation chains

A second, field-level machine: programs over field elements with
multiplication, squaring, addition and subtraction. Interpreted in any
field, they are what `CurveSpec.lean` proves things about; printed, they
become Swift calls on `FieldElement`, whose operations the word-level
theorems cover. Like word programs, they cannot branch on a value.

- `double` is dbl-2009-l and `addMixed` is madd-2007-bl from the
  Explicit-Formulas Database (Jacobian coordinates, a = 0), the formulas
  `JacobianPoint` used by hand. `addMixed` also returns H and r, the
  quantities whose vanishing marks the cases the formula cannot express.
- `invert` and `sqrtCandidate` are libsecp256k1's addition chains for
  a^(p−2) and a^((p+1)/4): 255 squarings with 15 and 13 multiplications,
  against 256 squarings and about 256 multiplications by square-and-multiply.
-/

namespace Winnow.Curve

/-- The field-level operations. -/
class FieldMachine (m : Type → Type) (F : Type) where
  fmul : F → F → m F
  fsqr : F → m F
  fadd : F → F → m F
  fsub : F → F → m F

export FieldMachine (fmul fsqr fadd fsub)

section Programs

variable {m : Type → Type} [Monad m] {F : Type} [FieldMachine m F]

def fdouble (a : F) : m F := fadd a a

/-- 2P for P = (X : Y : Z) in Jacobian coordinates (dbl-2009-l, 2M + 5S). -/
def double (x y z : F) : m (F × F × F) := do
  let a ← fsqr x
  let b ← fsqr y
  let c ← fsqr b
  let xb ← fadd x b
  let xb ← fsqr xb
  let d ← fsub xb a
  let d ← fsub d c
  let d ← fdouble d
  let e ← fdouble a
  let e ← fadd e a
  let f ← fsqr e
  let d2 ← fdouble d
  let x3 ← fsub f d2
  let dx ← fsub d x3
  let edx ← fmul e dx
  let c2 ← fdouble c
  let c4 ← fdouble c2
  let c8 ← fdouble c4
  let y3 ← fsub edx c8
  let yz ← fmul y z
  let z3 ← fdouble yz
  pure (x3, y3, z3)

/-- P + Q for Jacobian P = (X1 : Y1 : Z1) and affine Q = (x2, y2)
(madd-2007-bl, 7M + 4S), with H and r: H = 0 when the x coordinates agree
(then r = 0 means P = Q and the result must be a doubling instead, and
r ≠ 0 means P = −Q). -/
def addMixed (x1 y1 z1 x2 y2 : F) : m (F × F × F × F × F) := do
  let z1z1 ← fsqr z1
  let u2 ← fmul x2 z1z1
  let t ← fmul y2 z1
  let s2 ← fmul t z1z1
  let h ← fsub u2 x1
  let r ← fsub s2 y1
  let r ← fdouble r
  let hh ← fsqr h
  let i ← fdouble hh
  let i ← fdouble i
  let j ← fmul h i
  let v ← fmul x1 i
  let rr ← fsqr r
  let x3 ← fsub rr j
  let v2 ← fdouble v
  let x3 ← fsub x3 v2
  let vx ← fsub v x3
  let rvx ← fmul r vx
  let yj ← fmul y1 j
  let yj2 ← fdouble yj
  let y3 ← fsub rvx yj2
  let zh ← fadd z1 h
  let zh ← fsqr zh
  let z3 ← fsub zh z1z1
  let z3 ← fsub z3 hh
  pure (x3, y3, z3, h, r)

/-- x squared k times. -/
def sqrN (x : F) : Nat → m F
  | 0 => pure x
  | k + 1 => do
    let y ← fsqr x
    sqrN y k

/-- x^(2^k) · y. -/
def sqrNMul (x : F) (k : Nat) (y : F) : m F := do
  let s ← sqrN x k
  fmul s y

/-- a^(2^n − 1) for n = 2, 3, 6, 9, 11, 22, 44, 88, 176, 220, 223: the
blocks of ones shared by the inversion and square-root exponents. -/
def blocks (a : F) : m (F × F × F × F) := do
  let x2 ← sqrNMul a 1 a
  let x3 ← sqrNMul x2 1 a
  let x6 ← sqrNMul x3 3 x3
  let x9 ← sqrNMul x6 3 x3
  let x11 ← sqrNMul x9 2 x2
  let x22 ← sqrNMul x11 11 x11
  let x44 ← sqrNMul x22 22 x22
  let x88 ← sqrNMul x44 44 x44
  let x176 ← sqrNMul x88 88 x88
  let x220 ← sqrNMul x176 44 x44
  let x223 ← sqrNMul x220 3 x3
  pure (x2, x3, x22, x223)

/-- a^(p−2): the inverse of a nonzero a, by Fermat's little theorem. -/
def invert (a : F) : m F := do
  let (x2, _, x22, x223) ← blocks a
  let t ← sqrNMul x223 23 x22
  let t ← sqrNMul t 5 a
  let t ← sqrNMul t 3 x2
  sqrNMul t 2 a

/-- a^((p+1)/4): a square root of a when one exists (p ≡ 3 mod 4). -/
def sqrtCandidate (a : F) : m F := do
  let (x2, _, x22, x223) ← blocks a
  let t ← sqrNMul x223 23 x22
  let t ← sqrNMul t 6 x2
  sqrN t 2

end Programs

end Winnow.Curve
