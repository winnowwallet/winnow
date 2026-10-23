import Mathlib.Tactic.Ring
import WinnowProofs.Machine

/-!
# What each machine operation computes

The `Nat` meaning of every evaluator operation, proved from the Swift model
in `Machine.lean`. `word_omega` and `step_facts` (`Tactic.lean`) use these.
-/

namespace Winnow

/-- The value of explicit limbs. -/
@[simp] theorem U256.val_mk (a b c d : Word) :
    (U256.mk a b c d).val = a.toNat + 2 ^ 64 * b.toNat + 2 ^ 128 * c.toNat + 2 ^ 192 * d.toNat := rfl

theorem U256.val_lt (x : U256 Word) : x.val < 2 ^ 256 := by
  have := x.l0.isLt; have := x.l1.isLt; have := x.l2.isLt; have := x.l3.isLt
  unfold U256.val; omega

namespace Eval

private theorem bit_le (b : Bool) : (Swift.bit b).toNat ≤ 1 := by
  cases b <;> decide

private theorem bit_true {p : Prop} [Decidable p] (h : p) : Swift.bit (decide p) = 1#64 := by
  simp [Swift.bit, h]

private theorem bit_false {p : Prop} [Decidable p] (h : ¬p) : Swift.bit (decide p) = 0#64 := by
  simp [Swift.bit, h]

private theorem adding_spec (a b : Word) :
    (Swift.addingReportingOverflow a b).1.toNat +
        2 ^ 64 * (Swift.bit (Swift.addingReportingOverflow a b).2).toNat = a.toNat + b.toNat := by
  have := a.isLt; have := b.isLt
  simp only [Swift.addingReportingOverflow]
  by_cases h : 2 ^ 64 ≤ a.toNat + b.toNat
  · rw [bit_true h]; simp only [BitVec.toNat_add, BitVec.toNat_ofNat]; omega
  · rw [bit_false h]; simp only [BitVec.toNat_add, BitVec.toNat_ofNat]; omega

private theorem subtracting_spec (a b : Word) :
    a.toNat + 2 ^ 64 * (Swift.bit (Swift.subtractingReportingOverflow a b).2).toNat =
      b.toNat + (Swift.subtractingReportingOverflow a b).1.toNat := by
  have := a.isLt; have := b.isLt
  simp only [Swift.subtractingReportingOverflow]
  by_cases h : a.toNat < b.toNat
  · rw [bit_true h]; simp only [BitVec.toNat_sub, BitVec.toNat_ofNat]; omega
  · rw [bit_false h]; simp only [BitVec.toNat_sub, BitVec.toNat_ofNat]; omega

theorem adds_spec (a b : Word) :
    (adds a b).1.toNat + 2 ^ 64 * (adds a b).2.toNat = a.toNat + b.toNat ∧
      (adds a b).2.toNat ≤ 1 :=
  ⟨adding_spec a b, bit_le _⟩

theorem addc_spec (a b c : Word) :
    (addc a b c).1.toNat + 2 ^ 64 * (addc a b c).2.toNat = a.toNat + b.toNat + c.toNat ∧
      (addc a b c).2.toNat ≤ 2 := by
  have h1 := adding_spec a b
  have h2 := adding_spec (Swift.addingReportingOverflow a b).1 c
  have := bit_le (Swift.addingReportingOverflow a b).2
  have := bit_le (Swift.addingReportingOverflow (Swift.addingReportingOverflow a b).1 c).2
  simp only [addc, BitVec.toNat_add]
  omega

theorem subs_spec (a b : Word) :
    a.toNat + 2 ^ 64 * (subs a b).2.toNat = b.toNat + (subs a b).1.toNat ∧
      (subs a b).2.toNat ≤ 1 :=
  ⟨subtracting_spec a b, bit_le _⟩

