import WinnowApp.Real.Send
import WinnowApp.Real.Records
import WinnowApp.Real.MultisigStore
import WinnowApp.Real.SignerStore
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

/-- What the overview is a function of: the accounts, the signers, their notices, this phone's key and
the chain tip (a review's maturity and recovery checks). -/
structure OverviewKey where
  records : Array MultisigAccountRecord
  signers : Array SignerRecord
  notice : Option String
  signerNotice : Option String
  key : Option String
  tip : UInt32
  deriving BEq

/-- The store and a cache of the overview the screens poll (each address costs a derivation). -/
structure MultisigApp where
  host : MultisigHost
  /-- The signer list (`signerStore`): paired Ledgers and keys other people sent. -/
  signers : SignerHost
  overviewCache : IO.Ref (Option (OverviewKey × MultisigOverview))
  /-- `ledgerConnector`: opens one Ledger connection (Bluetooth through the shell, or test mode's
  simulated device); swappable, as Swift's `var ledgerConnector` is. -/
  ledger : IO.Ref (IO LedgerSession)

/-- Without a connector, every Ledger operation fails as a Ledger the phone cannot reach. -/
def noLedger : IO LedgerSession :=
  throw (IO.userError (LedgerError.transport "this device has no Bluetooth Low Energy").description)

def MultisigApp.new (keys : StoreKeyVault) (ledger : IO LedgerSession := noLedger) : IO MultisigApp := do
  return { host := ← MultisigHost.new keys, signers := ← SignerHost.new keys, overviewCache := ← IO.mkRef none,
           ledger := ← IO.mkRef ledger }

namespace MultisigApp

/-! ## The store's hooks into the core -/

def withStore {α} (a : MultisigApp) (f : MultisigStore → RM (MultisigStore × α)) : IO α := RM.toIO (a.host.modify f)

def withSigners {α} (a : MultisigApp) (f : SignerStore → RM (SignerStore × α)) : IO α := RM.toIO (a.signers.modify f)

/-- `mergeRestoredSigners(_:)`: the signer list is not the wallet's, so a bundle's joins the phone's own;
a damaged local list is already reported under Settings → Signers and must not stop the wallet from
restoring. -/
def mergeSigners (a : MultisigApp) (restored : Array SignerRecord) : IO Unit := do
  let r ← (a.signers.modify fun s => do
    let merged ← s.planRestore restored
    return (← s.restore a.signers.keys a.signers.writeData merged, ())).run
  match r with
  | .ok () => pure ()
  | .error e => if e.name == "damaged" then pure () else throw (IO.userError e.description)

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
      a.signers.configure (Network.tx n) (some (System.FilePath.mk dir))
      return r
    multisigWatchScripts := a.watchScripts
    multisigApply := a.applyMatch
    multisigRollBack := a.rollBack
    multisigValidate := fun rs n => RM.toIO (MultisigStore.validate rs n)
    multisigRestore := a.restore
    multisigBackup := a.backup
    multisigOwnedScripts := a.ownedScripts
    signerValidate := fun rs n => RM.toIO (SignerStore.validateBackup rs n)
    signerMerge := a.mergeSigners
    signerBackup := do RM.toIO (← a.signers.read).backup }

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

/-- `MultisigSigningScreen.signaturesTitle`: a nested account names its groups, on the recovery path too
when that has a leaf per group. -/
def signaturesTitle (path : SpendPath) (account : MultisigAccount) : String :=
  match path.recoveryLeaf with
  | some leaf => if account.recoveryLeaves.size > 1 then s!"Recovery group {leaf + 1} signatures" else "Recovery signatures"
  | none => if account.isNested then s!"Group {path.signersLeaf.getD 0 + 1} signatures" else "Signatures"

/-- `MultisigSigningScreen.signatureCountIdentifier`. -/
def signatureCountIdentifier (path : SpendPath) : String :=
  match path.recoveryLeaf with
  | some leaf => if leaf == 0 then "multisigRecoverySignatureCount" else s!"multisigRecoverySignatureCount-{leaf}"
  | none =>
    let leaf := path.signersLeaf.getD 0
    if leaf == 0 then "multisigSignatureCount" else s!"multisigSignatureCount-{leaf}"

