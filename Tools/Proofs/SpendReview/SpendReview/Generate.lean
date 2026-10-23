import SpendReview.Model

/-!
# Scenario generator and fixture writer

Seeded, so a fixture regenerates byte for byte. Each scenario starts as a
spend the account's own `createSpend` could have made and then takes up to
three mutations, each aimed at one check of the review. The model decides
the expected answer; nothing here does.
-/

namespace SpendReview

structure Rng where
  state : UInt64

abbrev Gen := StateM Rng

/-- SplitMix64. -/
def next : Gen UInt64 := modifyGet fun (r : Rng) =>
  let s : UInt64 := r.state + 0x9E3779B97F4A7C15
  let z : UInt64 := (s ^^^ (s >>> 30)) * 0xBF58476D1CE4E5B9
  let z : UInt64 := (z ^^^ (z >>> 27)) * 0x94D049BB133111EB
  ((z ^^^ (z >>> 31) : UInt64), (⟨s⟩ : Rng))

def below (n : Nat) : Gen Nat := do
  if n = 0 then return 0
  return (← next).toNat % n

def between (lo hi : Nat) : Gen Nat := do
  return lo + (← below (hi + 1 - lo))

def chance (k n : Nat) : Gen Bool := do
  return (← below n) < k

def pick {α} [Inhabited α] (xs : List α) : Gen α := do
  return xs.getD (← below xs.length) default

partial def shuffle {α} [Inhabited α] (xs : List α) : Gen (List α) := do
  if xs.isEmpty then return []
  let i ← below xs.length
  return xs.getD i default :: (← shuffle (xs.eraseIdx i))

def updateAt {α} (xs : List α) (i : Nat) (f : α → α) : List α :=
  xs.mapIdx fun j x => if i = j then f x else x

structure Scenario where
  account : Account
  known : List Coin
  coords : List (Int × Nat)
  tip : Nat
  psbt : Psbt
  notes : List String
  deriving Inhabited

def Scenario.blocks (s : Scenario) : Nat := s.account.recovery.getD 0

/-- Applies `f` to the first known coin at the outpoint input `i` names. -/
def Scenario.updateCoinOf (s : Scenario) (i : Nat) (f : Coin → Coin) : Scenario :=
  match s.psbt.inputs[i]? with
  | some { txid := some t, vout := some v, .. } =>
    match s.known.findIdx? (fun k => k.txid == t && k.vout == v) with
    | some at_ => { s with known := updateAt s.known at_ f }
    | none => s
  | _ => s

def Scenario.updateInput (s : Scenario) (i : Nat) (f : Input → Input) : Scenario :=
  { s with psbt := { s.psbt with inputs := updateAt s.psbt.inputs i f } }

def Scenario.updateOutput (s : Scenario) (j : Nat) (f : Output → Output) : Scenario :=
  { s with psbt := { s.psbt with outputs := updateAt s.psbt.outputs j f } }

def Scenario.note (s : Scenario) (n : String) : Scenario := { s with notes := s.notes ++ [n] }

def Scenario.inputTotal (s : Scenario) : Int :=
  s.psbt.inputs.foldl (fun acc i => acc + (i.witness.map (·.1)).getD 0) 0

def Scenario.outputTotal (s : Scenario) : Int :=
  s.psbt.outputs.foldl (fun acc o => acc + o.amount.getD 0) 0

/-- Splits `total` into `n` positive parts (fewer when it is too small). -/
def split (total : Nat) (n : Nat) : Gen (List Nat) := do
  if total = 0 then return []
  let n := min n total
  let mut cuts : List Nat := []
  for _ in [1:n] do
    cuts := (← between 1 (total - 1)) :: cuts
  let sorted := (cuts.mergeSort (· ≤ ·)).eraseDups
  let points := 0 :: sorted ++ [total]
  return (points.zip points.tail).map (fun (a, b) => b - a) |>.filter (· > 0)

def sequenceFor (s : Account) (tip : Nat) (k : Coin) (mode : Nat) : Gen (Option Nat) := do
  let blocks := s.recovery.getD 1
  match mode with
  | 0 => pick [some 0xFFFF_FFFD, none, some 0xFFFF_FFFE, some 0xFFFF_FFFF]
  | 1 => return some blocks
  | 2 =>
    -- BIP326: the coin's confirmations, while they fit in 16 bits.
    let confirmations := tip + 1 - k.height
    return if k.height > 0 ∧ k.height ≤ tip ∧ confirmations < 65536 then some confirmations else some 0xFFFF_FFFD
  | _ => pick [some 0xFFFF_FFFD, some blocks, some (blocks + 7), some 0]

