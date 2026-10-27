import WinnowApp.Real.Send
import WinnowApp.Real.Records
import WinnowApp.Real.MultisigStore
import WinnowApp.Real.LedgerTransport

/-! # Multisig accounts in the app (AppModel.swift at upstream 1cf93fb, "Multisig accounts (Advanced mode)")

AppModel's multisig operations over the core (`Env`: the wallet, the chain tip, the broadcaster and the
spending gate) and the account store (`MultisigHost`): `multisigKeyExpression`,
`multisigAccount(validating:)`, `addMultisigAccount`, `removeMultisigAccount`,
`newMultisigReceiveAddress`, `multisigOwnedCoordinates`, `reviewMultisigSpend`,
`multisigOwnSignerPositions`, `multisigSigningScreen` (+ its progress), `multisigApprovals`,
`createMultisigSpend`, `signMultisigSpend`, `combineMultisigSpend`, `broadcastMultisigSpend` (+ `feeRate(of:
spending:)`), `createMultisigAccount` without its Ledger branch, and `journalPSBT`. Also the `Hooks` the core
reads the store through (the combined scan, rollbacks, import, export, history ownership).

The Model holds no PSBT: a PSBT travels as its v2 Base64 (`MultisigPSBT.psbt`), and every operation
answers with the PSBT in hand reviewed again (`present`), as the screen's `install` does.

Left for the Ledger phase: `pairLedger`, `includeLedger`, `verifyLedgerAddress`,
`signMultisigSpendWithLedger`, `setLedger`; the progress already reads a paired Ledger's position from a
record's `ledger`, so its texts are Swift's once one exists. -/

namespace WinnowApp.Real
open Winnow Winnow.IO Winnow.Net WinnowApp.RecordsReal
open MultisigAccount (OutputCoordinate SpendPath)

/-- `MultisigActionError`. -/
def notASignerText : String :=
  "No key of this descriptor is this wallet's key. Put this phone's key among the signers or the recovery keys."
def accountHoldsCoinsText : String :=
  "This account still holds coins or a pending payment. Spend them first: a removed account is not scanned, and adding it again does not find coins it already had."
def spendNotRecordedText (txid reason : String) : String :=
  s!"Sent as {txid}, but the account could not be updated: {reason} Do not spend from it again until it syncs."

/-- `LedgerActionError` (the cases the account builder throws without a Ledger). -/
def advancedModeOnlyText : String :=
  "Multisig accounts and Ledger signing are part of Advanced mode. Turn on Advanced mode to use them."
def invalidNameText : String :=
  "Use a name of 1 to 64 plain letters, digits and punctuation: the Ledger shows it on its screen."

/-- `PSBTError.errorDescription`. -/
def psbtErrorText : PSBTError → String
  | .invalidMagic => "That text is not a valid PSBT."
  | .truncated => "The PSBT ended before all of its data could be read."
  | .duplicateKey _ => "The PSBT repeats a field that must appear only once."
  | .unsupportedVersion v => s!"This PSBT uses unsupported version {v}. Use PSBTv0 or PSBTv2."
  | .missingField f => s!"The PSBT is missing required data ({f})."
  | .malformed r => s!"The PSBT is malformed ({r})."
  | .inconsistentCounts => "The PSBT's input or output count does not match its transaction."
  | .conflict _ => "The PSBTs disagree about a field and cannot be combined safely."
  | .wire e => s!"The operation couldn’t be completed. (WalletCore.WireError.{e.name})"

/-- A `MultisigAccount` failure as the screens show it (another module's error is known by its case name
only, so it reads as `namedText` does). -/
def multisigFailureText : MultisigFailure → String
  | .account e => e.description
  | .named n => namedText n

def runMAM {α} (x : MAM α) : IO α :=
  match x with
  | .ok a => pure a
  | .error e => failText (multisigFailureText e)

/-- The store and a cache of the overview the screens poll (each address costs a derivation). -/
structure MultisigApp where
  host : MultisigHost
  overviewCache : IO.Ref (Option (Array MultisigAccountRecord × Option String × Option String × MultisigOverview))
  /-- `ledgerConnector`: opens one Ledger connection (Bluetooth through the shell, or test mode's
  simulated device); swappable, as Swift's `var ledgerConnector` is. -/
  ledger : IO.Ref (IO LedgerSession)

