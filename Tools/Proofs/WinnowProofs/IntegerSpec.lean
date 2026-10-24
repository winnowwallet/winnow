import WinnowProofs.Tactic
import WinnowProofs.Integer

/-!
# What the integer programs compute

Each theorem states the exact `Nat` value of a program's outputs.
-/

set_option exponentiation.threshold 1024

namespace Winnow



section Proofs

open Eval

theorem add256_spec (a b : U256 Word) :
    let r := Id.run (add256 a b)
    r.1.val + 2 ^ 256 * r.2.toNat = a.val + b.val ∧ r.2.toNat ≤ 1 := by
  simp only [add256, Id.run, bind, pure, U256.val, Machine.adds, Machine.addc]
  word_omega

theorem sub256_spec (a b : U256 Word) :
    let r := Id.run (sub256 a b)
    a.val + 2 ^ 256 * r.2.toNat = b.val + r.1.val ∧ r.2.toNat ≤ 1 := by
  simp only [sub256, Id.run, bind, pure, U256.val, Machine.subs, Machine.subb]
  word_omega

theorem addExact_spec (a b : Word) (h : a.toNat + b.toNat < 2 ^ 64) :
    let r := Id.run (addExact a b)
    r.toNat = a.toNat + b.toNat ∧ r.toNat = a.toNat + b.toNat := by
  simp only [addExact, Id.run, Machine.add, Eval.add, BitVec.toNat_add]
  exact ⟨Nat.mod_eq_of_lt h, Nat.mod_eq_of_lt h⟩

/-- A product with a constant. The equation is repeated in the bound half
so that later side conditions can use it (it is linear). -/
theorem mulLit_spec (x : Word) (k : Nat) (hk : k < 2 ^ 64) :
    let r := Id.run (mulLit x k)
    r.1.toNat * 2 ^ 64 + r.2.toNat = x.toNat * k ∧
      (r.1.toNat * 2 ^ 64 + r.2.toNat = x.toNat * k ∧ r.2.toNat < 2 ^ 64) := by
  have h := Eval.mul_spec x (BitVec.ofNat 64 k)
  have := (Eval.mul x (BitVec.ofNat 64 k)).2.isLt
  simp only [mulLit, Id.run, Machine.mul, Lit.lit, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hk] at *
  omega

/-- `p ∧ q` from `p` and `p → q`. -/
theorem and_of_imp {p q : Prop} (hp : p) (hq : p → q) : p ∧ q := ⟨hp, hq hp⟩

/-- What `accumulate` adds, while the top word has room for the carry. -/
theorem Column.accumulate_spec (c : Column Word) (p : Word × Word) (h : c.c2.toNat + 1 < 2 ^ 64) :
    let r := Id.run (c.accumulate p)
    r.c0.toNat + 2 ^ 64 * r.c1.toNat + 2 ^ 128 * r.c2.toNat =
        c.c0.toNat + 2 ^ 64 * c.c1.toNat + 2 ^ 128 * c.c2.toNat + 2 ^ 64 * p.1.toNat + p.2.toNat ∧
      r.c2.toNat ≤ c.c2.toNat + 1 := by
  simp only [Column.accumulate, Id.run, bind, pure, Machine.adds, Machine.addc, Machine.add]
  word_omega

/-- `mulAdd` adds the product x·y. -/
theorem Column.mulAdd_spec (c : Column Word) (x y : Word) (h : c.c2.toNat + 1 < 2 ^ 64) :
    let r := Id.run (c.mulAdd x y)
    r.c0.toNat + 2 ^ 64 * r.c1.toNat + 2 ^ 128 * r.c2.toNat =
        c.c0.toNat + 2 ^ 64 * c.c1.toNat + 2 ^ 128 * c.c2.toNat + x.toNat * y.toNat ∧
      r.c2.toNat ≤ c.c2.toNat + 1 := by
  have := Column.accumulate_spec c (Eval.mul x y) h
  have := Eval.mul_spec x y
  simp only [Column.mulAdd, Id.run, bind, Machine.mul] at *
  omega

/-- `mulAdd2` adds 2·x·y. -/
theorem Column.mulAdd2_spec (c : Column Word) (x y : Word) (h : c.c2.toNat + 2 < 2 ^ 64) :
    let r := Id.run (c.mulAdd2 x y)
    r.c0.toNat + 2 ^ 64 * r.c1.toNat + 2 ^ 128 * r.c2.toNat =
        c.c0.toNat + 2 ^ 64 * c.c1.toNat + 2 ^ 128 * c.c2.toNat + 2 * (x.toNat * y.toNat) ∧
      r.c2.toNat ≤ c.c2.toNat + 2 := by
  have h1 := Column.accumulate_spec c (Eval.mul x y) (by omega)
  have h2 := Column.accumulate_spec (Id.run (c.accumulate (Eval.mul x y))) (Eval.mul x y) (by omega)
  have := Eval.mul_spec x y
  simp only [Column.mulAdd2, Id.run, bind, Machine.mul] at *
  omega

