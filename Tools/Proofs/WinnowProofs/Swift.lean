import Std.Data.HashSet
import WinnowProofs.Integer
import WinnowProofs.Curve

/-!
# The Swift printer

The printing interpretation of `Machine`: a word is a Swift expression (a
variable name, an input limb such as `a.l2`, or a literal), and each
operation appends the `let` lines that compute it with the calls modelled in
`Machine.lean`'s `Swift` namespace. Running a program here produces its
Swift body; running it at `Id` is what the theorems are about. Both runs
execute the same definition, which cannot branch on a word, so they perform
the same operations in the same order.

The printer is trusted: each `emit` below must be the Swift form of the
evaluator operation of the same name. Lines whose results are never used are
dropped after the run (and unused tuple components become `_`), which
changes nothing about the values returned.
-/

namespace Winnow.Printer

/-- One Swift `let`: the names it binds and the names it reads. -/
structure Line where
  defs : List String
  uses : List String
  /-- The source, given the bound names (an unused one replaced by `_`). -/
  render : List String → String

structure State where
  next : Nat := 0
  lines : Array Line := #[]

abbrev M := StateM State

def fresh : M String := modifyGet fun s => (s!"t{s.next}", { s with next := s.next + 1 })

def emit (defs uses : List String) (render : List String → String) : M Unit :=
  modify fun s => { s with lines := s.lines.push ⟨defs, uses, render⟩ }

/-- Groups of four from the front of a list. -/
def chunks4 : List Char → List (List Char)
  | a :: b :: c :: d :: rest@(_ :: _) => [a, b, c, d] :: chunks4 rest
  | cs => [cs]

/-- A constant as Swift writes it in `Integer256.swift`: decimal below 10,
otherwise hexadecimal grouped by four digits from the right. -/
def literal (k : Nat) : String :=
  if k < 10 then toString k
  else
    let digits := ((Nat.toDigits 16 (k % 2 ^ 64)).map Char.toUpper).reverse
    let groups := (chunks4 digits).map List.reverse |>.reverse
    "0x" ++ String.ofList (['_'].intercalate groups)

/-- A literal cannot receive a method call without a type, so it is
wrapped as `UInt64(…)` there. -/
def receiver (x : String) : String :=
  if x.front.isDigit then s!"UInt64({x})" else x

def bitExpr (flag : String) : String := s!"({flag} ? 1 : 0)"

instance : Lit String where
  lit k := literal k

instance : Machine M String where
  adds a b := do
    let s ← fresh; let o ← fresh; let c ← fresh
    emit [s, o] [a, b] fun d => s!"let ({d[0]!}, {d[1]!}) = {receiver a}.addingReportingOverflow({b})"
    emit [c] [o] fun d => s!"let {d[0]!}: UInt64 = {o} ? 1 : 0"
    pure (s, c)
  addc a b c := do
    let t ← fresh; let o1 ← fresh; let s ← fresh; let o2 ← fresh; let k ← fresh
    emit [t, o1] [a, b] fun d => s!"let ({d[0]!}, {d[1]!}) = {receiver a}.addingReportingOverflow({b})"
    emit [s, o2] [t, c] fun d => s!"let ({d[0]!}, {d[1]!}) = {t}.addingReportingOverflow({c})"
    emit [k] [o1, o2] fun d => s!"let {d[0]!}: UInt64 = {bitExpr o1} &+ {bitExpr o2}"
    pure (s, k)
  subs a b := do
    let s ← fresh; let o ← fresh; let c ← fresh
    emit [s, o] [a, b] fun d => s!"let ({d[0]!}, {d[1]!}) = {receiver a}.subtractingReportingOverflow({b})"
    emit [c] [o] fun d => s!"let {d[0]!}: UInt64 = {o} ? 1 : 0"
    pure (s, c)
  subb a b c := do
    let t ← fresh; let o1 ← fresh; let s ← fresh; let o2 ← fresh; let k ← fresh
    emit [t, o1] [a, b] fun d => s!"let ({d[0]!}, {d[1]!}) = {receiver a}.subtractingReportingOverflow({b})"
    emit [s, o2] [t, c] fun d => s!"let ({d[0]!}, {d[1]!}) = {t}.subtractingReportingOverflow({c})"
    emit [k] [o1, o2] fun d => s!"let {d[0]!}: UInt64 = {bitExpr o1} &+ {bitExpr o2}"
    pure (s, k)
  mul a b := do
    let h ← fresh; let l ← fresh
    emit [h, l] [a, b] fun d => s!"let ({d[0]!}, {d[1]!}) = {receiver a}.multipliedFullWidth(by: {b})"
    pure (h, l)
  add a b := do
    let s ← fresh
    emit [s] [a, b] fun d => s!"let {d[0]!} = {a} &+ {b}"
    pure s
  or a b := do
    let s ← fresh
    emit [s] [a, b] fun d => s!"let {d[0]!} = {a} | {b}"
    pure s
  select f x y := do
    let s ← fresh
    emit [s] [f, x, y] fun d => s!"let {d[0]!} = ({x} & (0 &- {f})) | ({y} & ~(0 &- {f}))"
    pure s