/-- `multisigSigningScreen(_:record:)`: the review (fails closed), the verified signatures on each leaf
that can finish the spend, and what this phone and its Ledger still need to add. -/
def signingScreen (env : Env) (r : MultisigAccountRecord) (psbt : PSBT) : IO MultisigScreen := do
  let w ← needWallet env
  let network ← currentNetwork env
  let account ← accountOf r network
  let review ← reviewSpend env r account psbt
  -- every signers' leaf always, the recovery leaves too when every input's sequence meets their lock
  let paths : List SpendPath := account.signersPaths.toList ++ (if review.path.isRecovery then account.recoveryPaths.toList else [])
  let mut progress : MultisigProgress := {}
  let mut signatures : List (Bool × Nat × Nat) := []
  let mut titles : List (String × String) := []
  for path in paths do
    let approved := approvals r account psbt path
    let threshold := (account.thresholdOn path).toNat
    signatures := signatures ++ [(path.isRecovery, approved.size, threshold)]
    titles := titles ++ [(signaturesTitle path account, signatureCountIdentifier path)]
    if approved.size ≥ threshold then progress := { progress with complete := true }
    let own := ownSignerPositions w account path
    progress := { progress with phoneHolds := progress.phoneHolds || !own.isEmpty,
                                phoneUnsigned := progress.phoneUnsigned || !own.all approved.contains }
    if let some ledger := ledgerPosition r (account.keysOn path) then
      progress := { progress with ledgerHolds := true, ledgerUnsigned := progress.ledgerUnsigned || !approved.contains ledger }
  let outputs := review.outputs.toList.map fun o =>
    { owned := o.isAccountOwned, amount := natOf o.amount,
      address := (AddressDecoder.address o.scriptPubKey network).getD (hex o.scriptPubKey) : MultisigOutputLine }
  return { outputs, inputTotal := natOf review.inputTotal, fee := natOf review.fee, signatures, signatureTitles := titles,
           progress }

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

/-! ## Signers (Settings → Signers) -/

/-- `SignerLabel.fingerprint(of:network:)`: "6824f543", or "?" for text that is not a signer key. -/
def signerFingerprint (key : String) (network : Tx.BitcoinNetwork) : String :=
  match MultisigAccount.signerKey key network with
  | .ok single => match single.origin with
    | some o => Wallet.hex8 o.fingerprint
    | none => "?"
  | .error _ => "?"

/-- `SignerLabel.keysText(_:network:)`. -/
def signerKeysText (r : SignerRecord) (network : Tx.BitcoinNetwork) : String :=
  " · ".intercalate (r.keys.toList.map (signerFingerprint · network))

def signerInfo (r : SignerRecord) (network : Tx.BitcoinNetwork) : SignerInfo :=
  { id := r.id, isLedger := r.isLedger, name := r.name, keys := r.keys.toList, keysText := signerKeysText r network }

/-- `text.split(whereSeparator: \.isWhitespace)`: the keys of a pasted share. -/
def splitKeys (text : String) : List String :=
  let isSpace (c : Char) := Keys.Unicode.isWhitespaceOrNewline c && c.toNat != 0x200B
  (text.split isSpace).toList.map (·.toString) |>.filter (!·.isEmpty)

/-- `pairLedger(name:)`: reads the Ledger's signer key over Bluetooth and files it under `name` among this
phone's signers, for the account builder and the Join screen's member share. Nothing is registered on
the Ledger until an account uses it. Pairing the same Ledger again renames it. -/
def pairLedger (env : Env) (a : MultisigApp) (advanced : Bool) (name : String) : IO SignerRecord := do
  unless advanced do failText advancedModeOnlyText
  unless (DisplayName.normalized name).isSome do
    failText (SignerStorageError.invalidState "a signer needs a short, single-line name").description
  let network ← currentNetwork env
  let (expression, fingerprint) ← a.withSession fun session => runOn session (Ledger.Multisig.signerExpression network)
  let id ← uuidString
  let addedAt ← referenceDateNow
  let record ← a.withSigners fun s => s.addLedger a.signers.keys a.signers.writeData name expression fingerprint id addedAt
  env.journal "signer.ledgerPaired" [("id", record.id), ("fingerprint", Wallet.hex8 fingerprint)]
  return record

