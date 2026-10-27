import WinnowApp.Common
import Winnow.Wallet.People
import Winnow.Keys.Taproot

/-! MultisigViews.swift and MultisigBuildView.swift (upstream 1cf93fb): raw k-of-n multisig accounts in
Advanced mode's Wallet tab only — the Multisig section, MultisigAddView ("Join with a descriptor"),
MultisigBuildView ("New multisig account"), MultisigAccountView and MultisigPSBTView (a PSBT created or
pasted, reviewed against the account's own coins, signed here, combined with the other signers' copies,
finalized and broadcast), and MultisigLiteralRow / MultisigValueRow.

Left out until the Ledger lands, with no stub: "Pair a Ledger (2-of-2)", the builder's "Include a Ledger",
the account's "Verify on Ledger", and "Sign with Ledger". The texts that depend on a paired Ledger (the
signing footer) already follow a record's registration. -/

namespace WinnowApp
open ElmLean

/-! ## Update -/

def Model.multisigInfo? (m : Model) (id : String) : Option MultisigInfo := m.multisig.accounts.find? (·.id == id)

def Model.multisigPSBTRoute? (m : Model) : Option String :=
  match m.routes.getLast? with
  | some (.multisigPSBT id) => some id
  | _ => none

/-- `Int64(text)`: an optional sign and decimal digits, nothing else, within Int64's range. -/
def swiftInt64? (text : String) : Option Int :=
  let (neg, digits) := match text.toList with
    | '-' :: rest => (true, rest)
    | '+' :: rest => (false, rest)
    | cs => (false, cs)
  if digits.isEmpty || !digits.all Char.isDigit then none else
  let n := (String.ofList digits).toNat!
  let v : Int := if neg then -(n : Int) else n
  if v < -(2 ^ 63 : Int) || v ≥ (2 ^ 63 : Int) then none else some v

/-- `String(format: "%.1f", rate)` of a rate in thousandths. -/
def oneDecimal (milli : Nat) : String :=
  let tenths := (milli + 50) / 100
  s!"{tenths / 10}.{tenths % 10}"

/-- MultisigBuildView.blocks(forDays:): about 144 blocks a day; BIP68 counts at most 65,535 blocks. -/
def recoveryBlocks (days : Nat) : Nat := min (days * 144) 0xFFFF

/-- `recoveryPlan`. -/
def MultisigBuildForm.recoveryPlan (f : MultisigBuildForm) : Option MultisigRecovery :=
  if !f.withRecovery then none
  else if f.recoveryMode == 0 then some (.fewerSigners f.recoveryThreshold (recoveryBlocks f.recoveryDays))
  else some (.separateKey f.recoveryKey.trimAscii.copy (recoveryBlocks f.recoveryDays))

/-- `.onChange(of: signerCount)`: both thresholds stay within 1 … signers. -/
def MultisigBuildForm.clamp (f : MultisigBuildForm) : MultisigBuildForm :=
  let n := f.signerCount
  { f with threshold := min (max f.threshold 1) n, recoveryThreshold := min (max f.recoveryThreshold 1) n }

def MultisigBuildForm.canCreate (f : MultisigBuildForm) : Bool :=
  !f.creating && (Winnow.DisplayName.normalized f.name).isSome && f.signerCount ≥ 2 &&
    !(f.withRecovery && f.recoveryMode == 1 && f.recoveryKey.isEmpty)

/-- The descriptor text as MultisigAddView validates it (trimmed; nothing while empty). -/
def MultisigAddForm.trimmed (f : MultisigAddForm) : String := Winnow.Keys.Unicode.trimWhitespace f.descriptor

def MultisigAddForm.validation (f : MultisigAddForm) : Option (Except String MultisigCheck) :=
  match f.check with
  | some (text, r) => if text == f.trimmed then some r else none
  | none => none

def MultisigAddForm.canSave (f : MultisigAddForm) : Bool :=
  !f.saving && (Winnow.DisplayName.normalized f.name).isSome && (f.validation.any fun r => r matches .ok _)

/-- MultisigPSBTView's `clearState` (leaving or backgrounding): the proposal goes; the shared PSBT text is
the only copy that travels between signers. -/
def MultisigSpendForm.cleared (f : MultisigSpendForm) : MultisigSpendForm :=
  { f with epoch := f.epoch + 1, busy := false, working := none, pasted := "", trusted := "" }