/-- The product of two four-limb values as the sum of its sixteen limb
products, in the order `mul256` forms them. -/
theorem U256.val_mul (a b : U256 Word) :
    a.val * b.val =
      a.l0.toNat * b.l0.toNat +
      2 ^ 64 * (a.l0.toNat * b.l1.toNat + a.l1.toNat * b.l0.toNat) +
      2 ^ 128 * (a.l0.toNat * b.l2.toNat + a.l1.toNat * b.l1.toNat + a.l2.toNat * b.l0.toNat) +
      2 ^ 192 * (a.l0.toNat * b.l3.toNat + a.l1.toNat * b.l2.toNat + a.l2.toNat * b.l1.toNat +
        a.l3.toNat * b.l0.toNat) +
      2 ^ 256 * (a.l1.toNat * b.l3.toNat + a.l2.toNat * b.l2.toNat + a.l3.toNat * b.l1.toNat) +
      2 ^ 320 * (a.l2.toNat * b.l3.toNat + a.l3.toNat * b.l2.toNat) +
      2 ^ 384 * (a.l3.toNat * b.l3.toNat) := by
  simp only [U256.val]; ring

theorem U256.val_mul_lt (a b : U256 Word) : a.val * b.val < 2 ^ 512 :=
  calc a.val * b.val < 2 ^ 256 * 2 ^ 256 := Nat.mul_lt_mul'' a.val_lt b.val_lt
    _ = 2 ^ 512 := by norm_num

/-- A value plus `B·t` equal to something below `B` forces `t = 0`: how
the top word of a product scan is shown to be empty. -/
theorem eq_of_add_top {g t r B : Nat} (h : g + B * t = r) (hr : r < B) : g = r := by
  rcases Nat.eq_zero_or_pos t with h0 | h0
  · simpa [h0] using h
  · exfalso; have : B ≤ B * t := Nat.le_mul_of_pos_right B h0; omega

open Lean Elab Tactic in
/-- `column_top_zero h` with `h : r < B`: reduces `g = r` to
`g + B·(top word of the last column) = r`, a linear identity.
`column_top_zero h 2` does the same with the top two words, for a scan whose
output stops at the column's low word. -/
elab "column_top_zero " h:ident words:(num)? : tactic => do
  let last := mkIdent (← lastStep)
  match words.map (·.getNat) with
  | some 2 =>
    evalTactic (← `(tactic|
      refine eq_of_add_top (t := ($last).c1.toNat + 2 ^ 64 * ($last).c2.toNat) ?_ $h))
  | _ => evalTactic (← `(tactic| refine eq_of_add_top (t := ($last).c2.toNat) ?_ $h))

/-- A value below 2n reduces modulo n with at most one subtraction. -/
theorem mod_of_lt_two_mul {x n : Nat} (h : x < 2 * n) : x % n = if x < n then x else x - n := by
  split
  · exact Nat.mod_eq_of_lt ‹_›
  · rw [Nat.mod_eq_sub_mod (by omega), Nat.mod_eq_of_lt (by omega)]

/-- The full product. The top column's carry word is shown empty from
`a·b < 2^512`. -/
theorem mul256_spec (a b : U256 Word) :
    let r := Id.run (mul256 a b)
    2 ^ 256 * r.1.val + r.2.val = a.val * b.val := by
  have hlt := U256.val_mul_lt a b
  rw [U256.val_mul] at hlt ⊢
  simp only [mul256, Column.start, Column.shift, Id.run, bind, pure, U256.val, Machine.mul, Lit.lit]
  step_facts [Column.mulAdd]
  have := (Eval.mul_spec a.l0 b.l0).1
  column_top_zero hlt
  clear_bounds; clear hlt
  omega

/-- The square of a four-limb value, cross products doubled, in the order
`sqr256` forms them. -/
theorem U256.val_sq (a : U256 Word) :
    a.val * a.val =
      a.l0.toNat * a.l0.toNat +
      2 ^ 64 * (2 * (a.l0.toNat * a.l1.toNat)) +
      2 ^ 128 * (2 * (a.l0.toNat * a.l2.toNat) + a.l1.toNat * a.l1.toNat) +
      2 ^ 192 * (2 * (a.l0.toNat * a.l3.toNat) + 2 * (a.l1.toNat * a.l2.toNat)) +
      2 ^ 256 * (2 * (a.l1.toNat * a.l3.toNat) + a.l2.toNat * a.l2.toNat) +
      2 ^ 320 * (2 * (a.l2.toNat * a.l3.toNat)) +
      2 ^ 384 * (a.l3.toNat * a.l3.toNat) := by
  simp only [U256.val]; ring

/-- The full square. -/
theorem sqr256_spec (a : U256 Word) :
    let r := Id.run (sqr256 a)
    2 ^ 256 * r.1.val + r.2.val = a.val * a.val := by
  have hlt := U256.val_mul_lt a a
  rw [U256.val_sq] at hlt ⊢
  simp only [sqr256, Column.start, Column.shift, Id.run, bind, pure, U256.val, Machine.mul, Lit.lit]
  step_facts [Column.mulAdd, Column.mulAdd2]
  have := (Eval.mul_spec a.l0 a.l0).1
  column_top_zero hlt
  clear_bounds; clear hlt
  omega

theorem mul256x64_spec (a : U256 Word) (k : Word) :
    let r := Id.run (mul256x64 a k)
    2 ^ 256 * r.1.toNat + r.2.val = a.val * k.toNat := by
  have : a.val * k.toNat = a.l0.toNat * k.toNat + 2 ^ 64 * (a.l1.toNat * k.toNat) +
      2 ^ 128 * (a.l2.toNat * k.toNat) + 2 ^ 192 * (a.l3.toNat * k.toNat) := by
    simp only [U256.val]; ring
  rw [this]
  simp only [mul256x64, Id.run, bind, pure, U256.val, Machine.mul, Machine.adds, Machine.addc, Machine.add]
  word_omega

end Proofs

end Winnow