/-- `addSignerKeys(name:text:)`: keys someone sent as one signer: a single key, or a phone's pasted
together with its Ledger's, which then count as one member. -/
def addSignerKeys (env : Env) (a : MultisigApp) (advanced : Bool) (name text : String) : IO SignerRecord := do
  unless advanced do failText advancedModeOnlyText
  let keys := splitKeys text
  if keys.isEmpty then failText (SignerStorageError.invalidState "paste at least one key").description
  let network ← currentNetwork env
  for key in keys do discard <| runMAM (MultisigAccount.signerKey key network)
  let id ← uuidString
  let addedAt ← referenceDateNow
  a.withSigners fun s => s.addKeys a.signers.keys a.signers.writeData name keys.toArray id addedAt

def renameSigner (a : MultisigApp) (id name : String) : IO Unit :=
  a.withSigners fun s => do return (← s.rename a.signers.keys a.signers.writeData id name, ())

def removeSigner (a : MultisigApp) (id : String) : IO Unit :=
  a.withSigners fun s => do return (← s.remove a.signers.keys a.signers.writeData id, ())

/-- `pairedLedgers(in:)`: the paired Ledgers holding a key of `account`. -/
def pairedLedgers (signers : Array SignerRecord) (account : MultisigAccount) : Array SignerRecord :=
  signers.filter fun r => r.isLedger && (r.masterFingerprint.any (Ledger.Multisig.hasLedgerSigner account ·))

/-- `signerNames(for:)`: what to call each key of an account, by fingerprint: a paired Ledger's or a saved
signer's name, or "Ledger" for the registered device when it is not in the list. -/
def signerNames (signers : Array SignerRecord) (r : MultisigAccountRecord) (network : Tx.BitcoinNetwork) :
    List (UInt32 × String) := Id.run do
  let mut names : List (UInt32 × String) := []
  let put (names : List (UInt32 × String)) (fp : UInt32) (n : String) := (fp, n) :: names.filter (·.1 != fp)
  if let some l := r.ledger then names := put names l.masterFingerprint "Ledger"
  for signer in signers do
    for key in signer.keys do
      if let .ok single := MultisigAccount.signerKey key network then
        if let some o := single.origin then names := put names o.fingerprint signer.name
  return names

/-- `LedgerActionError.oneLedgerPerAccount`. -/
def oneLedgerPerAccountText : String :=
  "Winnow registers one of this phone's Ledgers per account. Put one Ledger in it, or build the account from another phone."

/-- The builder's members as `MultisigAccount.Member`s: keys trimmed, empty members dropped, each member's
threshold at most its key count (all of them when none is given). -/
def builderMembers (members : List (List String × Option Nat)) : Array MultisigAccount.Member :=
  members.toArray.filterMap fun (keys, t) =>
    let keys := (keys.map Wire.trimWhitespace).filter (!·.isEmpty)
    if keys.isEmpty then none else some { keys := keys.toArray, threshold := (min (t.getD keys.length) keys.length : Nat) }

/-- `createMultisigAccount(name:threshold:members:recovery:)`: the account builder over members, each one
signer's keys (this phone's own wherever the user put it, a Ledger's, a key someone sent, or several keys
that sign together); a member of more than one key makes the account nested. An account naming a Ledger
key must fit a Ledger's policy and carry a name a Ledger can show; at most one of this phone's paired
Ledgers per account. The paired Ledger registers it afterwards (`registerPairedLedger`). -/
def createMultisigAccount (env : Env) (a : MultisigApp) (advanced : Bool) (name : String) (threshold : Nat)
    (members : List (List String × Option Nat)) (recovery : Option MultisigRecovery) : IO MultisigAccountRecord := do
  unless advanced do failText advancedModeOnlyText
  let some name := DisplayName.normalized name | failText invalidNameText
  let w ← needWallet env
  let descriptor ← runMAM (MultisigAccount.makeNestedDescriptor (builderMembers members) threshold
    (recovery.map recoveryPlan) w.network)
  let account ← multisigAccountValidating w descriptor.serialized
  -- a Ledger shows the name and registers the policy, whoever's Ledger it is
  if Ledger.Multisig.namesALedgerKey account then
    unless Ledger.WalletPolicy.isValidName name do failText invalidNameText
    if let .error e := Ledger.WalletPolicy.ofAccount name account then failText e.description
  unless (pairedLedgers (← a.signers.all) account).size ≤ 1 do failText oneLedgerPerAccountText
  existingOrNew env a name descriptor.serialized