/-- Leave the innermost multisig screen (its state goes with it). -/
def Model.popMultisig (m : Model) : Model :=
  let m' := match m.routes.getLast? with
    | some (.multisigPSBT _) => { m with multisigSpend := m.multisigSpend.cleared }
    | some .multisigAdd => { m with multisigAdd := {} }
    | some .multisigBuild => { m with multisigBuild := {} }
    | some (.multisigAccount _) => { m with multisigAccountError := none }
    | _ => m
  { m' with routes := m'.routes.dropLast }

/-- The PSBT in hand, installed (`install`), for the account state it was reviewed against. -/
def Model.installPSBT (m : Model) (id : String) (p : MultisigPSBT) : Model :=
  let trusted := ((m.multisigInfo? id).map (·.trusted)).getD ""
  { m with multisigSpend := { m.multisigSpend with working := some p, trusted } }

/-- Begin an operation of the PSBT screen (`run`): a new epoch, busy, no error. -/
def Model.runPSBT (m : Model) : Model × Nat :=
  let e := m.multisigSpend.epoch + 1
  ({ m with multisigSpend := { m.multisigSpend with epoch := e, busy := true, error := none } }, e)

def stepMultisig (msg : MultisigMsg) (m : Model) : Model × List Cmd :=
  let g := m.generation
  let add := m.multisigAdd
  let build := m.multisigBuild
  let spend := m.multisigSpend
  let withAdd (f : MultisigAddForm) : Model := { m with multisigAdd := f }
  let withBuild (f : MultisigBuildForm) : Model := { m with multisigBuild := f }
  let withSpend (f : MultisigSpendForm) : Model := { m with multisigSpend := f }
  match msg with
  | .openAdd => ({ m with routes := m.routes ++ [.multisigAdd], multisigAdd := {} }, [])
  | .openBuild => ({ m with routes := m.routes ++ [.multisigBuild], multisigBuild := {} }, [])
  | .openAccount id => ({ m with routes := m.routes ++ [.multisigAccount id], multisigAccountError := none }, [.multisigOverview g])
  | .openPSBT id =>
    ({ m with routes := m.routes ++ [.multisigPSBT id], multisigSpend := { epoch := spend.epoch + 1 } }, [.multisigFeeRate g])
  | .pop => (m.popMultisig, [])
  -- MultisigAddView
  | .setName s => (withAdd { add with name := s }, [])
  | .setDescriptor s =>
    let f := { add with descriptor := s }
    let text := f.trimmed
    if text.isEmpty then (withAdd { f with check := none }, [])
    else (withAdd f, [.checkMultisigDescriptor g text])
  | .pasteDescriptor => (m, [.paste .multisigDescriptor])
  | .save =>
    if !add.canSave then (m, []) else
    (withAdd { add with saving := true, error := none }, [.addMultisigAccount g add.name add.descriptor])
  -- MultisigBuildView
  | .buildSetName s => (withBuild { build with name := s }, [])
  | .pasteSignerKey => (m, [.paste .multisigSignerKey])
  | .removeSignerKey i => (withBuild { build with otherKeys := build.otherKeys.eraseIdx i }.clamp, [])
  | .setThreshold n => (withBuild { build with threshold := n }, [])
  | .setWithRecovery b => (withBuild { build with withRecovery := b }, [])
  | .setRecoveryMode i => (withBuild { build with recoveryMode := if i == 1 then 1 else 0 }, [])
  | .setRecoveryThreshold n => (withBuild { build with recoveryThreshold := n }, [])
  | .pasteRecoveryKey => (m, [.paste .multisigRecoveryKey])
  | .removeRecoveryKey => (withBuild { build with recoveryKey := "" }, [])
  | .setRecoveryDays n => (withBuild { build with recoveryDays := min (max n 1) 455 }, [])
  | .create =>
    if !build.canCreate then (m, []) else
    (withBuild { build with creating := true, error := none },
     [.createMultisigAccount g m.settings.advancedMode build.name build.threshold build.otherKeys build.recoveryPlan])
  -- MultisigAccountView
  | .newAddress =>
    match m.routes.getLast? with
    | some (.multisigAccount id) => ({ m with multisigAccountError := none }, [.newMultisigAddress g id])
    | _ => (m, [])
  | .askRemove =>
    match m.routes.getLast? with
    | some (.multisigAccount id) => ({ m with confirm := some (.removeMultisig id) }, [])
    | _ => (m, [])
  | .remove =>
    match m.confirm with
    | some (.removeMultisig id) => ({ m with confirm := none, multisigAccountError := none }, [.removeMultisigAccount g id])
    | _ => (m, [])
  -- MultisigPSBTView
  | .setAddress s => (withSpend { spend with address := s }, [])
  | .setAmount s => (withSpend { spend with amount := s }, [])
  | .setFeeRate s => (withSpend { spend with feeRate := s }, [])
  | .setPath i => (withSpend { spend with recovery := i == 1 }, [])
  | .createSpend =>
    match m.multisigPSBTRoute?, swiftInt64? spend.amount, parseDouble spend.feeRate with
    | some id, some amount, some rate =>
      if spend.busy || spend.address.trimAscii.isEmpty then (m, []) else
      let (m', e) := m.runPSBT
      (m', [.createMultisigSpend g e id spend.address amount rate spend.recovery])
    | _, _, _ => (m, [])
  | .setPasted s => (withSpend { spend with pasted := s }, [])
  | .pastePSBT => (m, [.paste .multisigPSBT])
  | .addPasted =>
    match m.multisigPSBTRoute? with
    | some id =>
      if spend.busy || spend.pasted.trimAscii.isEmpty then (m, []) else
      (withSpend { spend with error := none }, [.addMultisigPSBT g spend.epoch id (spend.working.map (·.psbt)) spend.pasted])
    | none => (m, [])
  | .sign =>
    match m.multisigPSBTRoute?, spend.working with
    | some id, some w =>
      let ok := w.screen.any fun s => s.progress.phoneUnsigned && !s.progress.complete
      if spend.busy || !ok then (m, []) else
      let (m', e) := m.runPSBT
      (m', [.signMultisigSpend g e id w.psbt])
    | _, _ => (m, [])
  | .broadcast =>
    match m.multisigPSBTRoute?, spend.working with
    | some id, some w =>
      if spend.busy || !(w.screen.any (·.progress.complete)) then (m, []) else
      if m.spendingInFlight then
        (withSpend { spend with error := some "Another payment is already being signed and broadcast. Wait for it to finish." }, [])
      else
        let (m', e) := m.runPSBT
        ({ m' with spendingInFlight := true }, [.broadcastMultisigSpend g e id w.psbt])
    | _, _ => (m, [])

/-- The backend's multisig answers (`onHost` hands them here). -/
def Model.onMultisigHost (m : Model) (h : Host) : Model × List Cmd :=
  let current (g : Nat) := g == m.generation
  let spend := m.multisigSpend
  -- an answer for the PSBT screen counts only while it shows that account and the operation's epoch lasts
  let accepts (g e : Nat) (id : String) := current g && e == spend.epoch && m.multisigPSBTRoute? == some id && m.active
  match h with
  | .multisig g o =>
    if !current g then (m, []) else
    let m' := { m with multisig := o }
    -- `.task(id: trustedState)`: the account's coins or frontiers moved under the PSBT in hand
    match m'.multisigPSBTRoute?, spend.working with
    | some id, some w =>
      let now := ((m'.multisigInfo? id).map (·.trusted)).getD ""
      if now != spend.trusted && !spend.busy then
        ({ m' with multisigSpend := { spend with trusted := now } }, [.reviewMultisigPSBT g spend.epoch id w.psbt])
      else (m', [])
    | _, _ => (m', [])
  | .multisigChecked g text r =>
    if current g && m.multisigAdd.trimmed == text then ({ m with multisigAdd := { m.multisigAdd with check := some (text, r) } }, [])
    else (m, [])
  | .multisigAdded g _ =>
    if !current g then (m, []) else
    let m' := { m with multisigAdd := { m.multisigAdd with saving := false } }
    -- `dismiss()`
    (if m'.routes.getLast? == some .multisigAdd then m'.popMultisig else m', [.multisigOverview g])
  | .multisigCreated g id d =>
    if !current g then (m, []) else
    ({ m with multisigBuild := { m.multisigBuild with creating := false, created := some (id, d) } }, [.multisigOverview g])
  | .multisigRemoved g id =>
    if !current g then (m, []) else
    (if m.routes.getLast? == some (.multisigAccount id) then m.popMultisig else m, [.multisigOverview g])
  | .multisigFeeRate g milli =>
    if current g && spend.feeRate.isEmpty && m.multisigPSBTRoute?.isSome then
      ({ m with multisigSpend := { spend with feeRate := oneDecimal milli } }, [])
    else (m, [])
  | .multisigPSBT g e id p fromPaste =>
    if !accepts g e id then (m, []) else
    let m' := m.installPSBT id p
    ({ m' with multisigSpend := { m'.multisigSpend with busy := false, pasted := if fromPaste then "" else spend.pasted } }, [])
  | .multisigBroadcast g e id txid =>
    let m := { m with spendingInFlight := false }
    if !accepts g e id then (m, [.refresh m.generation]) else
    ({ m with multisigSpend := { spend with busy := false, broadcastTxid := some txid } }, [.multisigOverview g, .refresh g])
  | _ => (m, [])

/-! ## View -/

/-- MultisigLiteralRow: a literal (an address, a key expression) with a copy button (below it: beside a
literal this long the renderer's row leaves the button no room). -/
def literalRow (m : Model) (key text : String) : H :=
  .col [caption text, .button (if m.copied == some key then "Copied" else "Copy") .plain (some (.copy key text))]

/-- The Wallet tab's multisig section. -/
def multisigSection (m : Model) : H :=
  .section "Multisig" "k-of-n Taproot accounts with other Winnows, a Ledger or any signer, shared as a descriptor and spent with PSBTs. Any k signers spend at once; an optional recovery path lets fewer signers, or a separate key, spend a coin that has not moved for a set number of blocks."
    ((match m.multisig.notice with | some n => [body n] | none => []) ++
     (m.multisig.accounts.map fun a =>
        .row [.button a.name .plain (some (.multisig (.openAccount a.id))), .spacer, body (satsText a.balance)]) ++
     [ .button "New multisig account" .plain (some (.multisig .openBuild))
     , .button "Join with a descriptor" .plain (some (.multisig .openAdd)) ])

def errorSection (e : Option String) : List H :=
  match e with
  | some text => [.section "" "" [body text]]
  | none => []

/-- MultisigAddView ("Add multisig account"). -/
def multisigAddSections (m : Model) : List H :=
  let f := m.multisigAdd
  let set (g : String → MultisigMsg) : String → Msg := fun s => .multisig (g s)
  [ .section "" "Winnow watches the account from the next block it scans. Coins the account received before that are not found."
      [.input .plain "" "Name" f.name (set .setName) none]
  , .section "This phone's key" "One signer must be this key. Every signer is an extended public key with its origin and the /<0;1>/* suffix; the internal key is the unspendable NUMS point."
      (match m.multisig.keyExpression with
       | some key =>
         [ literalRow m "multisig.key" key
         , copyableIdentifier m "multisig.template"
             s!"tr({Winnow.hex Winnow.Keys.Taproot.unspendableInternalKey},sortedmulti_a(2,{key},OTHER_KEY))"
             (abbreviated := true) (label := "Copy 2-of-2 template") ]
       | none => [caption "This wallet has no shareable account key."])
  , .section "Descriptor" ""
      ([ .input .multiline "" "tr(NUMS,sortedmulti_a(k,…))" f.descriptor (set .setDescriptor) none
       , .button "Paste" .plain (some (.multisig .pasteDescriptor)) ] ++
       (match f.validation with
        | some (.ok c) =>
          [.labeled "Policy" c.policy] ++
          (match c.firstAddress with | some a => [.col [caption "First address", caption a]] | none => [])
        | some (.error e) => [body e]
        | none => [])) ] ++
  errorSection f.error

def multisigAddScreen (m : Model) (inner : List H) : H :=
  let f := m.multisigAdd
  .screen "Add multisig account" (some (.multisig .pop))
    ([ .toolbar [.button (if f.saving then "Saving…" else "Save") .primary (if f.canSave then some (.multisig .save) else none)]
     , .list (multisigAddSections m) ] ++ inner)

/-- MultisigBuildView ("New multisig account"). -/
def multisigBuildSections (m : Model) : List H :=
  let f := m.multisigBuild
  let n := f.signerCount
  match f.created with
  | some (id, descriptor) =>
    [.section "" "Every other signer adds this same descriptor under Join with a descriptor. Check that each one shows the same first address."
      [ .text "Account created" .title, .qr descriptor, copyableBlock m "multisig.created" descriptor
      , .button "Open the account" .plain (some (.multisig (.openAccount id))) ]]
  | none =>
    [ .section "" "" [.input .plain "" "Name" f.name (fun s => .multisig (.buildSetName s)) none]
    , .section s!"Signers · {n}" "Another Winnow shows its key under Join with a descriptor → This phone's key. Any signer's key works: [fingerprint/path]xpub…/<0;1>/*."
        ((match m.multisig.keyExpression with
          | some key => [.col [caption "This phone", literalRow m "multisig.build.key" key]]
          | none => []) ++
         (f.otherKeys.zipIdx.map fun (k, i) =>
            .col [caption k, .button "Remove" .destructive (some (.multisig (.removeSignerKey i)))]) ++
         [.button "Paste a signer's key" .plain (some (.multisig .pasteSignerKey))])
    , .section "" ""
        [.stepper s!"Any {f.threshold} of {n} spend at once" f.threshold 1 (max n 1) (fun k => .multisig (.setThreshold k)) " "]
    , .section "" (if f.withRecovery then "The delay counts from when each coin is received. Once it passes, the recovery path can spend that coin without the other signers, so move coins before then if you do not want that." else "")
        ([.toggle "Recovery after a delay" f.withRecovery (fun b => .multisig (.setWithRecovery b))] ++
         (if !f.withRecovery then [] else
           [.picker "After the delay" ["Fewer signers", "A recovery key"] f.recoveryMode (fun i => .multisig (.setRecoveryMode i))] ++
           (if f.recoveryMode == 0 then
             [.stepper s!"Any {f.recoveryThreshold} of the {n} signers" f.recoveryThreshold 1 (max n 1)
                (fun k => .multisig (.setRecoveryThreshold k)) " "]
            else if f.recoveryKey.isEmpty then
             [.button "Paste the recovery key" .plain (some (.multisig .pasteRecoveryKey))]
            else
             [caption f.recoveryKey, .button "Remove the recovery key" .destructive (some (.multisig .removeRecoveryKey))]) ++
           [.stepper s!"After {f.recoveryDays} days ({recoveryBlocks f.recoveryDays} blocks)" f.recoveryDays 1 455
              (fun k => .multisig (.setRecoveryDays k)) " "]))
    , .section "" "Winnow watches the account from the next block it scans."
        [.button (if f.creating then "Creating…" else "Create account") .primary (if f.canCreate then some (.multisig .create) else none)] ] ++
    errorSection f.error

/-- MultisigAccountView. -/
def multisigAccountSections (m : Model) (id : String) : List H :=
  match m.multisigInfo? id with
  | some a =>
    match a.policy with
    | some policy =>
      [ .section "" ""
          ([.labeled "Balance" (satsText a.balance), .labeled "Policy" policy] ++
           (match a.recovery with | some r => [.labeled "Recovery" r] | none => []) ++
           (match a.ledgerFingerprint with | some fp => [.labeled "Ledger" fp] | none => []))
      , .section s!"Receive · index {a.nextReceiveIndex}" "The same address on every signer's device: check it there before sharing it."
          ((match a.receiveAddress with
            | some address => [.qr address, literalRow m "multisig.receive" address]
            | none => []) ++
           [.button "New address" .plain (some (.multisig .newAddress))])
      , .section "Spend" "" [.button "New or pasted PSBT" .plain (some (.multisig (.openPSBT a.id)))]
      , .section "Coins" ""
          ((if a.coins.isEmpty then [caption "No coins yet."] else []) ++
           a.coins.map fun c =>
             .col ([body (satsText c.amount), caption c.line] ++
                   (match c.recoveryFrom with | some h => [caption s!"recovery path from block {h}"] | none => [])))
      , .section "Descriptor" "" [copyableBlock m "multisig.descriptor" a.descriptor]
      , .section "" "" [.button "Remove account" .destructive (some (.multisig .askRemove))] ] ++
      errorSection m.multisigAccountError
    | none => [.section "" "" [caption "This multisig account is no longer on this phone."]] ++ errorSection m.multisigAccountError
  | none => [.section "" "" [caption "This multisig account is no longer on this phone."]] ++ errorSection m.multisigAccountError

/-- MultisigPSBTView ("Multisig PSBT"). -/
def multisigPSBTSections (m : Model) (id : String) : List H :=
  let f := m.multisigSpend
  let set (g : String → MultisigMsg) : String → Msg := fun s => .multisig (g s)
  match f.broadcastTxid with
  | some txid => [.section "" "" [.text "Payment sent" .title, literalRow m "multisig.txid" txid]]
  | none =>
    let hasRecovery := ((m.multisigInfo? id).map (·.hasRecovery)).getD false
    let canCreate := !f.busy && (swiftInt64? f.amount).isSome && (parseDouble f.feeRate).isSome && !f.address.trimAscii.isEmpty
    let create : List H :=
      if f.working.isSome then [] else
      [.section "New payment"
        (if f.recovery then "Only coins that have not moved for the recovery delay can be spent this way. Change returns to this account's next change address."
         else "Change returns to this account's next change address. The fee may be at most a tenth of the coins spent.")
        ((if hasRecovery then [.picker "Spend with" ["Signers now", "Recovery path"] (if f.recovery then 1 else 0) (fun i => .multisig (.setPath i))] else []) ++
         [ .input .plain "" "Address" f.address (set .setAddress) none
         , .input .number "" "Amount (sats)" f.amount (set .setAmount) none
         , .input .decimal "" "Fee rate (sat/vB)" f.feeRate (set .setFeeRate) none
         , .button "Create PSBT" .plain (if canCreate then some (.multisig .createSpend) else none) ])]
    let paste : H :=
      .section (if f.working.isNone then "Or paste a PSBT" else "Another signer's PSBT")
        "A pasted PSBT is combined with the one here. Winnow signs only a spend of coins this account already has."
        [ .input .multiline "" "Paste a PSBT (Base64)" f.pasted (set .setPasted) none
        , .button "Paste from clipboard" .plain (some (.multisig .pastePSBT))
        , .button (if f.working.isNone then "Use this PSBT" else "Combine") .plain
            (if f.busy || f.pasted.trimAscii.isEmpty then none else some (.multisig .addPasted)) ]
    let review : List H := match f.working with
      | none => []
      | some w =>
        [.section "Check this payment" "Check the addresses, amounts and fee on every signer's device before signing."
          (match w.screen with
           | some s =>
             (s.outputs.map fun o =>
                .col [.row [caption (if o.owned then "Back to this account" else "Pays"), .spacer, body (satsText o.amount)],
                      caption o.address]) ++
             [.labeled "Inputs" (satsText s.inputTotal), .labeled "Fee" (satsText s.fee)] ++
             (s.signatures.map fun (recovery, approved, threshold) =>
                .labeled (if recovery then "Recovery signatures" else "Signatures") s!"{approved} of {threshold}")
           | none =>
             [ .row [.icon "exclamationmark.triangle.fill", body "Winnow cannot safely review this PSBT"]
             , body (w.reviewError.getD "The account or PSBT is unavailable.") ])] ++
        (match w.screen with
         | some s =>
           let p := s.progress
           [.section (if s.recoveryUsable then "Signing · signers or recovery path" else "Signing") p.nextStep
             [ .button "Add this phone's signature" .plain
                 (if f.busy || !p.phoneUnsigned || p.complete then none else some (.multisig .sign))
             , .button (if f.busy then "Working…" else "Finalize and broadcast") .primary
                 (if f.busy || !p.complete then none else some (.multisig .broadcast)) ]]
         | none => [])
    let output : List H := match f.working.bind (·.output) with
      | some text => [.section "PSBT to share" "" [copyableBlock m "multisig.psbt" text]]
      | none => []
    create ++ [paste] ++ review ++ errorSection f.error ++ output

end WinnowApp
