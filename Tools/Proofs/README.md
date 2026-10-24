[Back to main README](../../README.md)

# Proved limb arithmetic

The 256-bit integer, field (mod p) and scalar (mod n) arithmetic of
[NativeSecp256k1](../../Sources/NativeSecp256k1/README.md), its Jacobian
doubling and mixed-addition formulas, and its field inversion and square
root chains are written here once, as straight-line programs in a small
Lean 4 language, proved in Lean, and printed as the Swift in
[`Sources/NativeSecp256k1/Generated`](../../Sources/NativeSecp256k1/Generated).
The app builds from that committed Swift; nothing here is a build
dependency, and no Lean code is linked into anything.

## Layout

| File | What it holds |
| --- | --- |
| [Machine.lean](WinnowProofs/Machine.lean) | The language: a `Machine` class of word operations (add and subtract with carry, the 128-bit product, wrapping add, flag `or`, mask `select`), the model of the Swift `UInt64` calls the printer emits, and the evaluator over `BitVec 64` built from that model. |
| [Integer.lean](WinnowProofs/Integer.lean), [Field.lean](WinnowProofs/Field.lean), [Scalar.lean](WinnowProofs/Scalar.lean) | The programs. Each is a definition polymorphic in the machine, so it cannot branch on a word. |
| [MachineSpec.lean](WinnowProofs/MachineSpec.lean) | What each operation computes in `Nat`, proved from the Swift model. |
| [IntegerSpec.lean](WinnowProofs/IntegerSpec.lean), [FieldSpec.lean](WinnowProofs/FieldSpec.lean), [ScalarSpec.lean](WinnowProofs/ScalarSpec.lean) | The theorems: the exact value of every output, and for field and scalar operations that the result is the canonical residue. |
| [Curve.lean](WinnowProofs/Curve.lean), [CurveSpec.lean](WinnowProofs/CurveSpec.lean) | A second, field-level machine (multiply, square, add, subtract) and its programs: dbl-2009-l, madd-2007-bl and libsecp256k1's addition chains for a^(p−2) and a^((p+1)/4), with theorems against Mathlib's affine group law and on the chains' exponents. |
| [Tactic.lean](WinnowProofs/Tactic.lean) | `step_facts`, a symbolic executor that replaces each step by a variable carrying its lemma, so `omega` and `linarith` only ever see small linear problems. |
| [Swift.lean](WinnowProofs/Swift.lean), [Generated.lean](WinnowProofs/Generated.lean), [Emit.lean](Emit.lean) | The printer (the same programs run with a symbolic machine that records Swift `let` lines) and the list of generated functions. |
| [Audit.lean](Audit.lean) | `#print axioms` for every theorem the generated code relies on. |

## Running it

```sh
brew install elan-init
scripts/check-generated-lean
```

The script fetches Mathlib's prebuilt files (about 5 GB, once), builds the
project (which checks every proof, in under a minute), requires every
theorem to use only Lean's standard axioms (`propext`, `Classical.choice`,
`Quot.sound`: no `sorry`, `native_decide` or `bv_decide`), regenerates the
Swift into a scratch directory and diffs it against the committed files.
To change the arithmetic, edit a program, fix its proof, then run
`lake exe emit ../../Sources/NativeSecp256k1/Generated` here and commit both.

Lean is pinned to v4.35.0 by [lean-toolchain](lean-toolchain) and Mathlib to
the v4.35.0 tag by commit in [lakefile.toml](lakefile.toml); its own
dependencies are pinned in [lake-manifest.json](lake-manifest.json). The
printer's output is a pure function of the sources (no dates, paths or
versions), so a rerun is byte-identical.

## What is proved and what is trusted

Proved, for all inputs: each program at the evaluator computes what its
theorem says. For example `Field.mulMod_spec`:
`(Id.run (Field.mulMod a b)).val = (a.val * b.val) % P`, which also says the
result is below p. The reduction's bound arguments (the top word after the
first fold is at most R + 1, the carry after the second is 0 or 1 and then
leaves under 65 bits, the third fold cannot carry, a product scan's top
word is empty) are the bound halves of the step lemmas.

For the curve: in any field of characteristic other than 2, the doubling
and mixed-addition outputs, divided by Z3² and Z3³, are Mathlib's affine
`addX` and `addY` of the two points (`Curve.double_spec`,
`Curve.addMixed_spec`, for a point that is not 2-torsion and for
different x coordinates); H = 0 exactly when the x coordinates agree and
r = 0 exactly when the y coordinates do (`Curve.addMixed_cases`), and two
curve points with the same x and different y are negatives
(`Curve.same_x_negatives`), which is what the hand-written dispatch in
`JacobianPoint.adding` relies on. The chains compute a^(p−2) and
a^((p+1)/4) (`Curve.invert_spec`, `Curve.sqrtCandidate_spec`), and
`Curve.invert_inv` derives the inverse in ZMod p from Fermat's little
theorem under the hypothesis that p is prime.

Trusted, not proved:

- Lean's kernel, and Mathlib's `ring`, `linarith` and Lean's `omega` only as
  far as they produce kernel-checked proofs (they do; no `ofReduceBool`).
- The model of Swift in `Machine.lean`: `addingReportingOverflow`,
  `subtractingReportingOverflow`, `multipliedFullWidth(by:)`, `&+`, `|`,
  `&`, `~`, `0 &-` and `b ? 1 : 0` on `UInt64` behave as their standard
  library documentation says.
- The printer: each operation's Swift lines in `Swift.lean` compute that
  operation's evaluator definition, and the two interpretations of one
  program perform the same operations (true because a program cannot look
  at a word; this is an argument about the definitions, not a Lean theorem).
- That p is prime (SEC 2; Fermat's little theorem needs it), and that the
  curve has no point of order 2 (`double_spec` assumes y ≠ −y).
- That the field-level theorems, stated over an abstract field, apply to
  the Swift: the Swift `FieldElement` operations compute in ZMod p because
  the word-level theorems say each returns the canonical residue.
- The Swift wrappers that call the generated functions (`Integer256`,
  `FieldElement`, `Scalar`, `JacobianPoint`), the case dispatch in
  `JacobianPoint.adding`, and everything above (scalar multiplication, the
  generator table, keys, BIP340), which the existing tests and fuzzing cover.

The differential tests in
[NativeSecp256k1GeneratedTests](../../Tests/BitcoinCoreTests/NativeSecp256k1GeneratedTests.swift)
compare the generated functions with the previous hand-written arithmetic,
formulas and square-and-multiply exponentiation, and with the fuzz core's
independent reference implementation, on structured limbs, which checks the
trusted printer and Swift model from the other side.
