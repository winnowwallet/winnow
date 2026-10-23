/-!
# The multisig spend review, as a specification

An executable model of `MultisigAccount.reviewSpend`
(`Sources/WalletCore/Wallet/MultisigAccount.swift`) and the pieces it calls:
`spendPath`, `checkInput`, `reviewedInputTotal`, `reviewedOutputs`, the fee
ceiling, `isUnlockedForRecovery`, `RelativeLock.isSatisfied` and the parts of
`PSBT.unsignedTransaction` that `spendPath` reads.

Bytes are abstracted. A script, an internal key or a tap leaf is named by
where it came from (the account at a coordinate, or something foreign), and
the Swift harness turns each name into the real bytes. Two names are equal
exactly when the bytes are, which is the one modelling assumption: distinct
coordinates derive distinct scripts, keys and leaves, and nothing foreign
collides with them.

Integers are mathematical. Where the Swift computes in `UInt32` or `Int64`,
the model computes the value the code means, so a Swift overflow trap shows
up as a disagreement rather than being copied into the specification.
-/

namespace SpendReview

/-- The chain of a coordinate: `AddressChain` in the Swift. -/
inductive Chain where
  | receive
  | change
  deriving DecidableEq, Repr, Inhabited

def Chain.toNat : Chain → Nat
  | .receive => 0
  | .change => 1

/-- A scriptPubKey. -/
inductive Script where
  /-- The account's script at (choice, index). -/
  | account (choice index : Nat)
  /-- Any script the account does not derive. -/
  | foreign (tag : Nat)
  /-- The empty script. -/
  | empty
  deriving DecidableEq, Repr, Inhabited

/-- A PSBT_IN_TAP_INTERNAL_KEY value. -/
inductive Key where
  /-- The account's internal key at (choice, index). -/
  | internal (choice index : Nat)
  /-- Any other value, including one of the wrong length. -/
  | foreign (tag : Nat)
  deriving DecidableEq, Repr, Inhabited

/-- A PSBT_IN_TAP_LEAF_SCRIPT entry: control block, script and leaf version. -/
inductive Leaf where
  /-- The account's signers' leaf at (choice, index). -/
  | signers (choice index : Nat)
  /-- The account's recovery leaf at (choice, index). -/
  | recovery (choice index : Nat)
  /-- Any other leaf. -/
  | foreign (tag : Nat)
  deriving DecidableEq, Repr, Inhabited

/-- A known coin of the account: `WalletUTXO`. -/
structure Coin where
  txid : Nat
  vout : Nat
  amount : Int
  script : Script
  chain : Chain
  index : Nat
  height : Nat
  coinbase : Bool
  deriving DecidableEq, Repr, Inhabited

/-- A PSBT input as review reads it. `none` is a field that is absent or
does not decode; the Swift getters return nil for both. -/
structure Input where
  txid : Option Nat
  vout : Option Nat
  sequence : Option Nat
  sighash : Option Nat
  witness : Option (Int × Script)
  internalKey : Option Key
  leaves : List Leaf
  deriving DecidableEq, Repr, Inhabited

/-- A PSBT output. `amount` and `script` are what review reads;
`claimsChange` is whether the PSBT also carries BIP371 metadata (an internal
key and key origins) saying the output is the account's change, which
review must ignore (SEC-004). -/
structure Output where
  amount : Option Int
  script : Option Script
  claimsChange : Bool := false
  deriving DecidableEq, Repr, Inhabited

structure Psbt where
  txVersion : Int
  inputs : List Input
  outputs : List Output
  deriving DecidableEq, Repr, Inhabited

/-- The account, as far as review depends on it: whether it has a recovery
leaf and, if so, its relative lock in blocks. -/
structure Account where
  recovery : Option Nat
  deriving DecidableEq, Repr, Inhabited

inductive Path where
  | signers
  | recovery
  deriving DecidableEq, Repr, Inhabited

/-- One line of the review screen: `SpendReview.Output`. -/
structure Shown where
  amount : Int
  script : Script
  owned : Bool
  deriving DecidableEq, Repr, Inhabited

/-- What review shows: `SpendReview`. -/
structure Review where
  outputs : List Shown
  inputTotal : Int
  outputTotal : Int
  fee : Int
  path : Path
  deriving DecidableEq, Repr, Inhabited

