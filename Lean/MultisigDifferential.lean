import Winnow
import Lean.Data.Json

/-! `multisig-differential`: the Lean port of upstream's `winnow-fixture multisig-differential`
(Tools/Fixture/MultisigDifferential.swift, run by scripts/check-multisig-core at 1cf93fb): Winnow's Taproot
script-path multisig (`MultisigAccount`) held to Bitcoin Core on a disposable regtest node.

The node is started here (temp datadir, random ports, `bitcoind -regtest`) and killed at
the end, also on failure. Seeded cases vary the threshold, the number of signers (two to five), which
signers are Bitcoin Core wallets (keys Core generated, signing through `walletprocesspsbt` with its own
libsecp256k1), the order the signers are listed in, and the recovery leaf (none, fewer of the same signers,
or separate keys, after a delay). For every case Core must agree with Winnow on:

* the descriptor checksum and the first four receive and change addresses, and that listing the signers,
  or a recovery leaf's separate keys, in another order builds the same descriptor;
* which signers a PSBT carries valid signatures from, Core's included;
* every subset of exactly k signers, each signing in a shuffled order: Winnow finalizes, Core's mempool
  accepts it, and Core's own finalizer produces the same bytes; with k + 1 signers both finish and Core
  accepts Winnow's k-signature witness; with k − 1 neither finishes; one spend is mined;
* the recovery leaf, for delays of one to four blocks: every subset of its threshold, refused by Core
  (`non-BIP68-final`) and by Winnow's unlock rule one block before the lock opens and accepted by both in
  the block it opens; one key fewer finishing on neither side unless the same people also complete the
  signers' leaf; the signers' leaf finishing a spend that carries the recovery sequence (BIP326); one
  recovery spend is mined.