/-- `registerLedger(record:)`: registers the account on the Ledger connected now, which must hold one of
its keys: the Ledger shows the policy, the user approves it there, and it must derive the phone's first
address. -/
def registerLedger (env : Env) (a : MultisigApp) (advanced : Bool) (id : String) : IO MultisigAccountRecord := do
  unless advanced do failText advancedModeOnlyText
  let r ← record a id
  unless Ledger.WalletPolicy.isValidName r.name do failText invalidNameText
  let account ← accountOf r (← currentNetwork env)
  let registration ← a.withSession fun session => do
    let fingerprint ← runOn session Ledger.Client.masterFingerprint
    runOn session (Ledger.Multisig.register account r.name fingerprint)
  setLedger a r.id registration
  env.journal "multisig.ledgerRegistered" [("id", r.id)]
  record a id

/-- `registerPairedLedger(record:)`: an account just built or joined, registered on this phone's paired
Ledger when one holds a key of it; none when no paired Ledger is in the account (or it is registered). -/
def registerPairedLedger (env : Env) (a : MultisigApp) (advanced : Bool) (id : String) : IO (Option MultisigAccountRecord) := do
  let r ← record a id
  let account ← accountOf r (← currentNetwork env)
  if r.ledger.isSome || (pairedLedgers (← a.signers.all) account).isEmpty then return none
  return some (← registerLedger env a advanced id)

/-- The builder's and Join's Ledger step: the paired Ledger's name and the registration's outcome (its
failure as the text the screen shows); none when no paired Ledger holds a key of the account. -/
def registerAfterSaving (env : Env) (a : MultisigApp) (advanced : Bool) (r : MultisigAccountRecord) :
    IO (Option (Except String String)) := do
  let account ← accountOf r (← currentNetwork env)
  let some ledger := (pairedLedgers (← a.signers.all) account)[0]? | return none
  if r.ledger.isSome then return none
  try
    discard <| registerPairedLedger env a advanced r.id
    return some (.ok ledger.name)
  catch e => return some (.error (toString e))

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
def checkMultisigDescriptor (env : Env) (a : MultisigApp) (text : String) : IO MultisigCheck := do
  let account ← multisigAccountValidating (← needWallet env) text
  return { policy := account.policySummary, firstAddress := (account.address 0).toOption,
           ledgerName := (pairedLedgers (← a.signers.all) account)[0]?.map (·.name) }

/-! ## What the screens show -/

/-- `MultisigAccountView.recoveryText`: "after 4320 blocks: any 1 of the signers", or "… the recovery key". -/
def recoveryText (r : MultisigAccount.Recovery) (account : MultisigAccount) : String :=
  if let some members := account.recoveryMembers then s!"after {r.blocks} blocks: any {members.threshold} of the members" else
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

/-- `MultisigAccountView.groupText`: "6824f543 (this phone) · 5992698d (Nano X) · 1a2b3c4d (Bob)". -/
def groupText (keys : Array Descriptor.SingleKey) (ownKey : Option ByteArray) (names : List (UInt32 × String)) : String :=
  " · ".intercalate (keys.toList.map fun key =>
    match key.origin with
    | none => "no origin"
    | some o =>
      let fp := Wallet.hex8 o.fingerprint
      let own := match key.base, ownKey with
        | .extended xpub _, some k => xpub.publicKey == k
        | _, _ => false
      if own then fp ++ " (this phone)"
      else match names.lookup o.fingerprint with
        | some n => fp ++ s!" ({n})"
        | none => fp)