/-- Why review refused. Input and output positions count from 0. -/
inductive Reason where
  | noInputs
  | outputCount
  | txVersion
  /-- `PSBT.unsignedTransaction` found a missing field (recovery accounts
  read it first, in `spendPath`). -/
  | psbtField
  | incompleteOutpoint (input : Nat)
  | repeatedOutpoint (input : Nat)
  | unknownCoin (input : Nat)
  | wrongAmountOrScript (input : Nat)
  | immatureCoinbase (input : Nat)
  | notThisDescriptor (input : Nat)
  | sighash (input : Nat)
  | policy (input : Nat)
  | recoveryLocked (input : Nat)
  | inputSupply
  | candidates
  | invalidOutput (output : Nat)
  | outputSupply
  | outputsExceedInputs
  | feeCeiling
  /-- Key derivation failed: a non-hardened step at an index of 2^31 or more. -/
  | derivation
  deriving DecidableEq, Repr, Inhabited

/-- Bitcoin's supply cap in satoshis. -/
def maxMoney : Int := 2_100_000_000_000_000

def coinbaseMaturity : Nat := 100

/-- `RelativeLock.isSatisfied`: BIP68/BIP112, block-based only. -/
def lockMet (blocks sequence : Nat) (txVersion : Int) : Bool :=
  !blocks.testBit 31 && !blocks.testBit 22 &&
  decide (2 ≤ txVersion) && !sequence.testBit 31 && !sequence.testBit 22 &&
  decide (blocks % 65536 ≤ sequence % 65536)

/-- The sequence an input carries: BIP370's default when the field is absent. -/
def Input.seq (i : Input) : Nat := i.sequence.getD 0xFFFF_FFFF

/-- Deriving the account's script at (choice, index). Every step after the
origin is non-hardened, so an index of 2^31 or more cannot be derived from
the public keys. -/
def derive (choice index : Nat) : Except Reason Script :=
  if index < 2 ^ 31 then .ok (.account choice index) else .error .derivation

/-- The leaves the account has at (choice, index). -/
def Account.expectedLeaves (a : Account) (choice index : Nat) : List Leaf :=
  .signers choice index :: (if a.recovery.isSome then [.recovery choice index] else [])

/-- `isUnlockedForRecovery`: confirmed at least `blocks` blocks below the
next block. -/
def Account.unlocked (a : Account) (k : Coin) (tip : Nat) : Bool :=
  match a.recovery with
  | none => false
  | some blocks => decide (0 < k.height) && decide (k.height ≤ tip) && decide (blocks ≤ tip - k.height + 1)

/-- `spendPath`. A recovery account reads the unsigned transaction first, so
a missing outpoint field or output field is a PSBT error there; then the
recovery path is taken when every input's sequence meets the lock. -/
def spendPath (a : Account) (p : Psbt) : Except Reason Path :=
  match a.recovery with
  | none => .ok .signers
  | some blocks =>
    if p.inputs.any (fun i => i.txid.isNone || i.vout.isNone) then .error .psbtField
    else if p.outputs.any (fun o => o.amount.isNone || o.script.isNone) then .error .psbtField
    else if p.inputs.all (fun i => lockMet blocks i.seq p.txVersion) then .ok .recovery
    else .ok .signers

/-- The first known coin at an outpoint. -/
def findCoin (known : List Coin) (txid vout : Nat) : Option Coin :=
  known.find? (fun k => k.txid == txid && k.vout == vout)

/-- `checkInput`: amount and script against the known coin, coinbase
maturity, the coin's own derivation, a hash type that commits to every
output, and the account's internal key and leaves. -/
def checkInput (a : Account) (tip : Nat) (k : Coin) (inp : Input) (i : Nat) : Except Reason Unit :=
  if ¬(0 < k.amount ∧ k.amount ≤ maxMoney ∧ inp.witness = some (k.amount, k.script)) then
    .error (.wrongAmountOrScript i)
  else if k.coinbase ∧ tip < k.height + coinbaseMaturity - 1 then
    .error (.immatureCoinbase i)
  else match derive k.chain.toNat k.index with
    | .error e => .error e
    | .ok s =>
      if s ≠ k.script then .error (.notThisDescriptor i)
      else if ¬(inp.sighash.getD 0 = 0 ∨ inp.sighash.getD 0 = 1) then .error (.sighash i)
      else if ¬(inp.internalKey = some (.internal k.chain.toNat k.index) ∧
                 inp.leaves.isPerm (a.expectedLeaves k.chain.toNat k.index)) then
        .error (.policy i)
      else .ok ()