The case generator draws from the same SplitMix64 sequence in the same order as the Swift one, so a seed
names the same case shapes (Core's keys differ per node). Differences: the signers' spend uses the
locktime-at-tip draw and the change goes last (Swift draws both at random); a disagreement is recorded with
seed and case and the run continues. Usage: `multisig-differential [--seed HEX] [--cases N]`. Exit 1 on any
disagreement. -/

open Winnow Keys Lean
open MultisigAccount (OutputCoordinate SpendPath RecoveryPlan)

/-- A Bitcoin Core binary: `$WINNOW_BITCOIND` / `$WINNOW_BITCOIN_CLI`, else Homebrew's, else the PATH. -/
def findTool (env name : String) : IO String := do
  if let some path := (← IO.getEnv env) then return path
  for dir in ["/opt/homebrew/bin", "/usr/local/bin"] do
    if ← System.FilePath.pathExists s!"{dir}/{name}" then return s!"{dir}/{name}"
  return name

initialize bitcoind : String ← findTool "WINNOW_BITCOIND" "bitcoind"
initialize bitcoinCli : String ← findTool "WINNOW_BITCOIN_CLI" "bitcoin-cli"

def say (s : String) : IO Unit := do IO.println s; (← IO.getStdout).flush

/-! ## The tally -/

initialize agreed : IO.Ref (Array (String × Nat)) ← IO.mkRef #[]
initialize disagreements : IO.Ref (Array String) ← IO.mkRef #[]

def tally (agrees : Bool) (kind : String) (detail : String) : IO Unit := do
  if agrees then
    agreed.modify fun a => match a.findIdx? (·.1 == kind) with
      | some j => a.modify j fun (k, n) => (k, n + 1)
      | none => a.push (kind, 1)
  else
    disagreements.modify (·.push s!"{kind}: {detail}")
    say s!"  DISAGREE {kind}: {detail}"

/-! ## The node -/

structure Node where
  datadir : String
  rpc : UInt16
  pid : UInt32

initialize nodeRef : IO.Ref (Option Node) ← IO.mkRef none

def node : IO Node := do
  let some n ← nodeRef.get | throw (IO.userError "no node")
  return n

def cli (args : Array String) (wallet : Option String := none) : IO String := do
  let n ← node
  let w := match wallet with | some w => #[s!"-rpcwallet={w}"] | none => #[]
  let out ← IO.Process.output
    { cmd := bitcoinCli, args := #["-regtest", s!"-datadir={n.datadir}", s!"-rpcport={n.rpc}"] ++ w ++ args }
  if out.exitCode != 0 then throw (IO.userError s!"bitcoin-cli {args}: {out.stderr.trimAscii}")
  return out.stdout.trimAscii.toString

def cliJson (args : Array String) (wallet : Option String := none) : IO Json := do
  match Json.parse (← cli args wallet) with
  | .ok j => return j
  | .error e => throw (IO.userError s!"json {args}: {e}")

def jstr (j : Json) (k : String) : IO String := match j.getObjValAs? String k with
  | .ok s => pure s | .error e => throw (IO.userError s!"{k}: {e}")

def randomU64 : IO UInt64 := do
  let b ← IO.getRandomBytes 8
  return (List.range 8).foldl (fun a i => (a <<< 8) ||| b[i]!.toUInt64) 0

def killPid (pid : UInt32) (signal : String := "-TERM") : IO Unit :=
  discard <| IO.Process.output { cmd := "kill", args := #[signal, toString pid] }

def startNode (dir : String) : IO Node := do
  for attempt in [0:5] do
    let r ← randomU64
    let p2p := (30000 + r.toNat % 25000).toUInt16
    let rpc := p2p + 1
    let datadir := s!"{dir}/node{attempt}"
    IO.FS.createDirAll datadir
    let child ← IO.Process.spawn {
      cmd := bitcoind
      args := #["-regtest", s!"-datadir={datadir}", s!"-port={p2p}", s!"-rpcport={rpc}", "-rpcbind=127.0.0.1", "-rpcallowip=127.0.0.1",
        "-listen=0", "-server=1", "-fallbackfee=0.0002", "-printtoconsole=0", "-dnsseed=0", "-discover=0",
        "-listenonion=0"]
      stdout := .null, stderr := .null, stdin := .null }
    let n : Node := { datadir, rpc, pid := child.pid }
    nodeRef.set (some n)
    let mut ready := false
    for _ in [0:150] do
      IO.sleep 200
      if (← child.tryWait).isSome then break
      match ← (cli #["getblockchaininfo"]).toBaseIO with
      | .ok _ => ready := true; break
      | .error _ => pure ()
    if ready then return n
    killPid child.pid "-KILL"
  throw (IO.userError "bitcoind did not start")

def height : IO UInt32 := do return (← cli #["getblockcount"]).toNat!.toUInt32

def bank := "bank"

def ensureWallet (name : String) : IO Unit := do
  if ((← cli #["listwallets"]).splitOn s!"\"{name}\"").length > 1 then return
  if (← (cli #["loadwallet", name]).toBaseIO).toOption.isSome then return
  discard <| cli #["-named", "createwallet", s!"wallet_name={name}"]

def newAddress (wallet : String) : IO String := cli #["getnewaddress", "", "bech32m"] wallet

def mine (blocks : Nat) : IO Unit := do
  if blocks == 0 then return
  discard <| cli #["generatetoaddress", toString blocks, ← newAddress bank]

def mineTo (target : UInt32) : IO Unit := do
  let current ← height
  if target > current then mine (target - current).toNat

/-- A BTC amount (8 decimals) as exact sats. -/
def sats (j : Json) : IO Int64 := do
  let .num n := j | throw (IO.userError "amount")
  unless n.exponent ≤ 8 do throw (IO.userError "amount precision")
  return Int64.ofInt (n.mantissa * 10 ^ (8 - n.exponent))

def hexOf (s : String) : IO ByteArray := match Wire.dataOfHex? s with
  | some b => pure b | none => throw (IO.userError s!"hex {s}")

def mam {α} (what : String) (r : MAM α) : IO α := match r with
  | .ok a => pure a
  | .error e => throw (IO.userError s!"{what}: {e.name}{match e with | .account a => " (" ++ a.description ++ ")" | _ => ""}")

/-! ## Seeded randomness (`Tests/Support/SeededRandom.swift`, SplitMix64) -/

initialize rngState : IO.Ref UInt64 ← IO.mkRef 0

def next : IO UInt64 := do
  let s := (← rngState.get) + 0x9E37_79B9_7F4A_7C15
  rngState.set s
  let mut v := s
  v := (v ^^^ (v >>> 30)) * 0xBF58_476D_1CE4_E5B9
  v := (v ^^^ (v >>> 27)) * 0x94D0_49BB_1331_11EB
  return v ^^^ (v >>> 31)

/-- A draw in `0 ..< max(upperBound, 1)`. -/
def count (upperBound : Nat) : IO Nat := do return ((← next) % (max upperBound 1).toUInt64).toNat

/-- A draw inside `lo … hi`. -/
def drawInt (lo hi : Nat) : IO Nat := do return lo + ((← next) % (hi - lo + 1).toUInt64).toNat

def shuffle {α} (xs : Array α) : IO (Array α) := do
  let mut v := xs
  if v.size ≤ 1 then return v
  let mut i := v.size - 1
  while i > 0 do
    let j ← count (i + 1)
    v := v.swapIfInBounds i j
    i := i - 1
  return v

def combinations : List Nat → Nat → List (List Nat)
  | _, 0 => [[]]
  | [], _ + 1 => []
  | x :: rest, k + 1 => (combinations rest k).map (x :: ·) ++ combinations rest (k + 1)

/-! ## Signers -/

def hex8 (n : UInt32) : String := Descriptor.hex8 n

def keyExpressionOf (master : HDKey) : IO String := do
  let account ← match master.derived "m/86'/1'/0'" with
    | .ok k => pure k | .error e => throw (IO.userError e.name)
  return s!"[{hex8 master.fingerprint}/86'/1'/0']{account.neutered.serialized .testnet}/<0;1>/*"

/-- A Bitcoin Core signer: a Core wallet's own tr() account key; Core signs with `walletprocesspsbt`. -/
structure CoreSigner where
  wallet : String
  /-- `[fp/86'/1'/0']tpub…`, without a suffix. -/
  publicExpression : String
  privateExpression : String
  deriving Inhabited

/-- The key expression inside Core's `tr(KEY/0/*)`, through Winnow's parser and serializer. -/
def coreKeyExpression (text : String) : IO String := do
  let d ← match Descriptor.parse text with
    | .ok d => pure d.serialized | .error e => throw (IO.userError s!"Core descriptor: {e.name}")
  let some open_ := d.toList.idxOf? '(' | throw (IO.userError "unparsable Core descriptor")
  let close := d.length - 1 - (d.toList.reverse.idxOf ')')
  let inner := String.ofList ((d.toList.drop (open_ + 1)).take (close - open_ - 1))
  unless inner.endsWith "/0/*" do throw (IO.userError "unexpected Core key path")
  return String.ofList (inner.toList.take (inner.length - 4))

def CoreSigner.make (wallet : String) : IO CoreSigner := do
  if (← (cli #["loadwallet", wallet]).toBaseIO).toOption.isNone then
    discard <| (cli #["-named", "createwallet", s!"wallet_name={wallet}"]).toBaseIO
  let descriptor (isPrivate : Bool) : IO String := do
    let listed ← cliJson #["listdescriptors", if isPrivate then "true" else "false"] wallet
    let entries ← match listed.getObjValAs? (Array Json) "descriptors" with
      | .ok a => pure a | .error e => throw (IO.userError e)
    let some entry := entries.find? fun e =>
        ((e.getObjValAs? String "desc").toOption.getD "").startsWith "tr(" &&
          !((e.getObjValAs? Bool "internal").toOption.getD false)
      | throw (IO.userError s!"no external tr() descriptor in {wallet}")
    jstr entry "desc"
  return { wallet, publicExpression := ← coreKeyExpression (← descriptor false),
           privateExpression := ← coreKeyExpression (← descriptor true) }

def CoreSigner.signerExpression (c : CoreSigner) : String := c.publicExpression ++ "/<0;1>/*"

/-- Imports the account with Core's own key private, so Core can sign as one of its signers. -/
def CoreSigner.importAccount (c : CoreSigner) (a : MultisigAccount) : IO Unit := do
  let text := (a.descriptor.serialized.splitOn "#")[0]!
  let privateText := text.replace c.publicExpression c.privateExpression
  if privateText == text then throw (IO.userError "Core key absent from the account")
  let checksum ← jstr (← cliJson #["getdescriptorinfo", privateText]) "checksum"
  let request := s!"[\{\"desc\":\"{privateText}#{checksum}\",\"timestamp\":\"now\",\"active\":true,\"range\":[0,5]}]"
  let imported ← cliJson #["importdescriptors", request] c.wallet
  let ok := match imported with
    | .arr xs => (xs[0]?.bind fun x => (x.getObjValAs? Bool "success").toOption) == some true
    | _ => false
  unless ok do throw (IO.userError s!"Core refused the account descriptor: {imported.compress}")

def CoreSigner.process (c : CoreSigner) (p : PSBT) : IO PSBT := do
  let b64 ← match p.base64V0 with | .ok s => pure s | .error e => throw (IO.userError e.name)
  let result ← cliJson #["walletprocesspsbt", b64, "true", "DEFAULT", "true", "false"] c.wallet
  let theirs ← match PSBT.ofBase64 (← jstr result "psbt") with
    | .ok q => pure q | .error e => throw (IO.userError e.name)
  mam "combine" (MultisigAccount.lift (·.name) (p.combined #[theirs]))

inductive Signer where
  | winnow (master : HDKey)
  | core (c : CoreSigner)
  deriving Inhabited

def Signer.expression : Signer → IO String
  | .winnow m => keyExpressionOf m
  | .core c => pure c.signerExpression

def Signer.label : Signer → String | .core _ => "Core" | .winnow _ => "Winnow"

/-- The xpub inside a key expression `[origin]xpub/…`. -/
def extendedKeyIn (expression : String) : String :=
  let afterOrigin := (expression.splitOn "]").getLast!
  (afterOrigin.splitOn "/")[0]!

def Signer.accountKey (s : Signer) : IO String := return extendedKeyIn (← s.expression)

structure Case where
  number : Nat
  threshold : Nat
  signers : Array Signer
  recovery : Option RecoveryPlan
  recoveryMasters : Array HDKey

def Case.summary (c : Case) : String :=
  let who := ",".intercalate (c.signers.toList.map (·.label))
  let leaf := match c.recovery with
    | none => "no recovery"
    | some (.fewerSigners m b) => s!"recovery {m} of the signers after {b}"
    | some (.separateKeys m ks b) => s!"recovery {m} of {ks.size} other keys after {b}"
  s!"{c.threshold}-of-{c.signers.size} [{who}], {leaf}"

def spendableDelay : UInt32 := 4

def randomMaster : IO HDKey := do
  let mut seed := ByteArray.empty
  for _ in [0:32] do seed := seed.push (← next).toUInt8
  match HDKey.ofSeed seed with | .ok k => pure k | .error e => throw (IO.userError e.name)

def generate (number : Nat) : IO Case := do
  let n := 2 + (← count 4)
  let threshold := 1 + (← count n)
  let coreCount := min (← count 3) n
  let mut signers : Array Signer := #[]
  for i in [0:coreCount] do signers := signers.push (.core (← CoreSigner.make s!"case{number}-core{i}"))
  for _ in [coreCount:n] do signers := signers.push (.winnow (← randomMaster))
  signers ← shuffle signers
  let blocks : UInt32 ← do
    if (← count 10) < 7 then pure (1 + (← count spendableDelay.toNat)).toUInt32
    else pure (#[16, 144, 4_032, 65_535] : Array UInt32)[← count 4]!
  let mut recoveryMasters : Array HDKey := #[]
  let recovery ← match ← count 3 with
    | 0 => pure none
    | 1 => pure (some (RecoveryPlan.fewerSigners (1 + (← count n)) blocks))
    | _ =>
      let k := 1 + (← count 3)
      for _ in [0:k] do recoveryMasters := recoveryMasters.push (← randomMaster)
      let keys ← recoveryMasters.mapM keyExpressionOf
      pure (some (RecoveryPlan.separateKeys (1 + (← count recoveryMasters.size)) keys blocks))
  return { number, threshold, signers, recovery, recoveryMasters }

/-! ## Signing and finalizing -/

def signAs (p : PSBT) (s : Signer) (a : MultisigAccount) (coins : Array WalletUTXO) (owned : Array OutputCoordinate)
    (tip : UInt32) : IO PSBT := do
  match s with
  | .winnow m => mam "sign" (a.sign p m coins owned tip (← IO.getRandomBytes 32))
  | .core c => c.process p

/-- Both finalizers on the same signed PSBT: raw transactions in hex, `none` where a side does not complete. -/
def finalizeBoth (a : MultisigAccount) (p : PSBT) (coins : Array WalletUTXO) (owned : Array OutputCoordinate)
    (tip : UInt32) : IO (Option String × Option String) := do
  let ours := (a.finalizeSpend p coins owned tip).toOption.map fun (_, tx) => hex (tx.serialized true)
  let b64 ← match p.base64V0 with | .ok s => pure s | .error e => throw (IO.userError e.name)
  let result ← cliJson #["finalizepsbt", b64]
  let theirs := if (result.getObjValAs? Bool "complete").toOption == some true then
    (result.getObjValAs? String "hex").toOption else none
  return (ours, theirs)

def mempoolVerdict (txHex : String) : IO (Bool × String) := do
  let results ← cliJson #["testmempoolaccept", s!"[\"{txHex}\"]"]
  let first := match results with | .arr xs => xs[0]?.getD Json.null | _ => Json.null
  return ((first.getObjValAs? Bool "allowed").toOption == some true, (first.getObjValAs? String "reject-reason").toOption.getD "")

def broadcastAndMine (txHex label : String) : IO Unit := do
  let txid ← cli #["sendrawtransaction", txHex]
  mine 1
  let block ← cliJson #["getblock", ← cli #["getbestblockhash"], "1"]
  let mined := match block.getObjValAs? (Array String) "tx" with
    | .ok txs => txs.contains txid | .error _ => false
  tally mined "mined" s!"{label}: {txid} is not in the next block"

def newScript : IO ByteArray := do
  let info ← cliJson #["getaddressinfo", ← newAddress bank] bank
  hexOf (← jstr info "scriptPubKey")

def satsText (v : Nat) : String :=
  let frac := toString (v % 100_000_000)
  s!"{v / 100_000_000}.{String.ofList (List.replicate (8 - frac.length) '0')}{frac}"

/-- Pays each receive index of `a` from the bank, mines the payments, returns them as account coins. -/
def fund (a : MultisigAccount) (indices : Array UInt32) : IO (Array WalletUTXO) := do
  for index in indices do
    let amount := 80_000 + (← drawInt 0 120_000)
    discard <| cli #["-named", "sendtoaddress", s!"address={← mam "address" (a.address index)}",
      s!"amount={satsText amount}", "fee_rate=2"] bank
  mine 1
  let mut coins := #[]
  for index in indices do
    let script ← mam "spk" (a.scriptPubKey index)
    let result ← cliJson #["scantxoutset", "start", s!"[\"raw({hex script})\"]"]
    let unspents ← match result.getObjValAs? (Array Json) "unspents" with
      | .ok u => pure u | .error e => throw (IO.userError e)
    for u in unspents do
      let txid ← hexOf (← jstr u "txid")
      let amount ← sats ((u.getObjVal? "amount").toOption.getD Json.null)
      let vout := ((u.getObjValAs? Nat "vout").toOption.getD 0).toUInt32
      let h := ((u.getObjValAs? Nat "height").toOption.getD 0).toUInt32
      let coin : WalletUTXO := { txid := ByteArray.reverse txid, vout, amount, scriptPubKey := script,
                                 chain := .receive, index, height := h }
      coins := coins.push coin
  return coins

def signerPositions (a : MultisigAccount) (signers : Array Signer) : IO (Array Nat) := do
  let listed := a.signers.map fun k => match k.base with
    | .extended x _ => x.serialized .testnet | _ => ""
  signers.mapM fun s => do
    let key ← s.accountKey
    let some p := listed.findIdx? (· == key) | throw (IO.userError "a signer is missing from the account")
    return p

def recoveryHolders (a : MultisigAccount) (c : Case) : IO (Array Signer) := do
  let holders : Array Signer := if c.recoveryMasters.isEmpty then c.signers else c.recoveryMasters.map .winnow
  let keys ← holders.mapM (·.accountKey)
  (a.keysOn .recovery).mapM fun k => do
    let .extended x _ := k.base | throw (IO.userError "a recovery key is not an xpub")
    let some p := keys.findIdx? (· == x.serialized .testnet) | throw (IO.userError "a recovery key has no holder")
    return holders[p]!

def sortedNat (xs : Array Nat) : Array Nat := (xs.toList.mergeSort (· ≤ ·)).toArray

/-! ## The checks -/

def checkAddresses (a : MultisigAccount) (c : Case) (expressions : Array String) (tag : String) : IO Unit := do
  let text := a.descriptor.serialized
  let body := (text.splitOn "#")[0]!
  let coreChecksum ← jstr (← cliJson #["getdescriptorinfo", body]) "checksum"
  tally (coreChecksum == a.id) "descriptor checksum" s!"{tag}: Core {coreChecksum}, Winnow {a.id}"
  let derived ← cliJson #["deriveaddresses", text, "[0,3]"]
  let lists : Array (Array String) := match derived with
    | .arr xs => if xs.all (fun x => match x with | .arr _ => true | _ => false) then
        xs.map fun x => match x with | .arr ys => ys.filterMap (·.getStr?.toOption) | _ => #[]
      else #[xs.filterMap (·.getStr?.toOption)]
    | _ => #[]
  for choice in [0:2] do
    for index in [0:4] do
      let ours ← mam "address" (a.address index.toUInt32 choice)
      let theirs := ((lists[choice]?).bind (·[index]?)).getD "none"
      tally (ours == theirs) "address" s!"{tag} {choice}/{index}: Core {theirs}, Winnow {ours}"
  let reversedRecovery := c.recovery.map fun
    | .separateKeys m ks b => .separateKeys m ks.reverse b
    | plan => plan
  let reordered ← mam "reordered" (MultisigAccount.makeDescriptor c.threshold expressions.reverse reversedRecovery .regtest)
  tally (reordered.serialized == text) "signer order"
    s!"{tag}: listing the keys in reverse gives {reordered.serialized}, not {a.id}"

def checkSignersPath (a : MultisigAccount) (c : Case) (tag : String) : IO Unit := do
  let coins ← fund a #[0, 1]
  let tip ← height
  let destination ← newScript
  let psbt ← mam "create" (a.createSpend coins #[{ amount := 60_000, scriptPubKey := destination }] 0 2 tip .signers (0.5, 0.5))
  let owned : Array OutputCoordinate := #[{ choice := 1, index := 0 }]
  let positions ← signerPositions a c.signers
  let k := c.threshold
  let all := (List.range c.signers.size)
  let mut trials := (combinations all k).map List.toArray
  if k > 1 then trials := trials ++ [(all.take (k - 1)).toArray]
  if k < c.signers.size then trials := trials ++ [(all.take (k + 1)).toArray]
  let mut first : Option (String × String) := none
  for trial in trials do
    let subset ← shuffle trial
    let label := s!"{tag} signers {subset.toList.map fun i => c.signers[i]!.label ++ toString i}"
    let mut signed := psbt
    for member in subset do signed ← signAs signed c.signers[member]! a coins owned tip
    let approved ← mam "approvals" (a.approvals signed coins)
    let expected := sortedNat (subset.map (positions[·]!))
    tally (approved == expected) "verified signers" s!"{label}: Winnow verifies {approved}, signed by {expected}"
    let (ours, theirs) ← finalizeBoth a signed coins owned tip
    if subset.size < k then
      tally (ours.isNone && theirs.isNone) "below threshold refused"
        s!"{label}: Winnow finished {ours.isSome}, Core finished {theirs.isSome}"
      continue
    let some ours := ours | tally false "threshold finalizes" s!"{label}: Winnow refused {k} signatures"; continue
    tally theirs.isSome "threshold finalizes" s!"{label}: Core's finalizer did not complete"
    if subset.size == k then
      if let some t := theirs then tally (ours == t) "finalizers agree" s!"{label}: Winnow {ours}, Core {t}"
    let (allowed, reason) ← mempoolVerdict ours
    tally allowed "Core accepts" s!"{label}: {reason}"
    if allowed && first.isNone then first := some (label, ours)
  if let some (label, txHex) := first then broadcastAndMine txHex label

def checkRecoveryPath (a : MultisigAccount) (c : Case) (tag : String) : IO Unit := do
  let some recovery := a.recovery | return
  let coin := (← fund a #[2])[0]!
  let unlock := coin.height + recovery.blocks
  let openTip := unlock - 1
  let destination ← newScript
  -- Core's 50-block anti-fee-sniping lookback, so only BIP68 can refuse the spend a block early.
  let psbt ← mam "create recovery" (a.createSpend #[coin] #[{ amount := 40_000, scriptPubKey := destination }] 1 2 openTip
    .recovery (0, 0.5))
  let owned : Array OutputCoordinate := #[{ choice := 1, index := 1 }]
  let holders ← recoveryHolders a c
  let m := recovery.threshold.toNat
  let all := List.range holders.size
  let mut trials := (combinations all m).map List.toArray
  if m > 1 then trials := trials ++ [(all.take (m - 1)).toArray]
  let mut ready : Array (String × String) := #[]
  for trial in trials do
    let subset ← shuffle trial
    let label := s!"{tag} recovery keys {subset}"
    let mut signed := psbt
    for member in subset do signed ← signAs signed holders[member]! a #[coin] owned openTip
    let approved ← mam "approvals" (a.approvals signed #[coin] .recovery)
    tally (approved == sortedNat subset) "verified recovery signers"
      s!"{label}: Winnow verifies {approved}, signed by {sortedNat subset}"
    let (ours, theirs) ← finalizeBoth a signed #[coin] owned openTip
    let signersCanFinish := decide ((← mam "approvals" (a.approvals signed #[coin])).size ≥ c.threshold)
    if subset.size < m then
      tally (ours.isSome == signersCanFinish && theirs.isSome == signersCanFinish) "below recovery threshold"
        s!"{label}: Winnow finished {ours.isSome}, Core finished {theirs.isSome}, signers' leaf complete {signersCanFinish}"
      continue
    let some ours := ours | tally false "recovery finalizes" s!"{label}: Winnow refused {m} recovery signatures"; continue
    tally theirs.isSome "recovery finalizes" s!"{label}: Core's finalizer did not complete"
    if let some t := theirs then
      if !signersCanFinish then tally (ours == t) "recovery finalizers agree" s!"{label}: Winnow {ours}, Core {t}"
    ready := ready.push (label, ours)
  -- BIP326: the signers' leaf may finish a spend that carries the recovery sequence.
  let mut bySigners := psbt
  for member in [0:c.threshold] do bySigners ← signAs bySigners c.signers[member]! a #[coin] owned openTip
  match (← finalizeBoth a bySigners #[coin] owned openTip).1 with
  | some ours => ready := ready.push (s!"{tag} signers' leaf with the recovery sequence", ours)
  | none => tally false "signers' leaf under the recovery sequence" s!"{tag}: Winnow refused it"
  -- One block before the lock opens: Core and Winnow both refuse.
  if openTip ≥ 1 && openTip - 1 ≥ (← height) then
    mineTo (openTip - 1)
    tally (!a.isUnlockedForRecovery coin (openTip - 1)) "locked a block early"
      s!"{tag}: Winnow calls the coin unlocked at tip {openTip - 1}, coin at {coin.height}"
    for (label, txHex) in ready do
      let (allowed, reason) ← mempoolVerdict txHex
      tally (!allowed && (reason.splitOn "non-BIP68-final").length > 1) "Core refuses a block early"
        s!"{label}: allowed {allowed} {reason}"
  -- The block the lock opens in: both accept.
  mineTo openTip
  tally (a.isUnlockedForRecovery coin openTip) "unlocked on time"
    s!"{tag}: Winnow calls the coin locked at tip {openTip}, coin at {coin.height}"
  tally (a.recoveryUnlockHeight coin == some unlock) "unlock height"
    s!"{tag}: Winnow {a.recoveryUnlockHeight coin}, expected {unlock}"
  for (label, txHex) in ready do
    let (allowed, reason) ← mempoolVerdict txHex
    tally allowed "Core accepts on time" s!"{label}: {reason}"
  if let some (label, txHex) := ready[0]? then
    if (← mempoolVerdict txHex).1 then broadcastAndMine txHex label

def checkCase (c : Case) (tag : String) : IO Unit := do
  let expressions ← c.signers.mapM (·.expression)
  let d ← mam "descriptor" (MultisigAccount.makeDescriptor c.threshold expressions c.recovery .regtest)
  let a ← mam "account" (MultisigAccount.make d .regtest)
  checkAddresses a c expressions tag
  for s in c.signers do
    if let .core core := s then core.importAccount a
  checkSignersPath a c tag
  if let some r := a.recovery then
    if r.blocks ≤ spendableDelay then checkRecoveryPath a c tag

def parseHex64 (s : String) : Option UInt64 :=
  s.toList.foldlM (fun acc ch =>
    let d := if '0' ≤ ch && ch ≤ '9' then some (ch.toNat - 48)
      else if 'a' ≤ ch && ch ≤ 'f' then some (ch.toNat - 87)
      else if 'A' ≤ ch && ch ≤ 'F' then some (ch.toNat - 55) else none
    d.map fun d => acc * 16 + d.toUInt64) 0

def main (args : List String) : IO UInt32 := do
  let mut seed : UInt64 := 0x5441_5052_4F4F_5453
  let mut cases := 24
  let mut rest := args
  while !rest.isEmpty do
    match rest with
    | "--seed" :: v :: r => seed := (parseHex64 v).getD seed; rest := r
    | "--cases" :: v :: r => cases := v.toNat!; rest := r
    | x :: _ => IO.eprintln s!"unknown argument {x}"; return 2
    | [] => pure ()
  let dir := s!"/tmp/winnow-multisig-core-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  let n ← startNode dir
  try
    let chain ← jstr (← cliJson #["getblockchaininfo"]) "chain"
    unless chain == "regtest" do throw (IO.userError s!"the node reports {chain}")
    ensureWallet bank
    mine 110
    for number in [0:cases] do
      rngState.set (seed + number.toUInt64 * 0x9E37_79B9)
      let tag := s!"seed {String.ofList (Nat.toDigits 16 seed.toNat)} case {number}"
      let start ← IO.monoMsNow
      try
        let c ← generate number
        say s!"case {number}: {c.summary}"
        checkCase c tag
      catch e => tally false "case completed" s!"{tag}: {e}"
      say s!"  ({(← IO.monoMsNow) - start} ms)"
  finally
    killPid n.pid
    IO.sleep 1000
    discard <| IO.Process.output { cmd := "rm", args := #["-rf", dir] }
  for (kind, k) in ← agreed.get do say s!"  {kind}: {k}"
  let d ← disagreements.get
  say s!"multisig-differential: {(← agreed.get).foldl (· + ·.2) 0} agreements, {d.size} disagreements"
  for x in d do say s!"  {x}"
  return if d.isEmpty then 0 else 1
