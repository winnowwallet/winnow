import WinnowProofs.FieldSpec
import WinnowProofs.Scalar

/-!
# What the scalar programs compute

Every result is the canonical residue modulo n. The reduction's bounds are
the bound halves of its stage lemmas: after the first fold the top word is
at most 1; after the second the top word is at most 4; after the third the
carry is 0 or 1, and when it is 1 the remaining value is below 2^131, so
the value is below 2n and one conditional subtraction finishes.
-/

set_option exponentiation.threshold 1024

namespace Winnow

namespace Scalar

theorem C_val : C = 0x14551231950B75FC4402DA1732FC9BEBF := by
  simp [C, N]

/-- n's limbs and C's limbs are tied to n itself (SEC 2's order). -/
theorem N_limbs : N = N0 + 2 ^ 64 * N1 + 2 ^ 128 * N2 + 2 ^ 192 * N3 := by
  simp [N, N0, N1, N2, N3]

theorem C_limbs : C = C0 + 2 ^ 64 * C1 + 2 ^ 128 := by
  simp [C, N, C0, C1]

theorem cLimbs_val : (cLimbs : U256 Word).val = C := by
  simp [cLimbs, U256.val, Lit.lit, C, N, C0, C1]

theorem foldHigh_spec (hi lo : U256 Word) :
    let r := Id.run (foldHigh hi lo)
    r.1.val + 2 ^ 256 * (r.2.1.toNat + 2 ^ 64 * r.2.2.1.toNat + 2 ^ 128 * r.2.2.2.toNat) =
        lo.val + C * hi.val ∧
      r.2.2.2.toNat ≤ 1 := by
  have hlt : lo.val + C * hi.val < 2 ^ 448 := by
    have := lo.val_lt; have := hi.val_lt; simp only [C, N]; omega
  have hb := lo.val_lt; have hb' := hi.val_lt
  simp only [foldHigh, Column.ofWord, Column.shift, Id.run, bind, pure, Lit.lit] at *
  step_facts [Column.mulAdd, Column.accumulate] unfolding [C0, C1]
  refine and_of_imp ?_ fun key => ?_
  · column_top_zero hlt
    clear_bounds; clear hlt hb hb'
    step_simp [C, N, C0, C1, U256.val] at *
    linarith
  · step_simp [C, N] at *
    linarith

theorem foldMid_spec (mlo : U256 Word) (m4 m5 m6 : Word) (h6 : m6.toNat ≤ 1) :
    let r := Id.run (foldMid mlo m4 m5 m6)
    r.1.val + 2 ^ 256 * r.2.toNat = mlo.val + C * (m4.toNat + 2 ^ 64 * m5.toNat + 2 ^ 128 * m6.toNat) ∧
      r.2.toNat ≤ 4 := by
  have hlt : mlo.val + C * (m4.toNat + 2 ^ 64 * m5.toNat + 2 ^ 128 * m6.toNat) < 2 ^ 320 := by
    have := mlo.val_lt; have := m4.isLt; have := m5.isLt; simp only [C, N]; omega
  have hb := mlo.val_lt; have := m4.isLt; have := m5.isLt
  simp only [foldMid, Column.ofWord, Column.shift, Id.run, bind, pure, Lit.lit] at *
  step_facts [Column.mulAdd, Column.accumulate] unfolding [C0, C1]
  refine and_of_imp ?_ fun key => ?_
  · column_top_zero hlt 2
    clear_bounds; clear hlt hb
    step_simp [C, N, C0, C1, U256.val] at *
    linarith
  · step_simp [C, N] at *
    linarith

theorem foldLow_spec (p : U256 Word) (top : Word) (h : top.toNat ≤ 4) :
    let r := Id.run (foldLow p top)
    r.1.val + 2 ^ 256 * r.2.toNat = p.val + C * top.toNat ∧
      r.2.toNat ≤ 1 ∧ (r.2.toNat = 1 → r.1.val < 2 ^ 131) := by
  simp only [foldLow, Id.run, bind, Machine.adds, Lit.lit]
  step_facts [mulLit, Eval.adds, addExact, add256] unfolding [C0, C1]
  word_bounds
  step_simp [C, N, C0, C1] at *
  omega

theorem reduceCarry_spec (q : U256 Word) (c : Word) (hc : c.toNat ≤ 1)
    (hs : q.val + 2 ^ 256 * c.toNat < 2 * N) :
    (Id.run (reduceCarry q c)).val = (q.val + 2 ^ 256 * c.toNat) % N := by
  have hC := cLimbs_val
  rw [mod_of_lt_two_mul hs]
  split_ifs with hlt
  all_goals
    simp only [reduceCarry, Id.run, bind, Machine.or] at *
    step_facts [add256, Eval.or, Field.select256]
    word_bounds
    rw [hC] at *
    step_simp [C, N] at *
    omega

theorem canonical_spec (w : U256 Word) : (Id.run (canonical w)).val = w.val % N := by
  have hC := cLimbs_val
  rw [mod_of_lt_two_mul (by have := w.val_lt; simp only [N]; omega)]
  split_ifs with hlt
  all_goals
    simp only [canonical, Id.run, bind] at *
    step_facts [add256, Field.select256]
    word_bounds
    rw [hC] at *
    step_simp [C, N] at *
    omega

theorem reduce_spec (hi lo : U256 Word) :
    (Id.run (reduce hi lo)).val = (2 ^ 256 * hi.val + lo.val) % N := by
  simp only [reduce, Id.run, bind]
  step_facts [foldHigh, foldMid, foldLow, reduceCarry] unfolding [C, N]
  step_simp [C, N] at *
  omega

theorem mulMod_spec (a b : U256 Word) : (Id.run (mulMod a b)).val = (a.val * b.val) % N := by
  simp only [mulMod, Id.run, bind]
  step_facts [mul256, reduce]
  step_simp [N] at *
  omega

theorem addMod_spec (a b : U256 Word) (ha : a.val < N) (hb : b.val < N) :
    (Id.run (addMod a b)).val = (a.val + b.val) % N := by
  have hC := cLimbs_val
  simp only [addMod, reduceCarry, Id.run, bind, Machine.or] at *
  step_facts [add256, Eval.or, Field.select256]
  word_bounds
  rw [hC] at *
  step_simp [C, N] at *
  omega

theorem subMod_spec (a b : U256 Word) (ha : a.val < N) (hb : b.val < N) :
    (Id.run (subMod a b)).val = (a.val + N - b.val) % N := by
  simp only [subMod, Id.run, bind, pure, Machine.select, Lit.lit]
  step_facts [sub256, Eval.select, add256]
  word_bounds
  step_simp [N, N0, N1, N2, N3] at *
  omega

theorem negMod_spec (a : U256 Word) (ha : a.val < N) :
    (Id.run (negMod a)).val = (N - a.val) % N := by
  have h0 : (⟨lit 0, lit 0, lit 0, lit 0⟩ : U256 Word).val = 0 := by
    simp [U256.val, Lit.lit]
  have := subMod_spec ⟨lit 0, lit 0, lit 0, lit 0⟩ a (by rw [h0]; simp [N]) ha
  rw [h0, Nat.zero_add] at this
  exact this

end Scalar

end Winnow