/-- A spend `createSpend` could have made: known coins, a subset of them as
inputs with the account's own policy fields, payments and change. -/
def baseScenario : Gen Scenario := do
  let recovery ← pick [none, none, some 1, some 10, some 144, some 65535]
  let account : Account := ⟨recovery⟩
  let tip ← between (recovery.getD 0 + 150) (recovery.getD 0 + 900_000)
  let coinCount ← between 1 4
  let mut known : List Coin := []
  for n in [0:coinCount] do
    let chain ← pick [Chain.receive, Chain.change]
    let index ← below 5
    let height ← (do
      if recovery.isSome ∧ (← chance 1 2) then
        -- Old enough for the recovery path.
        between 1 (tip + 1 - recovery.getD 0)
      else between (tip - 140) tip)
    let amount ← pick [← between 1_000 100_000_000, ← between 546 5_000, ← between 1 2_000_000_000_000]
    known := known ++ [{ txid := n + 1, vout := ← below 3, amount := amount, script := .account chain.toNat index,
                         chain, index, height, coinbase := false }]
  let spent ← shuffle known
  let spent := spent.take (← between 1 spent.length)
  let mode ← below 4
  let mut inputs : List Input := []
  for k in spent do
    inputs := inputs ++ [{ txid := some k.txid, vout := some k.vout, sequence := ← sequenceFor account tip k mode,
                           sighash := ← pick [some 0, some 0, none, some 1],
                           witness := some (k.amount, k.script),
                           internalKey := some (.internal k.chain.toNat k.index),
                           leaves := ← shuffle (account.expectedLeaves k.chain.toNat k.index) }]
  let total := (spent.foldl (fun (acc : Int) (k : Coin) => acc + k.amount) 0).toNat
  let fee ← pick [← between 0 (total / 10), total / 10, ← between 0 (total / 200)]
  let parts ← split (total - fee) (← between 1 3)
  let changeIndex ← below 5
  let withChange ← chance 2 3
  let mut outputs : List Output := []
  for p in [0:parts.length] do
    let script ← (do
      if withChange ∧ p = 0 then pure (Script.account 1 changeIndex)
      else if ← chance 1 10 then pure (Script.account 0 (← below 5))
      else pure (Script.foreign (← between 1 6)))
    outputs := outputs ++ [{ amount := some (parts.getD p 0), script := some script }]
  let shuffled ← shuffle outputs
  let mut coords : List (Int × Nat) := if ← chance 9 10 then [(1, changeIndex)] else []
  for _ in [0:← below 3] do
    coords := coords ++ [(← pick [0, 1, 1, 2, -1], ← below 6)]
  let version ← pick [2, 2, 2, 1]
  return { account, known, coords, tip, psbt := { txVersion := version, inputs, outputs := shuffled }, notes := [] }

def leafCoordinate : Leaf → Option (Nat × Nat)
  | .signers c i => some (c, i)
  | .recovery c i => some (c, i)
  | .foreign _ => none

