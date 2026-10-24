import WinnowProofs

/-!
The axioms behind every theorem the generated Swift relies on.
`scripts/check-generated-lean` runs this file and requires each line to name
only Lean's three standard axioms: no `sorryAx`, and no `Lean.ofReduceBool`
(which `native_decide` and `bv_decide` would add).
-/

open Winnow

#print axioms add256_spec
#print axioms sub256_spec
#print axioms mul256_spec
#print axioms sqr256_spec
#print axioms mul256x64_spec
#print axioms Field.mulMod_spec
#print axioms Field.sqrMod_spec
#print axioms Field.addMod_spec
#print axioms Field.subMod_spec
#print axioms Field.negMod_spec
#print axioms Field.canonical_spec
#print axioms Scalar.mulMod_spec
#print axioms Scalar.addMod_spec
#print axioms Scalar.subMod_spec
#print axioms Scalar.negMod_spec
#print axioms Scalar.canonical_spec
#print axioms Field.P_eq
#print axioms Field.P_limbs
#print axioms Scalar.N_limbs
#print axioms Scalar.C_limbs
#print axioms Curve.double_spec
#print axioms Curve.double_infinity
#print axioms Curve.addMixed_spec
#print axioms Curve.addMixed_cases
#print axioms Curve.same_x_negatives
#print axioms Curve.invert_spec
#print axioms Curve.sqrtCandidate_spec
#print axioms Curve.invert_inv