/-- Without a connector, every Ledger operation fails as a Ledger the phone cannot reach. -/
def noLedger : IO LedgerSession :=
  throw (IO.userError (LedgerError.transport "this device has no Bluetooth Low Energy").description)

def MultisigApp.new (keys : StoreKeyVault) (ledger : IO LedgerSession := noLedger) : IO MultisigApp := do
  return { host := ← MultisigHost.new keys, overviewCache := ← IO.mkRef none, ledger := ← IO.mkRef ledger }

namespace MultisigApp

/-! ## The store's hooks into the core -/

def withStore {α} (a : MultisigApp) (f : MultisigStore → RM (MultisigStore × α)) : IO α := RM.toIO (a.host.modify f)

def watchScripts (a : MultisigApp) (network : Tx.BitcoinNetwork) : IO (Array ByteArray) :=
  a.withStore fun s => do
    let (scripts, s') ← s.watchScripts network
    return (s', scripts)

def applyMatch (a : MultisigApp) (m : Net.BlockMatch) (network : Tx.BitcoinNetwork) : IO (Array ByteArray) :=
  a.withStore fun s => s.apply a.host.keys a.host.writeData m network

def rollBack (a : MultisigApp) (fork : UInt32) : IO Unit :=
  a.withStore fun s => do return (← s.rollBack a.host.keys a.host.writeData fork, ())

def restore (a : MultisigApp) (records : Array MultisigAccountRecord) : IO Unit :=
  a.withStore fun s => do return (← s.restore a.host.keys a.host.writeData records, ())

def backup (a : MultisigApp) : IO (Array MultisigAccountRecord) := do RM.toIO (← a.host.read).backupRecords

/-- `ownedMultisigScripts`: the scripts the accounts watch, on the store's network. -/
def ownedScripts (a : MultisigApp) : IO (Array ByteArray) := do
  a.watchScripts (← a.host.read).network

def hooks (a : MultisigApp) (base : Hooks) : Hooks :=
  { base with
    configure := fun n dir => do
      let r ← base.configure n dir
      a.host.configure (Network.tx n) (some (System.FilePath.mk dir))
      return r
    multisigWatchScripts := a.watchScripts
    multisigApply := a.applyMatch
    multisigRollBack := a.rollBack
    multisigValidate := fun rs n => RM.toIO (MultisigStore.validate rs n)
    multisigRestore := a.restore
    multisigBackup := a.backup
    multisigOwnedScripts := a.ownedScripts }

end MultisigApp

/-! ## AppModel's multisig operations -/

def currentNetwork (env : Env) : IO Tx.BitcoinNetwork := do
  match (← env.get).network with
  | some n => return Network.tx n
  | none => failWith .noWallet

def needWallet (env : Env) : IO Wallet := do
  let some w := (← env.get).wallet | failWith .noWallet
  return w

/-- `status.tipHeight`: the validated header tip (0 without a stack). -/
def chainTip (env : Env) : IO UInt32 := do
  match (← env.get).stack with
  | some s => s.chain.height
  | none => return 0

/-- The wallet's BIP86 account key (the `tr(KEY)` of its descriptor). -/
def walletAccountKey? (w : Wallet) : Option Keys.HDKey :=
  match w.descriptor.expression with
  | .tr key => match key.base with
    | .extended k _ => some k
    | _ => none
  | _ => none

/-- `multisigKeyExpression()`: the BIP86 account xpub with its origin and `/<0;1>/*`. -/
def multisigKeyExpression (env : Env) : IO String := do
  RM.toIO (ownKeyExpression (← needWallet env) true)

/-- `multisigAccount(validating:)`: the supported shape, this network, and one key that is this wallet's. -/
def multisigAccountValidating (w : Wallet) (text : String) : IO MultisigAccount := do
  let account ← runMAM (MultisigAccount.parse (Wire.trimWhitespace text) w.network)
  let some key := walletAccountKey? w | failText notASignerText
  unless account.includes key do failText notASignerText
  return account

def accountOf (r : MultisigAccountRecord) (network : Tx.BitcoinNetwork) : IO MultisigAccount :=
  runMAM (MultisigAccount.parse r.descriptor network)

def record (a : MultisigApp) (id : String) : IO MultisigAccountRecord := do
  let some r := (← a.host.read).record? id | failText "This multisig account is no longer on this phone."
  return r

/-- `addMultisigAccount(name:descriptor:)`: watched from the next block scanned. -/
def addMultisigAccount (env : Env) (a : MultisigApp) (name descriptor : String) : IO MultisigAccountRecord := do
  let w ← needWallet env
  let account ← multisigAccountValidating w descriptor
  let height ← match (← env.get).stack.bind (·.filters) with
    | some f => f.nextScanHeight
    | none => w.nextScanHeight
  let record ← a.withStore fun s => s.add a.host.keys a.host.writeData ((DisplayName.normalized name).getD "") account height
  env.journal "multisig.accountAdded"
    [("id", record.id), ("descriptor", record.descriptor), ("height", toString height),
     ("firstAddress", (account.address 0).toOption.getD "")]
  return record

/-- `removeMultisigAccount(id:)`: only an account whose every coin is spent in a block. -/
def removeMultisigAccount (a : MultisigApp) (id : String) : IO Unit := do
  let some r := (← a.host.read).record? id | return
  unless r.allUtxos.all (fun u => u.spent.any (·.height.isSome)) do failText accountHoldsCoinsText
  a.withStore fun s => do return (← s.remove a.host.keys a.host.writeData id, ())

def newMultisigReceiveAddress (a : MultisigApp) (id : String) : IO Unit :=
  a.withStore fun s => do return (← s.advanceReceiveIndex a.host.keys a.host.writeData id, ())

/-- `multisigOwnedCoordinates(for:)`: every coin's own, plus the next receive and change slots. -/
def ownedCoordinates (r : MultisigAccountRecord) : Array OutputCoordinate :=
  r.utxos.map (fun u => { choice := u.chain.rawValue, index := u.index }) ++
    #[{ choice := AddressChain.receive.rawValue, index := r.nextReceiveIndex },
      { choice := AddressChain.change.rawValue, index := r.nextChangeIndex }]

/-- `reviewMultisigSpend(_:record:)`. -/
def reviewSpend (env : Env) (r : MultisigAccountRecord) (account : MultisigAccount) (psbt : PSBT) :
    IO MultisigAccount.SpendReview := do
  runMAM (account.reviewSpend psbt r.utxos (ownedCoordinates r) (← chainTip env))

/-- `multisigOwnSignerPositions(_:path:)`. -/
def ownSignerPositions (w : Wallet) (account : MultisigAccount) (path : SpendPath) : Array Nat :=
  match walletAccountKey? w with
  | none => #[]
  | some key =>
    let keys := account.keysOn path
    (List.range keys.size).toArray.filter fun i => match MultisigAccount.extendedKey? keys[i]! with
      | some (base, _) => base.publicKey == key.publicKey
      | none => false

/-- `multisigApprovals(_:record:path:)`. -/
def approvals (r : MultisigAccountRecord) (account : MultisigAccount) (psbt : PSBT) (path : SpendPath) : Array Nat :=
  (account.approvals psbt r.utxos path).toOption.getD #[]

/-- `multisigLedgerPosition`: the paired Ledger among `keys`, by its origin. -/
def ledgerPosition (r : MultisigAccountRecord) (keys : Array Descriptor.SingleKey) : Option Nat := do
  let l ← r.ledger
  keys.findIdx? fun k => match k.origin with
    | some o => o.fingerprint == l.masterFingerprint && o.path == l.keyPath
    | none => false

/-- `multisigSigningScreen(_:record:)`: the review (fails closed), the verified signatures on each leaf
that can finish the spend, and what this phone and its Ledger still need to add. -/
def signingScreen (env : Env) (r : MultisigAccountRecord) (psbt : PSBT) : IO MultisigScreen := do
  let w ← needWallet env
  let network ← currentNetwork env
  let account ← accountOf r network
  let review ← reviewSpend env r account psbt
  let paths : List SpendPath := if review.path == .recovery then [.signers, .recovery] else [.signers]
  let mut progress : MultisigProgress := {}
  let mut signatures : List (Bool × Nat × Nat) := []
  for path in paths do
    let approved := approvals r account psbt path
    let threshold := (account.thresholdOn path).toNat
    signatures := signatures ++ [(path == .recovery, approved.size, threshold)]
    if approved.size ≥ threshold then progress := { progress with complete := true }
    let own := ownSignerPositions w account path
    progress := { progress with phoneHolds := progress.phoneHolds || !own.isEmpty,
                                phoneUnsigned := progress.phoneUnsigned || !own.all approved.contains }
    if let some ledger := ledgerPosition r (account.keysOn path) then
      progress := { progress with ledgerHolds := true, ledgerUnsigned := progress.ledgerUnsigned || !approved.contains ledger }
  let outputs := review.outputs.toList.map fun o =>
    { owned := o.isAccountOwned, amount := natOf o.amount,
      address := (AddressDecoder.address o.scriptPubKey network).getD (hex o.scriptPubKey) : MultisigOutputLine }
  return { outputs, inputTotal := natOf review.inputTotal, fee := natOf review.fee, signatures, progress }

/-- The screen's `install` + `refreshReview`: the PSBT in hand, its v0 text to share, and its review. -/
def present (env : Env) (r : MultisigAccountRecord) (psbt : PSBT) : IO MultisigPSBT := do
  let output := psbt.base64V0.toOption
  try
    return { psbt := psbt.base64, output, screen := some (← signingScreen env r psbt) }
  catch e =>
    return { psbt := psbt.base64, output, screen := none, reviewError := some (toString e) }

/-- `journalPSBT(stage:psbt:)`: only the public PSBT exchanged with other signers. -/
def journalPSBT (env : Env) (stage : String) (psbt : PSBT) : IO Unit :=
  env.journal "psbt.generated"
    [("stage", stage), ("base64", psbt.base64), ("inputCount", toString psbt.inputs.size),
     ("outputCount", toString psbt.outputs.size)]

def parsePSBT (text : String) : IO PSBT :=
  match PSBT.ofBase64 (Wire.trimWhitespace text) with
  | .ok p => pure p
  | .error e => failText (psbtErrorText e)

def roleText (e : PSBTRoleError) : String :=
  match e with
  | .psbt p => psbtErrorText p
  | .sign s => namedText s.name

/-- `createMultisigSpend(record:address:amount:feeRateSatPerVByte:path:)`: one payment, change to the next
change address, on the signers' path or (old enough coins) the recovery path. -/
def createMultisigSpend (env : Env) (a : MultisigApp) (id address : String) (amount : Int) (feeRate : Float)
    (recovery : Bool) : IO MultisigPSBT := do
  let r ← record a id
  let network ← currentNetwork env
  let payment ← match Payment.ofAddress (Int64.ofInt amount) (Wire.trimWhitespace address) network with
    | .ok p => pure p
    | .error e => failText (addressErrorText e)
  -- the first thing coin selection refuses (its other errors reach here by name only)
  unless amount > 0 do failText (CoinSelectionError.invalidAmount (Int64.ofInt amount)).description
  let account ← accountOf r network
  let draws := (← env.deps.random.draw, ← env.deps.random.draw)
  let position ← env.deps.random.changePosition 1
  let psbt ← runMAM (account.createSpend r.utxos #[payment] r.nextChangeIndex feeRate (← chainTip env)
    (if recovery then .recovery else .signers) draws (fun _ => position))
  journalPSBT env "multisig-created" psbt
  present env r psbt

/-- The screen's `refreshReview` for a PSBT already in hand (the account's coins or frontiers moved). -/
def reviewMultisigPSBT (env : Env) (a : MultisigApp) (id text : String) : IO MultisigPSBT := do
  present env (← record a id) (← parsePSBT text)