/-- One mutation aimed at one check. -/
def mutate (s : Scenario) : Gen Scenario := do
  let i ← below s.psbt.inputs.length
  let j ← below s.psbt.outputs.length
  let b := s.blocks
  match ← below 42 with
  | 0 => return (s.updateInput i fun (x : Input) => { x with txid := none }).note "txid absent"
  | 1 => return (s.updateInput i fun (x : Input) => { x with vout := none }).note "vout absent"
  | 2 =>
    let dup := s.psbt.inputs.getD i default
    let at_ ← below (s.psbt.inputs.length + 1)
    return { s with psbt := { s.psbt with inputs := s.psbt.inputs.insertIdx at_ dup } }.note "input repeated"
  | 3 => return (s.updateInput i fun (x : Input) => { x with txid := some 999 }).note "unknown txid"
  | 4 =>
    let d ← pick [1, -1]
    return (s.updateInput i fun (x : Input) => { x with witness := x.witness.map fun (a, sc) => (a + d, sc) }).note "witness amount off by one"
  | 5 => return (s.updateInput i fun (x : Input) => { x with witness := x.witness.map fun (a, _) => (a, .foreign 40) }).note "witness script foreign"
  | 6 => return (s.updateInput i fun (x : Input) => { x with witness := none }).note "witness absent"
  | 7 =>
    let s := s.updateCoinOf i fun (k : Coin) => { k with script := .foreign 41 }
    return (s.updateInput i fun (x : Input) => { x with witness := x.witness.map fun (a, _) => (a, .foreign 41) }).note "known coin script foreign"
  | 8 =>
    let a ← pick [0, -1, maxMoney + 1, maxMoney]
    let s := s.updateCoinOf i fun (k : Coin) => { k with amount := a }
    return (s.updateInput i fun (x : Input) => { x with witness := x.witness.map fun (_, sc) => (a, sc) }).note "known coin amount at a bound"
  | 9 =>
    let d ← pick [100, 99, 98, 97]
    return (s.updateCoinOf i fun (k : Coin) => { k with coinbase := true, height := s.tip + 1 - min d s.tip }).note "coinbase near maturity"
  | 10 =>
    let v ← pick [1, 2, 3, 0x81, 0x82, 0x83, 0xFF, 0x100, 0xFFFF_FFFF]
    return (s.updateInput i fun (x : Input) => { x with sighash := some v }).note "hash type"
  | 11 =>
    let key ← (do
      match (s.psbt.inputs.getD i default).internalKey with
      | some (.internal c n) => pick [some (Key.internal c (n + 1)), some (Key.internal (1 - c) n), some (.foreign 7), some (.foreign 8), none]
      | _ => pick [some (Key.foreign 7), none])
    return (s.updateInput i fun (x : Input) => { x with internalKey := key }).note "internal key"
  | 12 => return (s.updateInput i fun (x : Input) => { x with leaves := x.leaves.drop 1 }).note "leaf dropped"
  | 13 => do
    let extra ← pick [Leaf.foreign 3, Leaf.foreign 4]
    return (s.updateInput i fun (x : Input) => { x with leaves := x.leaves ++ [extra] }).note "foreign leaf added"
  | 14 =>
    -- A PSBT keys leaves by control block, so a leaf cannot appear twice;
    -- replacing one is the nearest representable change.
    return (s.updateInput i fun (x : Input) => { x with leaves := x.leaves.drop 1 ++ [.foreign 5] }).note "leaf replaced"
  | 15 =>
    return (s.updateInput i fun (x : Input) => { x with leaves := x.leaves.map fun
      | .signers c n => .signers c (n + 1)
      | .recovery c n => .recovery c (n + 1)
      | l => l }).note "leaves of another coordinate"
  | 16 =>
    -- A recovery leaf in the signers' slot, or a plain account's leaves on
    -- a recovery account.
    return (s.updateInput i fun (x : Input) => { x with leaves := x.leaves.filterMap fun
      | .signers c n => if s.account.recovery.isSome then some (.recovery c n) else some (.signers c n)
      | .recovery _ _ => none
      | l => some l }).note "leaf kinds changed"
  | 17 =>
    let v ← pick [0, b - 1, b, b + 1, 0xFFFF_FFFF, b ||| (1 <<< 22), b ||| (1 <<< 31), 65535, ← below (2 ^ 32)]
    return (s.updateInput i fun (x : Input) => { x with sequence := some v }).note "sequence"
  | 18 =>
    return { s with psbt := { s.psbt with inputs := s.psbt.inputs.map fun (x : Input) => { x with sequence := some b } } }.note "every sequence at the lock"
  | 19 =>
    let v ← pick [0, 1, 3, -1, 0x7FFF_FFFF, -0x8000_0000]
    return { s with psbt := { s.psbt with txVersion := v } }.note "tx version"
  | 20 =>
    let a ← pick [some 0, some (-1), some (maxMoney + 1), none, some maxMoney]
    return (s.updateOutput j fun (o : Output) => { o with amount := a }).note "output amount at a bound"
  | 21 =>
    let sc ← pick [some Script.empty, none, some (.foreign 9), some (.account 0 (← below 5)), some (.account 1 (← below 5))]
    return (s.updateOutput j fun (o : Output) => { o with script := sc }).note "output script"
  | 22 =>
    -- The fee exactly at, just under and just over the ceiling.
    let d ← pick [-1, 0, 1]
    let fee := s.inputTotal / 10 + d
    let others := s.outputTotal - (s.psbt.outputs.getD 0 default).amount.getD 0
    return (s.updateOutput 0 fun (o : Output) => { o with amount := some (s.inputTotal - fee - others) }).note "fee at the ceiling"
  | 23 =>
    let fee := s.inputTotal - s.outputTotal + (← pick [0, 1])
    return (s.updateOutput j fun (o : Output) => { o with amount := o.amount.map (· + fee) }).note "outputs reach the inputs"
  | 24 => return { s with psbt := { s.psbt with outputs := [] } }.note "no outputs"
  | 25 => return { s with psbt := { s.psbt with inputs := [] } }.note "no inputs"
  | 26 =>
    let c ← pick [(1, 2 ^ 31 + 3), (0, 2 ^ 32 - 1), ((1 : Int), 2 ^ 31)]
    return { s with coords := s.coords ++ [c] }.note "underivable output coordinate"
  | 27 => return { s with coords := [] }.note "no output coordinates"
  | 28 => return { s with coords := s.coords ++ [(2, 0), (-1, 0), (7, 1)] }.note "out-of-range choices"
  | 29 =>
    -- The recovery unlock boundary for this input's coin.
    let k := (s.psbt.inputs.getD i default).txid.bind fun t => s.known.find? (·.txid == t)
    match k with
    | some k => return { s with tip := k.height + b - 1 - (← pick [0, 1, 2]) }.note "tip at the unlock boundary"
    | none => return s
  | 30 => return (s.updateCoinOf i fun (k : Coin) => { k with height := 0 }).note "unconfirmed coin"
  | 31 =>
    let d ← between 1 3
    return (s.updateCoinOf i fun (k : Coin) => { k with height := s.tip + d }).note "coin above the tip"
  | 32 =>
    -- Heights at the top of UInt32.
    let h := 2 ^ 32 - 1 - (← below 120)
    let coinbase ← pick [true, false]
    let s := s.updateCoinOf i fun (k : Coin) => { k with height := h, coinbase }
    return { s with tip := ← pick [h - 1, h, 2 ^ 32 - 1, s.tip] }.note "heights at the top of UInt32"
  | 33 =>
    if s.psbt.inputs.length < 2 then return s
    let a := maxMoney / 2 + 1
    let s := (s.updateCoinOf 0 fun k => { k with amount := a }).updateCoinOf 1 fun k => { k with amount := a }
    let s := (s.updateInput 0 fun x => { x with witness := x.witness.map fun (_, sc) => (a, sc) }).updateInput 1
      fun x => { x with witness := x.witness.map fun (_, sc) => (a, sc) }
    return s.note "inputs past the supply"
  | 34 =>
    match (s.psbt.inputs.getD i default) with
    | { txid := some t, vout := some v, .. } =>
      let decoy : Coin := { (s.known.find? (fun k => k.txid == t && k.vout == v)).getD default with amount := 777 }
      return { s with known := decoy :: s.known }.note "decoy coin first"
    | _ => return s
  | 35 =>
    let n ← pick [2 ^ 31, 2 ^ 31 + 1, 2 ^ 32 - 1]
    return (s.updateCoinOf i fun (k : Coin) => { k with index := n }).note "coin index past 2^31"
  | 36 =>
    return (s.updateCoinOf i fun (k : Coin) => { k with chain := if k.chain = .receive then .change else .receive }).note "coin chain flipped"
  | 37 => return { s with psbt := { s.psbt with inputs := ← shuffle s.psbt.inputs } }.note "inputs reordered"
  | 38 => return (s.updateInput i fun (x : Input) => { x with vout := x.vout.map (· + 1) }).note "vout off by one"
  | 39 => return (s.updateInput i fun (x : Input) => { x with sighash := none }).note "hash type absent"
  | 40 =>
    let a := maxMoney / 2 + 1
    return { s with psbt := { s.psbt with outputs := s.psbt.outputs ++ [(⟨some a, some (.foreign 5)⟩ : Output), (⟨some a, some (.foreign 6)⟩ : Output)] } }.note "outputs past the supply"
  | _ => return { s with tip := ← pick [0, 1, s.tip + 1000] }.note "tip moved"

