import WinnowProofs.Swift
import WinnowProofs.Scalar

/-!
# The generated Swift files

Each function below runs one proved program through the printer. The
theorem named in each doc comment is about the same program at `Id`.
-/

namespace Winnow

open Printer

instance : Inhabited Arg := ⟨.word "0"⟩

/-- `Integer256` arithmetic (`Integer.lean`). -/
def integerFile : File where
  path := "GeneratedInteger256.swift"
  summary := ["Programs and theorems: Tools/Proofs/WinnowProofs/Integer.lean."]
  container := "GeneratedInteger256"
  containerDoc := ["Straight-line `Integer256` arithmetic. Each function is printed from a",
    "program whose result the named theorem states exactly."]
  functions := [
    { name := "add"
      doc := ["a + b and the carry out, 0 or 1 (`add256_spec`)."]
      params := [("a", .integer), ("b", .integer)]
      results := [(none, .integer), (none, .word)]
      body := fun args => do
        let r ← add256 args[0]!.integer! args[1]!.integer!
        pure [.integer r.1, .word r.2] },
    { name := "subtract"
      doc := ["a − b and the borrow out, 0 or 1 (`sub256_spec`)."]
      params := [("a", .integer), ("b", .integer)]
      results := [(none, .integer), (none, .word)]
      body := fun args => do
        let r ← sub256 args[0]!.integer! args[1]!.integer!
        pure [.integer r.1, .word r.2] },
    { name := "multiply"
      doc := ["The 512-bit product a·b (`mul256_spec`)."]
      params := [("a", .integer), ("b", .integer)]
      results := [(some "high", .integer), (some "low", .integer)]
      body := fun args => do
        let r ← mul256 args[0]!.integer! args[1]!.integer!
        pure [.integer r.1, .integer r.2] },
    { name := "square"
      doc := ["The 512-bit square a² (`sqr256_spec`)."]
      params := [("a", .integer)]
      results := [(some "high", .integer), (some "low", .integer)]
      body := fun args => do
        let r ← sqr256 args[0]!.integer!
        pure [.integer r.1, .integer r.2] },
    { name := "multiply"
      doc := ["The 320-bit product a·k with one limb (`mul256x64_spec`)."]
      params := [("a", .integer), ("k", .word)]
      results := [(some "high", .word), (some "low", .integer)]
      body := fun args => do
        let r ← mul256x64 args[0]!.integer! args[1]!.word!
        pure [.word r.1, .integer r.2] }]

/-- `FieldElement` arithmetic (`Field.lean`). -/
def fieldFile : File where
  path := "GeneratedField.swift"
  summary := ["Programs: Tools/Proofs/WinnowProofs/Field.lean; theorems: FieldSpec.lean."]
  container := "GeneratedField"
  containerDoc := ["Straight-line arithmetic modulo p = 2^256 − 2^32 − 977. Every result is",
    "canonical (below p); each function's theorem states the residue it returns."]
  functions := [
    { name := "multiply"
      doc := ["a·b mod p (`Field.mulMod_spec`)."]
      params := [("a", .integer), ("b", .integer)]
      results := [(none, .integer)]
      body := fun args => do
        let r ← Field.mulMod args[0]!.integer! args[1]!.integer!
        pure [.integer r] },
    { name := "square"
      doc := ["a² mod p (`Field.sqrMod_spec`)."]
      params := [("a", .integer)]
      results := [(none, .integer)]
      body := fun args => do
        let r ← Field.sqrMod args[0]!.integer!
        pure [.integer r] },
    { name := "add"
      doc := ["a + b mod p for a, b < p (`Field.addMod_spec`)."]
      params := [("a", .integer), ("b", .integer)]
      results := [(none, .integer)]
      body := fun args => do
        let r ← Field.addMod args[0]!.integer! args[1]!.integer!
        pure [.integer r] },
    { name := "subtract"
      doc := ["a − b mod p for a, b < p (`Field.subMod_spec`)."]
      params := [("a", .integer), ("b", .integer)]
      results := [(none, .integer)]
      body := fun args => do
        let r ← Field.subMod args[0]!.integer! args[1]!.integer!
        pure [.integer r] },
    { name := "negate"
      doc := ["−a mod p for a < p (`Field.negMod_spec`)."]
      params := [("a", .integer)]
      results := [(none, .integer)]
      body := fun args => do
        let r ← Field.negMod args[0]!.integer!
        pure [.integer r] },
    { name := "reduce"
      doc := ["Any 256-bit a modulo p (`Field.canonical_spec`)."]
      params := [("a", .integer)]
      results := [(none, .integer)]
      body := fun args => do
        let r ← Field.canonical args[0]!.integer!
        pure [.integer r] }]

