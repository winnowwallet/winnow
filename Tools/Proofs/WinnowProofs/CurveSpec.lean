import Mathlib.AlgebraicGeometry.EllipticCurve.Affine.Formula
import Mathlib.FieldTheory.Finite.Basic
import Mathlib.Tactic.FieldSimp
import Mathlib.Tactic.LinearCombination
import WinnowProofs.Curve
import WinnowProofs.Field

/-!
# What the curve programs compute

The point formulas are checked against Mathlib's affine group law on
y² = x³ + 7 (`WeierstrassCurve.Affine.slope`, `addX`, `addY`, from which
Mathlib builds the group of points): for a point given in Jacobian form
(x·Z², y·Z³, Z) with Z ≠ 0, the outputs divided by Z3² and Z3³ are the
affine coordinates of the doubled or added point. This holds in any field
of characteristic other than 2; the generic case is proved, and so are the
facts the Swift dispatch relies on for the cases the formula cannot
express (H = 0 exactly when the x coordinates agree, r = 0 exactly when the
y coordinates do, and same x with different y means Q = −P).

The chains are proved to compute a^(p−2) and a^((p+1)/4) in any commutative
monoid. That a^(p−2) is the inverse in ZMod p is Fermat's little theorem,
proved here under the hypothesis that p is prime; this development does not
prove p prime.
-/

set_option exponentiation.threshold 1024

namespace Winnow.Curve

/-- Evaluation in a field. -/
instance instFieldMachine {K : Type} [Field K] : FieldMachine Id K where
  fmul a b := a * b
  fsqr a := a * a
  fadd a b := a + b
  fsub a b := a - b

/-- secp256k1 over a field: y² = x³ + 7. -/
def secp (K : Type) [Field K] : WeierstrassCurve K := ⟨0, 0, 0, 0, 7⟩

variable {K : Type} [Field K]

theorem secp_negY (x y : K) : (secp K).toAffine.negY x y = -y := by
  simp [secp, WeierstrassCurve.Affine.negY]