theorem subb_spec (a b c : Word) :
    a.toNat + 2 ^ 64 * (subb a b c).2.toNat = b.toNat + c.toNat + (subb a b c).1.toNat ∧
      (subb a b c).2.toNat ≤ 2 := by
  have h1 := subtracting_spec a b
  have h2 := subtracting_spec (Swift.subtractingReportingOverflow a b).1 c
  have := bit_le (Swift.subtractingReportingOverflow a b).2
  have := bit_le (Swift.subtractingReportingOverflow (Swift.subtractingReportingOverflow a b).1 c).2
  simp only [subb, BitVec.toNat_add]
  omega

theorem mul_spec (a b : Word) :
    (mul a b).1.toNat * 2 ^ 64 + (mul a b).2.toNat = a.toNat * b.toNat ∧
      (mul a b).1.toNat ≤ 2 ^ 64 - 2 := by
  have ha := a.isLt; have hb := b.isLt
  have hp : a.toNat * b.toNat ≤ (2 ^ 64 - 1) * (2 ^ 64 - 1) :=
    Nat.mul_le_mul (by omega) (by omega)
  have hq : a.toNat * b.toNat / 2 ^ 64 ≤ 2 ^ 64 - 2 := by
    calc a.toNat * b.toNat / 2 ^ 64 ≤ (2 ^ 64 - 1) * (2 ^ 64 - 1) / 2 ^ 64 := Nat.div_le_div_right hp
      _ = 2 ^ 64 - 2 := by norm_num
  simp only [mul, Swift.multipliedFullWidth, BitVec.toNat_ofNat, BitVec.toNat_mul]
  rw [Nat.mod_eq_of_lt (by omega : a.toNat * b.toNat / 2 ^ 64 < 2 ^ 64)]
  exact ⟨by omega, hq⟩

theorem add_spec (a b : Word) : (add a b).toNat = (a.toNat + b.toNat) % 2 ^ 64 := by
  simp [add, BitVec.toNat_add]

/-- `or` of two flags is a flag, and is zero only when both are. -/
theorem or_spec (a b : Word) :
    a.toNat ≤ 1 → b.toNat ≤ 1 →
      ((or a b).toNat = 0 ↔ a.toNat = 0 ∧ b.toNat = 0) ∧ (or a b).toNat ≤ 1 := by
  intro ha hb
  have : a = 0#64 ∨ a = 1#64 := by
    rcases Nat.le_one_iff_eq_zero_or_eq_one.mp ha with h | h
    · left; exact BitVec.eq_of_toNat_eq (by simp [h])
    · right; exact BitVec.eq_of_toNat_eq (by simp [h])
  have : b = 0#64 ∨ b = 1#64 := by
    rcases Nat.le_one_iff_eq_zero_or_eq_one.mp hb with h | h
    · left; exact BitVec.eq_of_toNat_eq (by simp [h])
    · right; exact BitVec.eq_of_toNat_eq (by simp [h])
  rcases ‹a = 0#64 ∨ a = 1#64› with rfl | rfl <;> rcases ‹b = 0#64 ∨ b = 1#64› with rfl | rfl <;>
    simp [or]

theorem select_zero (x y : Word) : select 0#64 x y = y := by
  have : (18446744073709551615#64 : Word) = BitVec.allOnes 64 := by decide
  simp [select]; rw [this, BitVec.and_allOnes]

theorem select_one (x y : Word) : select 1#64 x y = x := by
  have : (18446744073709551615#64 : Word) = BitVec.allOnes 64 := by decide
  simp [select]; rw [this, BitVec.and_allOnes]

/-- With a 0/1 flag, `select` picks `x` on 1 and `y` on 0. -/
theorem select_spec (f x y : Word) :
    f.toNat ≤ 1 →
      (f.toNat = 1 ∧ (select f x y).toNat = x.toNat) ∨ (f.toNat = 0 ∧ (select f x y).toNat = y.toNat) := by
  intro hf
  rcases Nat.le_one_iff_eq_zero_or_eq_one.mp hf with h | h
  · have : f = 0#64 := BitVec.eq_of_toNat_eq (by simp [h])
    subst this
    right; simp [select_zero]
  · have : f = 1#64 := BitVec.eq_of_toNat_eq (by simp [h])
    subst this
    left; simp [select_one]

end Eval

end Winnow