/-- `Scalar` arithmetic (`Scalar.lean`). -/
def scalarFile : File where
  path := "GeneratedScalar.swift"
  summary := ["Programs: Tools/Proofs/WinnowProofs/Scalar.lean; theorems: ScalarSpec.lean."]
  container := "GeneratedScalar"
  containerDoc := ["Straight-line arithmetic modulo the group order n. Every result is",
    "canonical (below n); each function's theorem states the residue it returns."]
  functions := [
    { name := "multiply"
      doc := ["a·b mod n (`Scalar.mulMod_spec`)."]
      params := [("a", .integer), ("b", .integer)]
      results := [(none, .integer)]
      body := fun args => do
        let r ← Scalar.mulMod args[0]!.integer! args[1]!.integer!
        pure [.integer r] },
    { name := "add"
      doc := ["a + b mod n for a, b < n (`Scalar.addMod_spec`)."]
      params := [("a", .integer), ("b", .integer)]
      results := [(none, .integer)]
      body := fun args => do
        let r ← Scalar.addMod args[0]!.integer! args[1]!.integer!
        pure [.integer r] },
    { name := "subtract"
      doc := ["a − b mod n for a, b < n (`Scalar.subMod_spec`)."]
      params := [("a", .integer), ("b", .integer)]
      results := [(none, .integer)]
      body := fun args => do
        let r ← Scalar.subMod args[0]!.integer! args[1]!.integer!
        pure [.integer r] },
    { name := "negate"
      doc := ["−a mod n for a < n (`Scalar.negMod_spec`)."]
      params := [("a", .integer)]
      results := [(none, .integer)]
      body := fun args => do
        let r ← Scalar.negMod args[0]!.integer!
        pure [.integer r] },
    { name := "reduce"
      doc := ["Any 256-bit a modulo n (`Scalar.canonical_spec`)."]
      params := [("a", .integer)]
      results := [(none, .integer)]
      body := fun args => do
        let r ← Scalar.canonical args[0]!.integer!
        pure [.integer r] }]

/-- Point formulas and exponentiation chains (`Curve.lean`). -/
def curveFile : File where
  path := "GeneratedCurve.swift"
  summary := ["Programs: Tools/Proofs/WinnowProofs/Curve.lean; theorems: CurveSpec.lean."]
  container := "GeneratedCurve"
  containerDoc := ["Straight-line point formulas and exponentiation chains over `FieldElement`.",
    "Each function's theorem states what it computes in any field (characteristic not 2)."]
  functions := [
    { name := "double"
      doc := ["2·(X : Y : Z) in Jacobian coordinates, dbl-2009-l (`Curve.double_spec`)."]
      params := [("x", .field), ("y", .field), ("z", .field)]
      results := [(none, .field), (none, .field), (none, .field)]
      body := fun args => do
        let r ← Curve.double args[0]!.word! args[1]!.word! args[2]!.word!
        pure [.field r.1, .field r.2.1, .field r.2.2] },
    { name := "addMixed"
      doc := ["(X1 : Y1 : Z1) + (x2, y2), madd-2007-bl, with H and r; H = 0 exactly when the x",
        "coordinates agree and r = 0 exactly when the y coordinates do (`Curve.addMixed_spec`,",
        "`Curve.addMixed_cases`)."]
      params := [("x1", .field), ("y1", .field), ("z1", .field), ("x2", .field), ("y2", .field)]
      results := [(some "x", .field), (some "y", .field), (some "z", .field), (some "h", .field),
        (some "r", .field)]
      body := fun args => do
        let r ← Curve.addMixed args[0]!.word! args[1]!.word! args[2]!.word! args[3]!.word!
          args[4]!.word!
        pure [.field r.1, .field r.2.1, .field r.2.2.1, .field r.2.2.2.1, .field r.2.2.2.2] },
    { name := "invert"
      doc := ["a^(p−2) by a fixed chain of 255 squarings and 15 multiplications (`Curve.invert_spec`)."]
      params := [("a", .field)]
      results := [(none, .field)]
      body := fun args => do
        let r ← Curve.invert args[0]!.word!
        pure [.field r] },
    { name := "squareRootCandidate"
      doc := ["a^((p+1)/4) by a fixed chain of 255 squarings and 13 multiplications",
        "(`Curve.sqrtCandidate_spec`)."]
      params := [("a", .field)]
      results := [(none, .field)]
      body := fun args => do
        let r ← Curve.sqrtCandidate args[0]!.word!
        pure [.field r] }]

/-- Every generated file, in the order `emit` writes them. -/
def files : List File := [integerFile, fieldFile, scalarFile, curveFile]

end Winnow
