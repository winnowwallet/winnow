import SpendReview

open SpendReview

/-- `spend-review-vectors <count> <seed> <path>` writes the fixture and
prints how the expected outcomes are spread. -/
def main (args : List String) : IO UInt32 := do
  let (count, seed, path) ← match args with
    | [c, s, p] => match c.toNat?, s.toNat? with
      | some c, some s => pure (c, s, p)
      | _, _ => throw (IO.userError "count and seed must be numbers")
    | _ => throw (IO.userError "usage: spend-review-vectors <count> <seed> <path>")
  let generate : Gen (List Scenario) := do
    let boundary ← boundaryScenarios
    let mut random : List Scenario := []
    for _ in [0:count] do
      random := random ++ [← scenario]
    return boundary ++ random
  let (scenarios, rng) := generate.run ⟨seed.toUInt64⟩
  let (lines, _) := ((List.range scenarios.length).zip scenarios).mapM (fun (p : Nat × Scenario) => p.2.json p.1) |>.run rng
  let body := ",\n".intercalate lines
  IO.FS.writeFile path ("{\"source\":\"Tools/Proofs/SpendReview, spend-review-vectors " ++ toString count ++ " " ++
    toString seed ++ "\",\"vectors\":[\n" ++ body ++ "\n]}\n")
  let outcomes := scenarios.map fun (s : Scenario) => match review s.account s.psbt s.known s.coords s.tip with
    | .ok r => if r.path = Path.recovery then "accept (recovery path)" else "accept (signers' path)"
    | .error e => e.name
  let names := outcomes.eraseDups
  for name in names.mergeSort (· ≤ ·) do
    IO.println s!"{(outcomes.filter (· == name)).length}\t{name}"
  IO.println s!"{scenarios.length}\ttotal"
  return 0