/-- `reviewedInputTotal`: every input in order, returning the coin each one
spends and the running total. `seen` holds the outpoints already spent. -/
def reviewInputs (a : Account) (known : List Coin) (tip : Nat) (path : Path) :
    List Input → (index : Nat) → (seen : List (Nat × Nat)) → (total : Int) →
    Except Reason (List Coin × Int)
  | [], _, _, total => .ok ([], total)
  | inp :: rest, i, seen, total =>
    match inp.txid, inp.vout with
    | some t, some v =>
      if (t, v) ∈ seen then .error (.repeatedOutpoint i)
      else match findCoin known t v with
        | none => .error (.unknownCoin i)
        | some k =>
          match checkInput a tip k inp i with
          | .error e => .error e
          | .ok () =>
            if path = .recovery ∧ a.unlocked k tip = false then .error (.recoveryLocked i)
            else if maxMoney < total + k.amount then .error .inputSupply
            else match reviewInputs a known tip path rest (i + 1) ((t, v) :: seen) (total + k.amount) with
              | .error e => .error e
              | .ok (coins, sum) => .ok (k :: coins, sum)
    | _, _ => .error (.incompleteOutpoint i)

/-- The coordinates review may count as the account's own: choice 0 or 1. -/
def candidateCoordinates (coords : List (Int × Nat)) : List (Int × Nat) :=
  coords.filter (fun c => decide (0 ≤ c.1 ∧ c.1 ≤ 1))

/-- Distinct elements, for the 1,024-candidate bound (a `Set` in the Swift). -/
def distinct {α} [DecidableEq α] : List α → List α
  | [] => []
  | x :: xs => if x ∈ xs then distinct xs else x :: distinct xs

/-- The scripts of the candidate coordinates. -/
def deriveAll : List (Int × Nat) → Except Reason (List Script)
  | [] => .ok []
  | c :: cs =>
    match derive c.1.toNat c.2 with
    | .error e => .error e
    | .ok s =>
      match deriveAll cs with
      | .error e => .error e
      | .ok ss => .ok (s :: ss)

/-- `reviewedOutputs`: every output in order with its ownership, and the
running total. -/
def reviewOutputs (owned : List Script) : List Output → (index : Nat) → (total : Int) →
    Except Reason (List Shown × Int)
  | [], _, total => .ok ([], total)
  | o :: rest, j, total =>
    match o.amount, o.script with
    | some amount, some script =>
      if amount ≤ 0 ∨ maxMoney < amount ∨ script = .empty then .error (.invalidOutput j)
      else if maxMoney < total + amount then .error .outputSupply
      else match reviewOutputs owned rest (j + 1) (total + amount) with
        | .error e => .error e
        | .ok (shown, sum) => .ok (⟨amount, script, decide (script ∈ owned)⟩ :: shown, sum)
    | _, _ => .error (.invalidOutput j)

/-- `reviewSpend`. -/
def review (a : Account) (p : Psbt) (known : List Coin) (coords : List (Int × Nat)) (tip : Nat) :
    Except Reason Review :=
  if p.inputs = [] then .error .noInputs
  else if p.outputs = [] ∨ 1000 < p.outputs.length then .error .outputCount
  else if ¬(p.txVersion = 1 ∨ p.txVersion = 2) then .error .txVersion
  else match spendPath a p with
    | .error e => .error e
    | .ok path =>
      match reviewInputs a known tip path p.inputs 0 [] 0 with
      | .error e => .error e
      | .ok (_, inputTotal) =>
        let candidates := candidateCoordinates coords
        if 1024 < (distinct candidates).length then .error .candidates
        else match deriveAll candidates with
          | .error e => .error e
          | .ok owned =>
            match reviewOutputs owned p.outputs 0 0 with
            | .error e => .error e
            | .ok (shown, outputTotal) =>
              if inputTotal < outputTotal then .error .outputsExceedInputs
              else if inputTotal / 10 < inputTotal - outputTotal then .error .feeCeiling
              else .ok ⟨shown, inputTotal, outputTotal, inputTotal - outputTotal, path⟩

end SpendReview