/-- Keeps every number inside the Swift type that carries it: heights, the
tip and indices in `UInt32`. -/
def Scenario.fit (s : Scenario) : Scenario :=
  let top := 2 ^ 32 - 1
  { s with tip := min s.tip top,
           known := s.known.map fun k => { k with height := min k.height top, index := min k.index top } }

def scenario : Gen Scenario := do
  let mut s ← baseScenario
  let count ← pick [0, 1, 1, 1, 2, 2, 3]
  for _ in [0:count] do
    s ← mutate s
  return s.fit

/-! ## JSON -/

def jsonString (s : String) : String := "\"" ++ s ++ "\""

def Script.json : Script → String
  | .account c i => jsonString s!"a{c}/{i}"
  | .foreign n => jsonString s!"f{n}"
  | .empty => jsonString "e"

def Key.json : Key → String
  | .internal c i => jsonString s!"i{c}/{i}"
  | .foreign n => jsonString s!"f{n}"

def Leaf.json : Leaf → String
  | .signers c i => jsonString s!"s{c}/{i}"
  | .recovery c i => jsonString s!"r{c}/{i}"
  | .foreign n => jsonString s!"f{n}"

def jsonList (xs : List String) : String := "[" ++ ",".intercalate xs ++ "]"

def jsonObject (fields : List (String × String)) : String :=
  "{" ++ ",".intercalate (fields.map fun (k, v) => jsonString k ++ ":" ++ v) ++ "}"