/-- `MultisigAccountView.memberText`: a member's keys, "any 2 of: " first when it signs with fewer than all. -/
def memberText (members : MultisigAccount.Members) (i : Nat) (ownKey : Option ByteArray) (names : List (UInt32 × String)) :
    String :=
  let keys := members.groups[i]!
  let prefix_ := if members.thresholds[i]! < keys.size then s!"any {members.thresholds[i]!} of: " else ""
  prefix_ ++ groupText keys ownKey names

/-- A nested account's members section (`groupsSection`): its header and lines. -/
def groupsSection (account : MultisigAccount) (ownKey : Option ByteArray) (names : List (UInt32 × String)) :
    Option String × List String :=
  if !account.isNested then (none, []) else
  match account.members with
  | some members =>
    (some s!"Members · any {members.threshold} of {members.groups.size}",
     (List.range members.groups.size).map (memberText members · ownKey names))
  | none =>
    (some "Ways to spend", account.signersLeaves.toList.map fun l => s!"{l.threshold} of: " ++ groupText l.keys ownKey names)

def info (r : MultisigAccountRecord) (network : Tx.BitcoinNetwork) (signers : Array SignerRecord := #[])
    (ownKey : Option ByteArray := none) : MultisigInfo :=
  let base : MultisigInfo :=
    { id := r.id, name := r.name, descriptor := r.descriptor, balance := r.balance.toInt,
      nextReceiveIndex := r.nextReceiveIndex.toNat,
      trusted := ",".intercalate (r.utxos.toList.map fun u => s!"{hex u.txid}:{u.vout}@{u.height}") ++
        s!"|{r.nextReceiveIndex}|{r.nextChangeIndex}" }
  match MultisigAccount.parse r.descriptor network with
  | .error _ => base
  | .ok account =>
    let names := signerNames signers r network
    let (membersHeader, memberLines) := groupsSection account ownKey names
    { base with
      policy := some account.policySummary
      recovery := account.recovery.map (recoveryText · account)
      ledgerFingerprint := r.ledger.map (Wallet.hex8 ·.masterFingerprint)
      ledgerName := r.ledger.map fun l =>
        let fp := Wallet.hex8 l.masterFingerprint
        match names.lookup l.masterFingerprint with
        | some n => s!"{n} · {fp}"
        | none => fp
      needsLedgerRegistration := r.ledger.isNone && Ledger.Multisig.namesALedgerKey account
      isNested := account.isNested, membersHeader, memberLines
      signerExpressions := account.signerExpressions.toList
      threshold := account.threshold.toNat, signerCount := account.signers.size
      receiveAddress := (account.address r.nextReceiveIndex).toOption
      coins := r.utxos.toList.map fun u =>
        { amount := natOf u.amount, line := coinLine u, recoveryFrom := (account.recoveryUnlockHeight u).map (·.toNat) } }

/-- `multisigAccounts`, `multisigStorageNotice` and `multisigKeyExpression()`, recomputed only when they
changed (every account's receive address is a derivation). -/
def overview (env : Env) (a : MultisigApp) : IO MultisigOverview := do
  let store ← a.host.read
  let signers ← a.signers.read
  let key ← match (← env.get).wallet with
    | some w => pure (((← (ownKeyExpression w true).run).toOption))
    | none => pure none
  let ownKey := (← env.get).wallet.bind walletAccountKey? |>.map (·.publicKey)
  let k : OverviewKey :=
    { records := store.records, signers := signers.records, notice := ← a.host.notice.get,
      signerNotice := ← a.signers.notice.get, key, tip := ← chainTip env }
  if let some (k', o) ← a.overviewCache.get then
    if k' == k then return o
  let o : MultisigOverview :=
    { accounts := store.records.toList.map (info · store.network signers.records ownKey), notice := k.notice,
      keyExpression := key,
      ownFingerprint := key.map (signerFingerprint · store.network),
      signers := signers.records.toList.map (signerInfo · store.network), signerNotice := k.signerNotice }
  a.overviewCache.set (some (k, o))
  return o

end WinnowApp.Real