/-- Doubling: for y ≠ −y (a point that is not 2-torsion; there is none on
secp256k1), the result represents 2·(x, y). -/
theorem double_spec [DecidableEq K] (x y z : K) (hz : z ≠ 0) (hy : y ≠ (secp K).toAffine.negY x y) :
    let r := Id.run (double (x * z ^ 2) (y * z ^ 3) z)
    let ℓ := (secp K).toAffine.slope x x y y
    r.2.2 ≠ 0 ∧ r.1 = (secp K).toAffine.addX x x ℓ * r.2.2 ^ 2 ∧
      r.2.1 = (secp K).toAffine.addY x x y ℓ * r.2.2 ^ 3 := by
  have hs : (secp K).toAffine.slope x x y y = 3 * x ^ 2 / (y + y) := by
    rw [WeierstrassCurve.Affine.slope_of_Y_ne rfl hy]
    simp only [secp, WeierstrassCurve.Affine.negY]; ring_nf
  rw [secp_negY] at hy
  have h2y : y + y ≠ 0 := by
    intro h; apply hy; linear_combination h
  have h2 : (2 : K) ≠ 0 := fun h => h2y (by linear_combination y * h)
  have hy0 : y ≠ 0 := fun h => h2y (by rw [h]; ring)
  have hs' : 3 * x ^ 2 / (y + y) = 3 * x ^ 2 / (2 * y) := by ring_nf
  simp only [hs, hs']
  simp only [double, fdouble, Id.run, bind, pure, FieldMachine.fmul, FieldMachine.fsqr,
    FieldMachine.fadd, FieldMachine.fsub, WeierstrassCurve.Affine.addY,
    WeierstrassCurve.Affine.negAddY, WeierstrassCurve.Affine.addX, secp_negY]
  simp only [secp]
  refine ⟨?_, ?_, ?_⟩
  · have : y * z ^ 3 * z + y * z ^ 3 * z = (y + y) * z ^ 4 := by ring
    rw [this]; exact mul_ne_zero h2y (pow_ne_zero _ hz)
  · field_simp; ring
  · field_simp; ring

/-- Mixed addition, generic case: for different x coordinates the result
represents (x1, y1) + (x2, y2). -/
theorem addMixed_spec [DecidableEq K] (x1 y1 z x2 y2 : K) (hz : z ≠ 0) (hx : x1 ≠ x2) (h2 : (2 : K) ≠ 0) :
    let r := Id.run (addMixed (x1 * z ^ 2) (y1 * z ^ 3) z x2 y2)
    let ℓ := (secp K).toAffine.slope x1 x2 y1 y2
    r.2.2.1 ≠ 0 ∧ r.1 = (secp K).toAffine.addX x1 x2 ℓ * r.2.2.1 ^ 2 ∧
      r.2.1 = (secp K).toAffine.addY x1 x2 y1 ℓ * r.2.2.1 ^ 3 := by
  have hd : x1 - x2 ≠ 0 := sub_ne_zero.mpr hx
  simp only [WeierstrassCurve.Affine.slope_of_X_ne (W := (secp K).toAffine) hx]
  simp only [addMixed, fdouble, Id.run, bind, pure, FieldMachine.fmul, FieldMachine.fsqr,
    FieldMachine.fadd, FieldMachine.fsub, WeierstrassCurve.Affine.addY,
    WeierstrassCurve.Affine.negAddY, WeierstrassCurve.Affine.addX, secp_negY]
  simp only [secp]
  refine ⟨?_, ?_, ?_⟩
  · have : (z + (x2 * (z * z) - x1 * z ^ 2)) * (z + (x2 * (z * z) - x1 * z ^ 2)) - z * z -
        (x2 * (z * z) - x1 * z ^ 2) * (x2 * (z * z) - x1 * z ^ 2) = -(2 * z ^ 3 * (x1 - x2)) := by ring
    rw [this, neg_ne_zero]
    exact mul_ne_zero (mul_ne_zero h2 (pow_ne_zero _ hz)) hd
  · field_simp; ring
  · field_simp; ring

/-- The quantities the Swift dispatch tests: H vanishes exactly when the x
coordinates agree, and r exactly when the y coordinates do. -/
theorem addMixed_cases (x1 y1 z x2 y2 : K) (hz : z ≠ 0) (h2 : (2 : K) ≠ 0) :
    let r := Id.run (addMixed (x1 * z ^ 2) (y1 * z ^ 3) z x2 y2)
    (r.2.2.2.1 = 0 ↔ x1 = x2) ∧ (r.2.2.2.2 = 0 ↔ y1 = y2) := by
  simp only [addMixed, fdouble, Id.run, bind, pure, FieldMachine.fmul, FieldMachine.fsqr,
    FieldMachine.fadd, FieldMachine.fsub]
  have hz2 : z * z ≠ 0 := mul_ne_zero hz hz
  have hz3 : z ^ 3 ≠ 0 := pow_ne_zero _ hz
  constructor
  · have : x2 * (z * z) - x1 * z ^ 2 = (z * z) * (x2 - x1) := by ring
    rw [this, mul_eq_zero, sub_eq_zero]
    constructor
    · rintro (h | h); exact absurd h hz2; exact h.symm
    · intro h; right; exact h.symm
  · have : y2 * z * (z * z) - y1 * z ^ 3 + (y2 * z * (z * z) - y1 * z ^ 3) = (2 * z ^ 3) * (y2 - y1) := by
      ring
    rw [this, mul_eq_zero, sub_eq_zero]
    constructor
    · rintro (h | h); exact absurd h (mul_ne_zero h2 hz3); exact h.symm
    · intro h; right; exact h.symm

/-- Two points on the curve with the same x and different y are negatives,
so when H = 0 and r ≠ 0 the sum is the point at infinity. -/
theorem same_x_negatives (x y1 y2 : K) (h1 : (secp K).toAffine.Equation x y1)
    (h2 : (secp K).toAffine.Equation x y2) (hy : y1 ≠ y2) :
    y1 = (secp K).toAffine.negY x y2 := by
  rw [secp_negY]
  simp only [WeierstrassCurve.Affine.equation_iff, secp] at h1 h2
  have : (y1 - y2) * (y1 + y2) = 0 := by linear_combination h1 - h2
  rcases mul_eq_zero.mp this with h | h
  · exact absurd (sub_eq_zero.mp h) hy
  · linear_combination h

theorem sqrN_spec (x : K) (k : Nat) : sqrN (m := Id) x k = x ^ (2 ^ k) := by
  induction k generalizing x with
  | zero => simp [sqrN]; rfl
  | succ k ih =>
    show sqrN (m := Id) (x * x) k = _
    rw [ih, ← sq, ← pow_mul, pow_succ, mul_comm]

theorem sqrNMul_spec (x y : K) (k : Nat) : sqrNMul (m := Id) x k y = x ^ (2 ^ k) * y := by
  simp only [sqrNMul, bind, FieldMachine.fmul]
  rw [sqrN_spec]

theorem blocks_spec (a : K) :
    blocks (m := Id) a =
      ((a ^ (2 ^ 2 - 1), a ^ (2 ^ 3 - 1), a ^ (2 ^ 22 - 1), a ^ (2 ^ 223 - 1)) : K × K × K × K) := by
  simp only [blocks, bind, pure, sqrNMul_spec]
  simp only [Id, ← pow_mul, ← pow_succ, ← pow_add]
  norm_num

/-- The chain computes a^(p−2). -/
theorem invert_spec (a : K) : invert (m := Id) a = a ^ (Field.P - 2) := by
  simp only [invert, bind]
  rw [blocks_spec]
  simp only [sqrNMul_spec, ← pow_mul, ← pow_succ, ← pow_add]
  norm_num [Field.P, Field.R]

/-- The chain computes a^((p+1)/4). -/
theorem sqrtCandidate_spec (a : K) : sqrtCandidate (m := Id) a = a ^ ((Field.P + 1) / 4) := by
  simp only [sqrtCandidate, bind]
  rw [blocks_spec]
  simp only [sqrNMul_spec, sqrN_spec, ← pow_mul, ← pow_add]
  norm_num [Field.P, Field.R]

/-- Fermat: in ZMod p, the chain inverts every nonzero element, given that p
is prime (assumed, not proved here). -/
theorem invert_inv [Fact (Nat.Prime Field.P)] (a : ZMod Field.P) (ha : a ≠ 0) :
    invert (m := Id) a = a⁻¹ := by
  have h := ZMod.pow_card_sub_one_eq_one ha
  have e : Field.P - 1 = (Field.P - 2) + 1 := by norm_num [Field.P, Field.R]
  rw [e, pow_succ] at h
  rw [invert_spec]
  exact eq_inv_of_mul_eq_one_left h

end Winnow.Curve
