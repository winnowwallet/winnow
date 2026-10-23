import Mathlib.Tactic.Linarith
import WinnowProofs.MachineSpec

/-!
# Proof automation: symbolic execution

A program unfolded at `Id` is a nest of operation applications. Handing all
of it to `omega` at once does not work: the terms share structure but are
huge as trees, and `omega` (which in Lean implements no dark or grey
shadows, so it is incomplete for some integer problems) gets lost in bound
reasoning across dozens of variables.

`step_facts [f, …]` executes the program symbolically instead. It takes the
innermost application of any listed function, adds that function's lemma
`f_spec` instantiated at it, and replaces the application everywhere by a
fresh variable `st…`. A lemma concludes `value ∧ bound`: the value part
(usually an exact equation) becomes `sv…` and the bound part (small facts
such as "the carry is 0 or 1") becomes `sb…`. A lemma's own hypotheses
are discharged by `omega` with the value facts cleared, so those calls stay
small. What remains at the end is a linear identity over the step variables,
which `linarith` closes when it is a pure identity (with large constant
coefficients `omega` can be slow) and `omega` when it needs integer
reasoning (carries, flags, residues).

`word_omega` does this for the evaluator operations themselves and then
calls `omega`; it is for short programs. Longer ones are proved by steps
over smaller programs that have their own lemmas.
-/

namespace Winnow

open Lean Meta Elab Tactic

private partial def collectWords (e : Expr) : StateT (Std.HashSet Expr × Array Expr) MetaM Unit := do
  if (← get).1.contains e then return
  modify fun (seen, facts) => (seen.insert e, facts)
  if e.isAppOfArity ``BitVec.toNat 2 then
    let fact ← mkAppM ``BitVec.isLt #[e.appArg!]
    modify fun (seen, facts) => (seen, facts.push fact)
  if e.isAppOfArity ``U256.val 1 then
    let fact ← mkAppM ``U256.val_lt #[e.appArg!]
    modify fun (seen, facts) => (seen, facts.push fact)
  match e with
  | .app f a => collectWords f; collectWords a
  | .mdata _ b => collectWords b
  | .proj _ _ b => collectWords b
  | _ => pure ()