/-- An absent field, or one present with bytes that do not decode. Review
reads both as nil, so the model does not tell them apart. -/
def missing : Gen String := do
  return if ← chance 1 3 then jsonString "malformed" else "null"

def optional {α} (f : α → String) : Option α → Gen String
  | some a => return f a
  | none => missing

def Coin.json (k : Coin) : String :=
  jsonObject [("txid", toString k.txid), ("vout", toString k.vout), ("amount", toString k.amount),
    ("script", k.script.json), ("chain", toString k.chain.toNat), ("index", toString k.index),
    ("height", toString k.height), ("coinbase", toString k.coinbase)]

def Input.json (x : Input) : Gen String := do
  return jsonObject [
    ("txid", ← optional toString x.txid), ("vout", ← optional toString x.vout),
    ("sequence", ← optional toString x.sequence), ("sighash", ← optional toString x.sighash),
    ("witness", ← optional (fun (a, s) => jsonObject [("amount", toString a), ("script", s.json)]) x.witness),
    ("internalKey", match x.internalKey with | some k => k.json | none => "null"),
    ("leaves", jsonList (x.leaves.map Leaf.json))]

def Output.json (o : Output) : Gen String := do
  return jsonObject [("amount", ← optional toString o.amount),
    ("script", match o.script with | some s => s.json | none => "null")]

def Reason.json : Reason → String
  | .noInputs => jsonObject [("reason", jsonString "noInputs")]
  | .outputCount => jsonObject [("reason", jsonString "outputCount")]
  | .txVersion => jsonObject [("reason", jsonString "txVersion")]
  | .psbtField => jsonObject [("reason", jsonString "psbtField")]
  | .incompleteOutpoint i => jsonObject [("reason", jsonString "incompleteOutpoint"), ("at", toString i)]
  | .repeatedOutpoint i => jsonObject [("reason", jsonString "repeatedOutpoint"), ("at", toString i)]
  | .unknownCoin i => jsonObject [("reason", jsonString "unknownCoin"), ("at", toString i)]
  | .wrongAmountOrScript i => jsonObject [("reason", jsonString "wrongAmountOrScript"), ("at", toString i)]
  | .immatureCoinbase i => jsonObject [("reason", jsonString "immatureCoinbase"), ("at", toString i)]
  | .notThisDescriptor i => jsonObject [("reason", jsonString "notThisDescriptor"), ("at", toString i)]
  | .sighash i => jsonObject [("reason", jsonString "sighash"), ("at", toString i)]
  | .policy i => jsonObject [("reason", jsonString "policy"), ("at", toString i)]
  | .recoveryLocked i => jsonObject [("reason", jsonString "recoveryLocked"), ("at", toString i)]
  | .inputSupply => jsonObject [("reason", jsonString "inputSupply")]
  | .candidates => jsonObject [("reason", jsonString "candidates")]
  | .invalidOutput j => jsonObject [("reason", jsonString "invalidOutput"), ("at", toString j)]
  | .outputSupply => jsonObject [("reason", jsonString "outputSupply")]
  | .outputsExceedInputs => jsonObject [("reason", jsonString "outputsExceedInputs")]
  | .feeCeiling => jsonObject [("reason", jsonString "feeCeiling")]
  | .derivation => jsonObject [("reason", jsonString "derivation")]