/-- `combineMultisigSpend(_:with:record:)`: another signer's copy merged (BIP174 combiner), then reviewed. -/
def combine (env : Env) (r : MultisigAccountRecord) (psbt other : PSBT) : IO PSBT := do
  let combined ← match psbt.combined #[other] with
    | .ok c => pure c
    | .error e => failText (roleText e)
  discard <| reviewSpend env r (← accountOf r (← currentNetwork env)) combined
  return combined

/-- MultisigPSBTView's `addPasted`: a pasted PSBT is combined with the one in hand, or (none in hand) used
once it reviews. -/
def addPastedPSBT (env : Env) (a : MultisigApp) (id : String) (working : Option String) (pasted : String) :
    IO MultisigPSBT := do
  let r ← record a id
  let incoming ← parsePSBT pasted
  let candidate ← match working with
    | some text => combine env r (← parsePSBT text) incoming
    | none =>
      discard <| reviewSpend env r (← accountOf r (← currentNetwork env)) incoming
      pure incoming
  let shown ← present env r candidate
  journalPSBT env "multisig-combined" candidate
  return shown

/-- `signMultisigSpend(_:record:)` (after device authentication, in `perform`): this wallet's script-path
signature on every input. -/
def signMultisigSpend (env : Env) (a : MultisigApp) (id text : String) : IO MultisigPSBT := do
  let r ← record a id
  let w ← needWallet env
  let account ← accountOf r w.network
  let psbt ← parsePSBT text
  let key ← runWM w.multisigSigningKey
  let signed ← runMAM (account.sign psbt key r.utxos (ownedCoordinates r) (← chainTip env) (← env.deps.random.auxRand))
  journalPSBT env "multisig-signed" signed
  present env r signed