/-- Adds `x.toNat < 2^64` for every word `x` and `v.val < 2^256` for every
limb group `v` in the goal and hypotheses. -/
elab "word_bounds" : tactic => withMainContext do
  let goal ← getMainGoal
  let mut roots := #[← instantiateMVars (← goal.getType)]
  for decl in ← getLCtx do
    unless decl.isImplementationDetail do
      roots := roots.push (← instantiateMVars decl.type)
  let (_, (_, facts)) ← (roots.forM collectWords).run ({}, #[])
  let hyps ← facts.mapIdxM fun i proof => do
    pure { userName := Name.mkSimple s!"wb{i}", type := ← inferType proof, value := proof : Hypothesis }
  let (_, goal) ← goal.assertHypotheses hyps
  replaceMainGoal [goal]

/-- The number of parameters of a constant, and how many are explicit. -/
private def arities (f : Name) : MetaM (Nat × Nat) := do
  forallTelescopeReducing (← getConstInfo f).type fun xs _ => do
    let mut n := 0
    for x in xs do
      if (← x.fvarId!.getBinderInfo).isExplicit then n := n + 1
    return (xs.size, n)

/-- Applications of any of `fs` (name, number of parameters) in `e`,
innermost first, without repeats. -/
private partial def applicationsOf (fs : Array (Name × Nat)) (e : Expr) :
    StateT (Std.HashSet Expr × Array Expr) MetaM Unit := do
  if (← get).1.contains e then return
  modify fun (seen, found) => (seen.insert e, found)
  match e with
  | .app g a => applicationsOf fs g; applicationsOf fs a
  | .mdata _ b => applicationsOf fs b
  | .proj _ _ b => applicationsOf fs b
  | _ => pure ()
  if fs.any fun (f, n) => e.isAppOfArity f n then
    modify fun (seen, found) => (seen, found.push e)

/-- The normalisation applied to step facts, side goals and final goals:
unfold `Id.run` and the value of explicit limbs, evaluate constants, plus
`extra` definitions to unfold (a modulus, or `U256.val` itself when a proof
works limb by limb). -/
def stepSimp (extra : Array Ident) (loc : Option (TSyntax ``Lean.Parser.Tactic.location)) :
    TacticM (TSyntax `tactic) := do
  let fixed := #[``Id.run, ``U256.val_mk, ``BitVec.toNat_ofNat, ``Nat.reducePow, ``Nat.reduceMod,
    ``Nat.reduceSub, ``Nat.reduceAdd, ``Nat.reduceMul, ``Nat.zero_mod]
  let names : Array Ident := fixed.map mkIdent ++ extra
  let lemmas ← names.mapM fun i => `(Lean.Parser.Tactic.simpLemma| $i:ident)
  match loc with
  | some l => `(tactic| try simp only [$lemmas,*] $l)
  | none => `(tactic| try simp only [$lemmas,*])

/-- The identifiers of an optional `[a, b, …]` group whose list is child
`index` of the group. -/
private def optionalIdents (group : Syntax) (index : Nat) : Array Ident :=
  if group.getNumArgs > index then group[index].getSepArgs.map (⟨·⟩) else #[]

/-- `step_simp [defs] at loc`: the step normalisation (see `stepSimp`). -/
syntax (name := stepSimpTac) "step_simp" (" [" ident,* "]")? (Lean.Parser.Tactic.location)? : tactic

@[tactic stepSimpTac] def evalStepSimp : Tactic := fun stx => do
  let loc : Option (TSyntax ``Lean.Parser.Tactic.location) :=
    if stx[2].getNumArgs > 0 then some ⟨stx[2][0]⟩ else none
  evalTactic (← stepSimp (optionalIdents stx[1] 1) loc)

/-- See the module documentation. `unfolding [d, …]` adds definitions to
unfold in every fact and side goal (constants such as a modulus). -/
syntax (name := stepFactsTac) "step_facts" " [" ident,* "]" (" unfolding" " [" ident,* "]")? : tactic

@[tactic stepFactsTac] def evalStepFacts : Tactic := fun stx => do
  let fs : Array Ident := stx[2].getSepArgs.map (⟨·⟩)
  let defs := optionalIdents stx[4] 2
  let mut count ← withMainContext do
    pure <| (← getLCtx).foldl (init := 0) fun n decl =>
      if decl.userName.toString.startsWith "st" then n + 1 else n
  let mut targets : Array (Name × Nat) := #[]
  for f in fs do
    let fName ← realizeGlobalConstNoOverloadWithInfo f
    targets := targets.push (fName, (← arities fName).1)
  let everywhere ← `(Lean.Parser.Tactic.location| at *)
  repeat
    let (_, (_, apps)) ← withMainContext do
      (applicationsOf targets (← instantiateMVars (← getMainTarget))).run ({}, #[])
    let some app := apps[0]? | break
    let fName := app.getAppFn.constName!
    let specName := fName.appendAfter "_spec"
    let arity := (← arities fName).2
    let value := Name.mkSimple s!"sv{count}"
    let bound := Name.mkSimple s!"sb{count}"
    let var := Name.mkSimple s!"st{count}"
    count := count + 1
    withMainContext do
      let args := app.getAppArgs
      let data := args.extract (args.size - arity) args.size
      let stmt := mkAppN (mkConst specName) data
      let (hyps, _, body) ← forallMetaTelescopeReducing (← inferType stmt)
      let values := (← getLCtx).foldl (init := #[]) fun acc decl =>
        if decl.userName.toString.startsWith "sv" then acc.push (mkIdent decl.userName) else acc
      let normalise ← stepSimp defs (some everywhere)
      let discharge ← if values.isEmpty then `(tactic| (word_bounds; $normalise; omega))
        else `(tactic| (clear $values*; word_bounds; $normalise; omega))
      for h in hyps do
        let goalType ← instantiateMVars (← h.mvarId!.getType)
        let remaining ← try
            Tactic.run h.mvarId! (evalTactic discharge)
          catch _ => throwError "step_facts: could not discharge{indentExpr goalType}"
        unless remaining.isEmpty do throwError "step_facts: a hypothesis of {specName} was not discharged"
      let proof ← instantiateMVars (mkAppN stmt hyps)
      let facts ← match (← whnfR body).and? with
        | some (valueType, boundType) => pure #[
            { userName := value, type := valueType, value := ← mkAppM ``And.left #[proof] : Hypothesis },
            { userName := bound, type := boundType, value := ← mkAppM ``And.right #[proof] }]
        | none => pure #[{ userName := value, type := body, value := proof : Hypothesis }]
      let (_, goal) ← (← getMainGoal).assertHypotheses facts
      let goal ← goal.withContext do
        let fvars := (← getLCtx).foldl (init := #[]) fun acc decl =>
          if decl.isImplementationDetail then acc else acc.push decl.fvarId
        let (_, _, goal) ← goal.generalizeHyp #[{ expr := app, xName? := var }] fvars
        pure goal
      replaceMainGoal [goal]
      let names := facts.map fun h => mkIdent h.userName
      evalTactic (← stepSimp defs (some (← `(Lean.Parser.Tactic.location| at $names*))))

/-- The last step variable `step_facts` introduced (`st…` with the largest
number). -/
def lastStep : TacticM Name := withMainContext do
  let mut best : Option (Nat × Name) := none
  for decl in (← getLCtx) do
    let n := decl.userName.toString
    if n.startsWith "st" then
      if let some k := (n.drop 2).toNat? then
        if best.all (·.1 < k) then best := some (k, decl.userName)
  match best with
  | some (_, name) => pure name
  | none => throwError "no step variable in context"

/-- Clears the bound facts (`sb…`) added by `step_facts`, so that a final
`omega` sees only the value equations. -/
elab "clear_bounds" : tactic => withMainContext do
  let mut goal ← getMainGoal
  for decl in (← getLCtx) do
    if decl.userName.toString.startsWith "sb" then
      goal ← goal.clear decl.fvarId
  replaceMainGoal [goal]

/-- Symbolic execution of an unfolded short program over the evaluator
operations, then word bounds and `omega`. -/
syntax "word_omega" (" unfolding" " [" ident,* "]")? : tactic

macro_rules
  | `(tactic| word_omega) =>
    `(tactic| (step_facts [Eval.adds, Eval.addc, Eval.subs, Eval.subb, Eval.mul, Eval.add, Eval.or,
        Eval.select]; word_bounds; step_simp at *; omega))
  | `(tactic| word_omega unfolding [$ds,*]) =>
    `(tactic| (step_facts [Eval.adds, Eval.addc, Eval.subs, Eval.subb, Eval.mul, Eval.add, Eval.or,
        Eval.select] unfolding [$ds,*]; word_bounds; step_simp [$ds,*] at *; omega))

end Winnow