/-- The field-level printer: each operation is one `FieldElement` call. -/
instance : Curve.FieldMachine M String where
  fmul a b := do
    let s ← fresh
    emit [s] [a, b] fun d => s!"let {d[0]!} = {a} * {b}"
    pure s
  fsqr a := do
    let s ← fresh
    emit [s] [a] fun d => s!"let {d[0]!} = {a}.squared()"
    pure s
  fadd a b := do
    let s ← fresh
    emit [s] [a, b] fun d => s!"let {d[0]!} = {a} + {b}"
    pure s
  fsub a b := do
    let s ← fresh
    emit [s] [a, b] fun d => s!"let {d[0]!} = {a} - {b}"
    pure s

/-- Drops lines whose names are never read, last to first, and renders the
rest. -/
def liveLines (lines : Array Line) (results : List String) : List String := Id.run do
  let mut live : Std.HashSet String := results.foldl (·.insert ·) {}
  let mut out : List String := []
  for line in lines.reverse do
    if line.defs.any live.contains then
      out := line.render (line.defs.map fun d => if live.contains d then d else "_") :: out
      live := line.uses.foldl (·.insert ·) live
  return out

/-! ## Generated functions -/

/-- A parameter or result type. -/
inductive Kind where
  | integer
  | word
  | field

def Kind.swift : Kind → String
  | .integer => "Integer256"
  | .word => "UInt64"
  | .field => "FieldElement"

/-- An argument as the program sees it. -/
inductive Arg where
  | integer (x : U256 String)
  | word (x : String)
  | field (x : String)

def Arg.integer! : Arg → U256 String
  | .integer x => x
  | .word x | .field x => ⟨x, x, x, x⟩

def Arg.word! : Arg → String
  | .word x | .field x => x
  | .integer x => x.l0

def Arg.swift : Arg → String
  | .integer x => s!"Integer256(l0: {x.l0}, l1: {x.l1}, l2: {x.l2}, l3: {x.l3})"
  | .word x | .field x => x

def Arg.names : Arg → List String
  | .integer x => [x.l0, x.l1, x.l2, x.l3]
  | .word x | .field x => [x]

/-- A Swift static function generated from a program. -/
structure Function where
  name : String
  doc : List String
  params : List (String × Kind)
  /-- The result types, with optional tuple labels. -/
  results : List (Option String × Kind)
  body : List Arg → M (List Arg)

def Function.render (f : Function) : String := Id.run do
  let args := f.params.map fun ((name : String), (kind : Kind)) => match kind with
    | .integer => Arg.integer ⟨s!"{name}.l0", s!"{name}.l1", s!"{name}.l2", s!"{name}.l3"⟩
    | .word => Arg.word name
    | .field => Arg.field name
  let (results, state) := (f.body args).run {}
  let lines := liveLines state.lines (results.flatMap Arg.names)
  let params := ", ".intercalate (f.params.map fun ((name : String), (kind : Kind)) =>
    s!"_ {name}: {kind.swift}")
  let resultType := match f.results with
    | [(none, kind)] => kind.swift
    | rs => "(" ++ ", ".intercalate (rs.map fun ((label : Option String), (kind : Kind)) => match label with
        | some l => s!"{l}: {kind.swift}"
        | none => kind.swift) ++ ")"
  let returned := match results with
    | [r] => r.swift
    | rs => "(" ++ ", ".intercalate (rs.map Arg.swift) ++ ")"
  let doc := f.doc.map (s!"    /// {·}")
  let header := s!"    static func {f.name}({params}) -> {resultType} \{"
  let body := lines.map (s!"        {·}")
  return "\n".intercalate (doc ++ [header] ++ body ++ [s!"        return {returned}", "    }"])

/-- A generated Swift file: one caseless enum of static functions. -/
structure File where
  path : String
  summary : List String
  container : String
  containerDoc : List String
  functions : List Function

def File.render (file : File) : String :=
  let header := ["// Generated by Tools/Proofs (`lake exe emit`). Do not edit; see Tools/Proofs/README.md."] ++
    file.summary.map (s!"// {·}")
  let doc := file.containerDoc.map (s!"/// {·}")
  "\n".intercalate (header ++ [""] ++ doc ++ [s!"enum {file.container} \{"] ++
    ["\n\n".intercalate (file.functions.map Function.render)] ++ ["}", ""])

end Winnow.Printer