def Reason.name (r : Reason) : String :=
  match r with
  | .noInputs => "noInputs" | .outputCount => "outputCount" | .txVersion => "txVersion"
  | .psbtField => "psbtField" | .incompleteOutpoint _ => "incompleteOutpoint"
  | .repeatedOutpoint _ => "repeatedOutpoint" | .unknownCoin _ => "unknownCoin"
  | .wrongAmountOrScript _ => "wrongAmountOrScript" | .immatureCoinbase _ => "immatureCoinbase"
  | .notThisDescriptor _ => "notThisDescriptor" | .sighash _ => "sighash" | .policy _ => "policy"
  | .recoveryLocked _ => "recoveryLocked" | .inputSupply => "inputSupply" | .candidates => "candidates"
  | .invalidOutput _ => "invalidOutput" | .outputSupply => "outputSupply"
  | .outputsExceedInputs => "outputsExceedInputs" | .feeCeiling => "feeCeiling" | .derivation => "derivation"

def Review.json (r : Review) : String :=
  jsonObject [
    ("outputs", jsonList (r.outputs.map fun o => jsonList [toString o.amount, o.script.json, toString o.owned])),
    ("inputTotal", toString r.inputTotal), ("outputTotal", toString r.outputTotal), ("fee", toString r.fee),
    ("path", jsonString (if r.path = .recovery then "recovery" else "signers"))]

def Scenario.json (s : Scenario) (id : Nat) : Gen String := do
  let expected := match review s.account s.psbt s.known s.coords s.tip with
    | .ok r => jsonObject [("accept", r.json)]
    | .error e => jsonObject [("reject", e.json)]
  let inputs ← s.psbt.inputs.mapM Input.json
  let outputs ← s.psbt.outputs.mapM Output.json
  return jsonObject [
    ("id", toString id),
    ("notes", jsonList (s.notes.map jsonString)),
    ("recovery", match s.account.recovery with | some b => toString b | none => "null"),
    ("tip", toString s.tip),
    ("known", jsonList (s.known.map Coin.json)),
    ("coords", jsonList (s.coords.map fun (c, i) => jsonList [toString c, toString i])),
    ("psbt", jsonObject [("version", toString s.psbt.txVersion), ("inputs", jsonList inputs), ("outputs", jsonList outputs)]),
    ("expect", expected)]

/-- Hand-built cases the random mix reaches rarely or never: the 1,000
output and 1,024 candidate bounds. -/
def boundaryScenarios : Gen (List Scenario) := do
  let base ← baseScenario
  let coin : Coin := { txid := 1, vout := 0, amount := 10_000_000, script := .account 0 0, chain := .receive,
                       index := 0, height := base.tip - 10, coinbase := false }
  let input : Input := { txid := some 1, vout := some 0, sequence := some 0xFFFF_FFFD, sighash := some 0,
                         witness := some (coin.amount, coin.script), internalKey := some (.internal 0 0),
                         leaves := base.account.expectedLeaves 0 0 }
  let pay (n : Nat) : List Output := (List.range n).map fun k => ⟨some 9_000, some (.foreign (k % 6 + 1))⟩
  let plain (outs : List Output) (coords : List (Int × Nat)) (note : String) : Scenario :=
    { account := base.account, known := [coin], coords, tip := base.tip,
      psbt := { txVersion := 2, inputs := [input], outputs := outs }, notes := [note] }
  return [
    plain (pay 1000) [(1, 0)] "1,000 outputs",
    plain (pay 1001) [(1, 0)] "1,001 outputs",
    plain (pay 1) ((List.range 1025).map fun k => ((1 : Int), k)) "1,025 candidate coordinates",
    plain (pay 1) ((List.range 2000).map fun _ => ((1 : Int), 0)) "2,000 copies of one coordinate",
    plain (pay 1) ((List.range 1025).map fun k => if k % 2 = 0 then ((2 : Int), k) else (1, 0))
      "1,025 entries, one candidate",
    -- A locked recovery spend whose unlock block would be past UInt32's top.
    let top := 2 ^ 32 - 1
    let coin := { coin with height := top - 4 }
    { account := ⟨some 10⟩, known := [coin], coords := [], tip := top,
      psbt := { txVersion := 2, inputs := [{ input with sequence := some 10, leaves := Account.expectedLeaves ⟨some 10⟩ 0 0 }],
                outputs := pay 1 }, notes := ["recovery unlock past the top height"] }]

end SpendReview
