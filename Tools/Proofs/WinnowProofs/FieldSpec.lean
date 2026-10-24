import WinnowProofs.IntegerSpec
import WinnowProofs.Field

/-!
# What the field programs compute

Every result is the canonical residue: `r.val = (…) % P`, so `r.val < P`.
The bounds the reduction relies on are the bound halves of its step
lemmas: the high word of x·R is at most R − 1; after the first fold the top
word is at most R + 1; after the second the carry is 0 or 1, and when it is
1 the remaining value is below 2^65; so the third fold cannot carry.
-/

set_option exponentiation.threshold 1024

namespace Winnow

namespace Field

/-- The modulus, written out: SEC 2's p. The limb constants are tied to it. -/
theorem P_eq : P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F := by
  simp [P, R]

theorem P_limbs : P = P0 + 2 ^ 64 * allOnes + 2 ^ 128 * allOnes + 2 ^ 192 * allOnes := by
  simp [P, R, P0, allOnes]

theorem select256_spec (f : Word) (x y : U256 Word) (hf : f.toNat ≤ 1) :
    let r := Id.run (select256 f x y)
    (f.toNat = 1 ∧ r.val = x.val) ∨ (f.toNat = 0 ∧ r.val = y.val) := by
  simp only [select256, Id.run, bind, pure, Machine.select, U256.val]
  word_omega

theorem mulR_spec (x : Word) :
    let r := Id.run (mulR x)
    r.1.toNat * 2 ^ 64 + r.2.toNat = x.toNat * R ∧ r.1.toNat ≤ R - 1 := by
  have h := Eval.mul_spec x (BitVec.ofNat 64 R)
  have := x.isLt; have := (Eval.mul x (BitVec.ofNat 64 R)).2.isLt
  simp only [mulR, Id.run, Machine.mul, Lit.lit] at *
  step_simp [R] at *
  omega

theorem foldHigh_spec (hi lo : U256 Word) :
    let r := Id.run (foldHigh hi lo)
    r.1.val + 2 ^ 256 * r.2.toNat = lo.val + R * hi.val ∧ r.2.toNat ≤ R + 1 := by
  simp only [foldHigh, Id.run, bind, pure, Lit.lit]
  step_facts [mulR, add256, addExact] unfolding [R]
  step_simp [R, U256.val] at *
  omega

theorem foldTop_spec (t : U256 Word) (top : Word) (h : top.toNat ≤ R + 1) :
    let r := Id.run (foldTop t top)
    r.1.val + 2 ^ 256 * r.2.toNat = t.val + R * top.toNat ∧
      r.2.toNat ≤ 1 ∧ (r.2.toNat = 1 → r.1.val < 2 ^ 65) := by
  simp only [foldTop, Id.run, bind, Lit.lit]
  step_facts [mulR, add256] unfolding [R]
  word_bounds
  step_simp [R] at *
  omega

theorem foldCarry_spec (v : U256 Word) (c : Word) (hc : c.toNat ≤ 1)
    (hs : c.toNat = 1 → v.val < 2 ^ 65) :
    (Id.run (foldCarry v c)).val = v.val + R * c.toNat := by
  simp only [foldCarry, Id.run, bind, pure, Machine.select, Lit.lit]
  step_facts [Eval.select, add256] unfolding [R]
  word_bounds
  step_simp [R] at *
  omega

theorem canonical_spec (w : U256 Word) : (Id.run (canonical w)).val = w.val % P := by
  simp only [canonical, Id.run, bind, Lit.lit]
  step_facts [add256, select256] unfolding [R]
  word_bounds
  step_simp [R, P] at *
  omega

theorem reduce_spec (hi lo : U256 Word) :
    (Id.run (reduce hi lo)).val = (2 ^ 256 * hi.val + lo.val) % P := by
  simp only [reduce, Id.run, bind]
  step_facts [foldHigh, foldTop, foldCarry, canonical] unfolding [R]
  step_simp [R, P] at *
  omega

theorem mulMod_spec (a b : U256 Word) : (Id.run (mulMod a b)).val = (a.val * b.val) % P := by
  simp only [mulMod, Id.run, bind]
  step_facts [mul256, reduce]
  step_simp [R, P] at *
  omega

theorem sqrMod_spec (a : U256 Word) : (Id.run (sqrMod a)).val = (a.val * a.val) % P := by
  simp only [sqrMod, Id.run, bind]
  step_facts [sqr256, reduce]
  step_simp [R, P] at *
  omega

theorem addMod_spec (a b : U256 Word) (ha : a.val < P) (hb : b.val < P) :
    (Id.run (addMod a b)).val = (a.val + b.val) % P := by
  simp only [addMod, Id.run, bind, Machine.or, Lit.lit]
  step_facts [add256, Eval.or, select256] unfolding [R]
  word_bounds
  step_simp [R, P] at *
  omega

theorem subMod_spec (a b : U256 Word) (ha : a.val < P) (hb : b.val < P) :
    (Id.run (subMod a b)).val = (a.val + P - b.val) % P := by
  simp only [subMod, Id.run, bind, pure, Machine.select, Lit.lit]
  step_facts [sub256, Eval.select, add256]
  word_bounds
  step_simp [R, P, P0, allOnes] at *
  omega

theorem negMod_spec (a : U256 Word) (ha : a.val < P) :
    (Id.run (negMod a)).val = (P - a.val) % P := by
  have h0 : (⟨lit 0, lit 0, lit 0, lit 0⟩ : U256 Word).val = 0 := by
    simp [U256.val, Lit.lit]
  have := subMod_spec ⟨lit 0, lit 0, lit 0, lit 0⟩ a (by rw [h0]; simp [P, R]) ha
  rw [h0, Nat.zero_add] at this
  exact this

end Field

end Winnow