/-- `AppModel.feeRate(of:spending:)`: the rate of a spend of known coins; none when an input is not one. -/
def feeRateOf (tx : Transaction) (coins : Array WalletUTXO) : Option Float := do
  let mut inputs : Int := 0
  for input in tx.inputs do
    let coin ← coins.find? (·.outpoint == input.previousOutput)
    inputs := inputs + coin.amount.toInt
  let fee := inputs - tx.outputs.foldl (fun t o => t + o.value.toInt) 0
  let vsize := TransactionBuilder.vsize tx
  guard (fee > 0 && vsize > 0)
  return Float.ofInt fee / vsize.toFloat

/-- `broadcastMultisigSpend(_:record:)`: finalize once enough signatures verify, broadcast, then move the
spent coins in flight and the change to pending, under the spending gate. The txid (display hex). -/
def broadcastMultisigSpend (env : Env) (a : MultisigApp) (id text : String) : IO String := exclusively env do
  let r ← record a id
  let network ← currentNetwork env
  let account ← accountOf r network
  let psbt ← parsePSBT text
  let (_, tx) ← runMAM (account.finalizeSpend psbt r.utxos (ownedCoordinates r) (← chainTip env))
  let txid ← broadcastTx env tx (feeRateOf tx r.utxos)
  let changeScript ← runMAM (account.scriptPubKey r.nextChangeIndex AddressChain.change.rawValue)
  let hasChange := tx.outputs.any (·.scriptPubKey == changeScript)
  try
    a.withStore fun s => do
      let (s', _) ← s.recordSpend a.host.keys a.host.writeData r.id tx (if hasChange then some r.nextChangeIndex else none)
      return (s', ())
  catch e =>
    failText (spendNotRecordedText (Winnow.displayHex txid) (toString e))
  env.journal "multisig.spendBroadcast" [("id", r.id), ("txid", Winnow.displayHex txid)]
  return Winnow.displayHex txid

def recoveryPlan : MultisigRecovery → MultisigAccount.RecoveryPlan
  | .fewerSigners t b => .fewerSigners t b.toUInt32
  | .separateKey key b => .separateKeys 1 #[Wire.trimWhitespace key] b.toUInt32

/-- `LedgerActionError.notPaired`. -/
def notPairedText : String := "No Ledger is paired with this account."

/-- One Ledger connection for `body` (`ledgerConnector.connect()` … `session.close()`). -/
def MultisigApp.withSession {α} (a : MultisigApp) (body : LedgerSession → IO α) : IO α := do
  let session ← (← a.ledger.get)
  try body session finally session.close

/-- One step of a Ledger operation on an open connection; its failure as the Ledger error's text. -/
def runOn {α} (session : LedgerSession) (p : Ledger.Program α) : IO α := do
  match ← (Ledger.Program.runIO session.exchange p).run with
  | .ok v => pure v
  | .error e => failText e.description

/-- `setLedger(id:registration:)` through the store. -/
def setLedger (a : MultisigApp) (id : String) (registration : LedgerRegistration) : IO Unit :=
  a.withStore fun s => do return (← s.setLedger a.host.keys a.host.writeData id registration, ())

/-- `existingOrNewMultisigAccount(name:descriptor:)`. -/
def existingOrNew (env : Env) (a : MultisigApp) (name text : String) : IO MultisigAccountRecord := do
  let id := String.ofList (text.toList.drop (text.length - 8))
  if let some existing := (← a.host.read).record? id then return existing
  addMultisigAccount env a name text

/-- `createMultisigAccount(name:threshold:otherKeys:includeLedger:recovery:)`: this phone's key, the other
signers' pasted key expressions and optionally a Ledger's key read over Bluetooth, any `threshold` of
them, with an optional recovery path. A Ledger among the signers registers the account on its own
screen; pairing the same Ledger again refiles the registration of the same account. -/
def createMultisigAccount (env : Env) (a : MultisigApp) (advanced : Bool) (name : String) (threshold : Nat)
    (otherKeys : List String) (includeLedger : Bool) (recovery : Option MultisigRecovery) : IO MultisigAccountRecord := do
  unless advanced do failText advancedModeOnlyText
  let some name := DisplayName.normalized name | failText invalidNameText
  unless !includeLedger || Ledger.WalletPolicy.isValidName name do failText invalidNameText
  let pasted := (otherKeys.map Wire.trimWhitespace).filter (!·.isEmpty)
  let w ← needWallet env
  let own ← multisigKeyExpression env
  let plan := recovery.map recoveryPlan
  if !includeLedger then
    let descriptor ← runMAM (MultisigAccount.makeDescriptor threshold (#[own] ++ pasted.toArray) plan w.network)
    discard <| multisigAccountValidating w descriptor.serialized
    return ← existingOrNew env a name descriptor.serialized
  let (descriptor, registration) ← a.withSession fun session => do
    let (ledgerKey, fingerprint) ← runOn session (Ledger.Multisig.signerExpression w.network)
    let descriptor ← runMAM (MultisigAccount.makeDescriptor threshold (#[own] ++ pasted.toArray ++ #[ledgerKey]) plan w.network)
    let account ← multisigAccountValidating w descriptor.serialized
    let registration ← runOn session (Ledger.Multisig.register account name fingerprint)
    return (descriptor, registration)
  let record ← existingOrNew env a name descriptor.serialized
  setLedger a record.id registration
  env.journal "multisig.ledgerPaired" [("id", record.id)]
  return ((← a.host.read).record? record.id).getD record

/-- `pairLedger(name:)`: the Ledger as the second signer of a new 2-of-2. -/
def pairLedger (env : Env) (a : MultisigApp) (advanced : Bool) (name : String) : IO MultisigAccountRecord :=
  createMultisigAccount env a advanced name 2 [] true none

/-- `verifyLedgerAddress(record:index:)`: shows the address at `index` on the Ledger, which must be the
one this phone derives. -/
def verifyLedgerAddress (env : Env) (a : MultisigApp) (advanced : Bool) (id : String) (index : Nat) : IO String := do
  unless advanced do failText advancedModeOnlyText
  let r ← record a id
  let some registration := r.ledger | failText notPairedText
  let account ← accountOf r (← currentNetwork env)
  a.withSession fun session => runOn session (Ledger.Multisig.displayAddress account registration 0 index.toUInt32)

def signErrorText : Ledger.SignError → String
  | .ledger e => e.description
  | .psbt e => psbtErrorText e
  | .signing e => namedText e.name

/-- `signMultisigSpendWithLedger(_:record:)`: the phone reviews the spend first; the Ledger then shows it
on its own screen and adds a signature this phone keeps only once it verifies. -/
def signMultisigSpendWithLedger (env : Env) (a : MultisigApp) (advanced : Bool) (id text : String) : IO MultisigPSBT := do
  unless advanced do failText advancedModeOnlyText
  let r ← record a id
  let some registration := r.ledger | failText notPairedText
  let account ← accountOf r (← currentNetwork env)
  let psbt ← parsePSBT text
  discard <| reviewSpend env r account psbt
  let signed ← a.withSession fun session => do
    match ← runOn session (Ledger.Multisig.sign psbt account registration) with
    | .ok (signed, _) => pure signed
    | .error e => failText (signErrorText e)
  discard <| reviewSpend env r account signed
  journalPSBT env "multisig-ledger-signed" signed
  present env r signed

/-- MultisigAddView's `validation`: the pasted text read as an account for this phone. -/
def checkMultisigDescriptor (env : Env) (text : String) : IO MultisigCheck := do
  let account ← multisigAccountValidating (← needWallet env) text
  return { policy := s!"{account.threshold} of {account.signers.size}", firstAddress := (account.address 0).toOption }

/-! ## What the screens show -/

/-- `MultisigAccountView.recoveryText`: "after 4320 blocks: any 1 of the signers", or "… the recovery key". -/
def recoveryText (r : MultisigAccount.Recovery) (account : MultisigAccount) : String :=
  let signerKeys := account.signers.filterMap fun s => (MultisigAccount.extendedKey? s).map (·.1.publicKey)
  let reused := r.keys.all fun k => match MultisigAccount.extendedKey? k with
    | some (x, _) => signerKeys.contains x.publicKey
    | none => false
  let who := if reused then s!"any {r.threshold} of the signers"
    else if r.keys.size == 1 then "the recovery key" else s!"{r.threshold} of {r.keys.size} recovery keys"
  s!"after {r.blocks} blocks: {who}"

def coinLine (u : WalletUTXO) : String :=
  let txid := String.ofList ((Winnow.displayHex u.txid).toList.take 16)
  s!"{txid}…:{u.vout} · {if u.chain == .change then "change" else "receive"} {u.index} · " ++
    (if u.height == 0 then "pending" else s!"block {u.height}")

def info (r : MultisigAccountRecord) (network : Tx.BitcoinNetwork) : MultisigInfo :=
  let base : MultisigInfo :=
    { id := r.id, name := r.name, descriptor := r.descriptor, balance := r.balance.toInt,
      nextReceiveIndex := r.nextReceiveIndex.toNat,
      trusted := ",".intercalate (r.utxos.toList.map fun u => s!"{hex u.txid}:{u.vout}@{u.height}") ++
        s!"|{r.nextReceiveIndex}|{r.nextChangeIndex}" }
  match MultisigAccount.parse r.descriptor network with
  | .error _ => base
  | .ok account =>
    { base with
      policy := some s!"{account.threshold} of {account.signers.size}"
      recovery := account.recovery.map (recoveryText · account)
      ledgerFingerprint := r.ledger.map (Wallet.hex8 ·.masterFingerprint)
      receiveAddress := (account.address r.nextReceiveIndex).toOption
      coins := r.utxos.toList.map fun u =>
        { amount := natOf u.amount, line := coinLine u, recoveryFrom := (account.recoveryUnlockHeight u).map (·.toNat) } }

/-- `multisigAccounts`, `multisigStorageNotice` and `multisigKeyExpression()`, recomputed only when they
changed (every account's receive address is a derivation). -/
def overview (env : Env) (a : MultisigApp) : IO MultisigOverview := do
  let store ← a.host.read
  let notice ← a.host.notice.get
  let key ← match (← env.get).wallet with
    | some w => pure (((← (ownKeyExpression w true).run).toOption))
    | none => pure none
  if let some (rs, n, k, o) ← a.overviewCache.get then
    if rs == store.records && n == notice && k == key then return o
  let o : MultisigOverview :=
    { accounts := store.records.toList.map (info · store.network), notice, keyExpression := key }
  a.overviewCache.set (some (store.records, notice, key, o))
  return o

end WinnowApp.Real
