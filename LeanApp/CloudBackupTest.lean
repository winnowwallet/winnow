import WinnowApp.Real.CloudAppState
import Lean.Data.Json

/-! `cloud-backup-test`: the encrypted iCloud recovery formats, headless.

* upstream d2ca878's `CloudWalletBackupTests` (all six), `CloudAppStateTests` (all three) and the restore
  halves of `CloudBackupTests` (what a backup restores, and the digest an automatic update compares);
  the controller around them (iCloud Keychain, CloudKit, scheduling) needs the shell and is not here;
* `../Lean/Vectors/cloud-backup.json`, written by upstream's `CloudWalletBackup.swift` (verbatim, over a
  copy of d2ca878's WalletCore): its version 1 and version 2 backups open here, its `wallet-…` purposes
  and the backup digest (and the canonical JSON under it) match byte for byte.

`--write <dir>` also leaves a Lean-made backup (`lean-backup.json`) and its key (`lean-backup.key`) there for
the Swift side to open. Run from `LeanApp/`. Exits 1 on any failure. -/

open Winnow WinnowApp WinnowApp.RecordsReal Keys
open Tx (BitcoinNetwork)

initialize passed : IO.Ref Nat ← IO.mkRef 0
initialize failures : IO.Ref (Array String) ← IO.mkRef #[]

def check (name : String) (ok : Bool) (detail : String := "") : IO Unit := do
  if ok then passed.modify (· + 1)
  else
    failures.modify (·.push name)
    IO.println s!"FAIL {name}{if detail.isEmpty then "" else ": " ++ detail}"

abbrev TM := ExceptT String IO

def wm {α} (name : String) (x : WM α) : TM α := do
  match ← x.run with
  | .ok a => pure a
  | .error e => throw s!"{name}: {e.name}"

def rm {α} (name : String) (x : RM α) : TM α := do
  match ← x.run with
  | .ok a => pure a
  | .error e => throw s!"{name}: {e.name}: {e.description}"

def refusedW {α} (x : WM α) : IO Bool := do return (← x.run).toOption.isNone
def refusedR {α} (x : RM α) : IO Bool := do return (← x.run).toOption.isNone

def runTest (name : String) (t : TM Unit) : IO Unit := do
  match ← t.run with
  | .ok () => pure ()
  | .error msg =>
    failures.modify (·.push name)
    IO.println s!"FAIL {name} (aborted): {msg}"

def newKeys : IO (KeyStore IO) := do return inMemoryKeyStore (← IO.mkRef {})

def walletBundle (network : BitcoinNetwork) (fill : UInt8) : TM ImportBundle := do
  let w ← wm "create" (Wallet.create network (← newKeys) none (some (ByteArray.mk (Array.replicate 16 fill))) 100)
  wm "export" (w.exportBundle (includeMnemonic := true))

def randomKey : IO ByteArray := IO.getRandomBytes 32

def contains (haystack needle : String) : Bool := (haystack.splitOn needle).length > 1

def jsonOf (b : CloudWalletBackup) : TM Lean.Json := do
  let text := String.fromUTF8! (← wm "encode" b.encoded)
  match Lean.Json.parse text with | .ok j => pure j | .error e => throw e

def bytesOfJson (j : Lean.Json) : ByteArray := j.compress.toUTF8

/-! ## CloudWalletBackupTests -/

def roundTripRestoresSigningAndAddressCounters : TM Unit := do
  let original := { (← walletBundle .signet 7) with nextReceiveIndex := some 19, nextChangeIndex := some 8 }
  let key ← randomKey
  let encrypted ← wm "create" (CloudWalletBackup.create original key)
  let data ← wm "encode" encrypted.encoded
  check "round trip: the file does not hold the words" (!contains (String.fromUTF8! data) original.mnemonic.get!)
  let restored ← wm "restore" ((← wm "decode" (CloudWalletBackup.decode data)).restoredBundle key)
  check "round trip: the bundle comes back whole" (restored == original)
  let keys ← newKeys
  let wallet ← wm "import" (Wallet.importing restored keys)
  check "round trip: importing it stores the words" (match ← (keys.load wallet.id).run with
    | .ok s => s == .mnemonic original.mnemonic.get! | .error _ => false)

def automaticUpdateKeepsTheSealedKeyAndNewHistoryFrontier : TM Unit := do
  let original ← walletBundle .signet 7
  let key ← randomKey
  let first ← wm "create" (CloudWalletBackup.create original key)
  let next := { original with mnemonic := none, lastKnownHeight := 123, nextReceiveIndex := some 5 }
  let updated ← wm "update" (first.updating next key)
  check "update: the phrase box is kept" (updated.sealedPhrase == first.sealedPhrase)
  let restored ← wm "restore" (updated.restoredBundle key)
  check "update: the words, the new frontier and the new cursor"
    (restored.mnemonic == original.mnemonic && restored.lastKnownHeight == 123 && restored.nextReceiveIndex == some 5)

def wrongKeyAndModifiedMetadataAreRejected : TM Unit := do
  let key ← randomKey
  let original ← walletBundle .signet 7
  let backup ← wm "create" (CloudWalletBackup.create original key)
  check "tamper: a wrong key" (← refusedW (backup.restoredBundle (← randomKey)))
  let json ← jsonOf backup
  let zeros := Base64.encode (ByteArray.mk (Array.replicate 40 0))
  for (field, value) in [("id", Lean.Json.str (← UUIDText.random)), ("network", .str "mainnet"), ("savedAt", (1 : Nat)),
                         ("sealedWallet", .str zeros), ("sealedPhrase", .str zeros)] do
    let changed := bytesOfJson (json.setObjVal! field value)
    check s!"tamper: a changed {field} is refused"
      (← refusedW (do (← CloudWalletBackup.decode changed).restoredBundle key))
  check "tamper: version 3 does not decode" (← refusedW (CloudWalletBackup.decode (bytesOfJson (json.setObjVal! "version" (3 : Nat)))))

def appContextIsEncryptedAndUpdatesWithoutReadingThePhrase : TM Unit := do
  let original ← walletBundle .signet 7
  let key ← randomKey
  let metadata := "private contact and invoice label".toUTF8
  let first ← wm "create" (CloudWalletBackup.create original key (appState := some metadata))
  check "app data: not in the clear" (!contains (String.fromUTF8! (← wm "encode" first.encoded)) "invoice label")
  check "app data: restored" ((← wm "app state" (first.restoredAppState key)) == some metadata)
  let publicBundle := { original with mnemonic := none }
  let edited := "edited local notes".toUTF8
  let second ← wm "update" (first.updating publicBundle key (appState := some edited))
  check "app data: the phrase box is kept" (second.sealedPhrase == first.sealedPhrase)
  check "app data: replaced" ((← wm "app state" (second.restoredAppState key)) == some edited)
  check "app data: the bundle is unchanged" ((← wm "restore" (second.restoredBundle key)) == original)
  check "app data: past 10 MiB is refused"
    (← refusedW (first.updating publicBundle key
      (appState := some (ByteArray.mk (Array.replicate (CloudWalletBackup.maximumAppStateBytes + 1) 0)))))

/-- A version 1 backup as upstream's test makes it (the bundle's `serialized()` text sealed alone). -/
def legacyBackup (original : ImportBundle) (key : ByteArray) (id : String) (savedAt : Float) : TM CloudWalletBackup := do
  let ctx (purpose : String) := CloudWalletBackup.context id original.network purpose
  let sealWith (pt aad : ByteArray) : TM ByteArray := do
    match ← AESGCM.sealRandom key pt aad with
    | .ok b => pure b.combined.get!
    | .error e => throw e.name
  let publicBundle := { original with mnemonic := none }
  let phrase ← sealWith original.mnemonic.get!.toUTF8 (ctx "phrase")
  let wallet ← sealWith publicBundle.serialized.toUTF8 (ctx (CloudWalletBackup.walletPurpose savedAt))
  return { version := 1, id, network := original.network, savedAt, sealedPhrase := phrase, sealedWallet := wallet }

def legacyBackupRestoresAndUpgradesWithoutLosingItsKey : TM Unit := do
  let original ← walletBundle .signet 7
  let key ← randomKey
  -- Date(timeIntervalSince1970: 1_700_000_000)
  let legacy ← legacyBackup original key (← UUIDText.random) (1_700_000_000 - 978_307_200)
  let loaded ← wm "decode" (CloudWalletBackup.decode (← wm "encode" legacy.encoded))
  check "legacy: restores" ((← wm "restore" (loaded.restoredBundle key)) == original)
  check "legacy: has no app data" ((← wm "app state" (loaded.restoredAppState key)) == none)
  let upgraded ← wm "upgrade" (loaded.updating { original with mnemonic := none } key (appState := some "notes".toUTF8))
  check "legacy: upgrades to version 2 with its phrase box" (upgraded.version == 2 && upgraded.sealedPhrase == legacy.sealedPhrase)
  check "legacy: the upgrade restores" ((← wm "restore" (upgraded.restoredBundle key)) == original &&
    (← wm "app state" (upgraded.restoredAppState key)) == some "notes".toUTF8)
  let downgraded := bytesOfJson ((← jsonOf upgraded).setObjVal! "version" (1 : Nat))
  check "legacy: a version 2 box called version 1 does not restore"
    (← refusedW (do (← CloudWalletBackup.decode downgraded).restoredBundle key))

def mismatchedWalletAndMissingPhraseAreRefused : TM Unit := do
  let original ← walletBundle .signet 7
  let key ← randomKey
  let backup ← wm "create" (CloudWalletBackup.create original key)
  let other := { original with descriptor := some "different wallet" }
  check "mismatch: another wallet does not update it" (← refusedW (backup.updating other key))
  check "mismatch: no words, no backup" (← refusedW (CloudWalletBackup.create { other with mnemonic := none } key))
  check "mismatch: past 32 MiB does not decode"
    (← refusedW (CloudWalletBackup.decode (ByteArray.mk (Array.replicate (CloudWalletBackup.maximumBytes + 1) 0))))

/-! ## CloudBackupTests (the restore halves) -/

def cloudBackupRestores : TM Unit := do
  let bundle ← walletBundle .signet 9
  let key ← randomKey
  let first ← wm "enable" (CloudWalletBackup.create bundle key (appState := some "before".toUTF8))
  let watchOnly := { bundle with mnemonic := none }
  let before : CloudBackupContents := { bundle := watchOnly, appState := some "before".toUTF8 }
  let after : CloudBackupContents := { bundle := watchOnly, appState := some "after".toUTF8 }
  check "contents: only changing the app data changes the digest" (before.digest != after.digest)
  check "contents: the words are not part of the digest"
    (({ before with bundle := bundle } : CloudBackupContents).digest == before.digest)
  let second ← wm "update" (first.updating watchOnly key (appState := after.appState))
  check "contents: the app data and the whole bundle restore"
    ((← wm "app state" (second.restoredAppState key)) == some "after".toUTF8 &&
     (← wm "restore" (second.restoredBundle key)) == bundle)

/-! ## CloudAppStateTests -/

structure Fixture where
  bundle : ImportBundle
  state : CloudAppState
  dir : System.FilePath

def fixture : TM Fixture := do
  let dir ← IO.FS.createTempDir
  let bundle ← walletBundle .mainnet 8
  let payTo ← match PersonPayTo.ofAddress "1BoatSLRHtKNngkdXEeobR76b53LETtpyT" .mainnet with
    | .ok p => pure p | .error e => throw e
  let person : PersonRecord := { id := ← UUIDText.random, name := "Saved friend", payTo := some payTo, nextPaymentIndex := 17 }
  let script ← match AddressDecoder.scriptPubKey "1BoatSLRHtKNngkdXEeobR76b53LETtpyT" .mainnet with
    | .ok s => pure s | .error _ => throw "script"
  let state : CloudAppState := {
    network := bundle.network, descriptor := bundle.descriptor,
    people := { people := #[person], senderByTxid := #[(String.join (List.replicate 32 "01"), person.id)] },
    receiveLabels := #[(hex script, "Private invoice")], ownDisplayName := "Me", advancedMode := true }
  return { bundle, state, dir }

def peopleStore (dir : System.FilePath) : TM PeopleStore := do
  let vault := StoreKeyVault.inMemory (← IO.mkRef {})
  let (s, _) ← PeopleStore.configure vault (some (dir / "people.json")) .mainnet
  return s

def cloudContextRoundTrips : TM Unit := do
  let f ← fixture
  let restored ← match ← rm "decode" (CloudAppState.decode (some f.state.encoded) f.bundle) with
    | some r => pure r | none => throw "no context"
  check "context: round trips" (restored == f.state)
  let vault := StoreKeyVault.inMemory (← IO.mkRef {})
  let (people, _) ← PeopleStore.configure vault (some (f.dir / "people.json")) .mainnet
  let plan ← rm "plan" (people.planRestore restored.people)
  let people ← rm "restore" (people.restore vault writeAtomically plan)
  check "context: the address book restores" ((← rm "backup" people.backup) == f.state.people)
  let labels ← LabelStore.open (some (f.dir / "labels.json")) "restored" .mainnet
  let labels ← rm "labels restore" (labels.restore writeAtomically restored.receiveLabels)
  let sorted (xs : Array (String × String)) := (xs.toList.mergeSort fun a b => !(b.1 < a.1)).toArray
  check "context: the receive notes restore" (sorted (← rm "labels backup" labels.backup) == sorted f.state.receiveLabels)
  let reopened ← LabelStore.open (some (f.dir / "labels.json")) "restored" .mainnet
  check "context: the receive notes are on disk" (sorted (← rm "reopened" reopened.backup) == sorted f.state.receiveLabels)
  check "context: the manual export stays without the address book" (!contains f.bundle.serialized "Saved friend")
  check "context: older backups have none" ((← rm "none" (CloudAppState.decode none f.bundle)).isNone)

def existingContactsAndNewerPaymentCounterSurviveRestore : TM Unit := do
  let f ← fixture
  let vault := StoreKeyVault.inMemory (← IO.mkRef {})
  let (store, _) ← PeopleStore.configure vault (some (f.dir / "people.json")) .mainnet
  let p := f.state.people.people[0]!
  let mine : PeopleStore.Backup :=
    { people := #[{ p with id := ← UUIDText.random, name := "Current local name", nextPaymentIndex := 24 }], senderByTxid := #[] }
  let store ← rm "restore local" (store.restore vault writeAtomically mine)
  let merged ← rm "plan" (store.planRestore f.state.people)
  check "merge: one person, by key" (merged.people.size == 1)
  check "merge: the local name stays" (merged.people[0]!.name == "Current local name")
  check "merge: the newer counter stays" (merged.people[0]!.nextPaymentIndex == 24)
  check "merge: the sender label moves to the local id" ((merged.senderByTxid.map (·.2)) == #[mine.people[0]!.id])

def wrongNetworkOrMalformedLabelsAreRejectedBeforeStoreChanges : TM Unit := do
  let f ← fixture
  let json ← match Lean.Json.parse (String.fromUTF8! f.state.encoded) with | .ok j => pure j | .error e => throw e
  let signet := json.setObjVal! "network" "signet"
  check "context: another network is refused" (← refusedR (CloudAppState.decode (some (bytesOfJson signet)) f.bundle))
  let badLabels := (signet.setObjVal! "network" "mainnet").setObjVal! "receiveLabels" (Lean.Json.mkObj [("not a script", "Private note")])
  check "context: a malformed note is refused" (← refusedR (CloudAppState.decode (some (bytesOfJson badLabels)) f.bundle))
  let vault := StoreKeyVault.inMemory (← IO.mkRef {})
  let (store, _) ← PeopleStore.configure vault (some (f.dir / "people.json")) .mainnet
  let store ← rm "restore" (store.restore vault writeAtomically f.state.people)
  let invalid := { f.state.people with
    senderByTxid := f.state.people.senderByTxid.push (String.join (List.replicate 32 "02"), "unknown person") }
  check "context: a dangling sender name fails validation" (← refusedR (store.planRestore invalid))
  check "context: the store is unchanged" ((← rm "backup" store.backup) == f.state.people)

/-! ## Swift's own output (`Vectors/cloud-backup.json`) -/

def swiftVectors (writeDir : Option String) : TM Unit := do
  let text ← IO.FS.readFile "../Lean/Vectors/cloud-backup.json"
  let j ← match Lean.Json.parse text with | .ok j => pure j | .error e => throw e
  let str (k : String) : TM String := match j.getObjValAs? String k with | .ok s => pure s | .error e => throw e
  let bundle ← match ImportBundle.decode (← str "bundle") with | .ok b => pure b | .error e => throw e.name
  let key := ofHex! (← str "key")
  let appState := ofHex! (← str "appState")
  let v2 ← wm "swift v2" (CloudWalletBackup.decode (← str "v2").toUTF8)
  check "swift v2: restores the bundle" ((← wm "restore" (v2.restoredBundle key)) == bundle)
  check "swift v2: restores the app data" ((← wm "app state" (v2.restoredAppState key)) == some appState)
  check "swift v2: savedAt and the id read back" (v2.savedAt == 783_000_000.123456 && (UUIDText.canonical? v2.id) == some v2.id)
  let plain ← wm "swift v2 plain" (CloudWalletBackup.decode (← str "v2NoAppState").toUTF8)
  check "swift v2 without app data" ((← wm "restore" (plain.restoredBundle key)) == bundle &&
    (← wm "app state" (plain.restoredAppState key)).isNone)
  let v1 ← wm "swift v1" (CloudWalletBackup.decode (← str "v1").toUTF8)
  check "swift v1: restores" (v1.version == 1 && (← wm "restore" (v1.restoredBundle key)) == bundle &&
    (← wm "app state" (v1.restoredAppState key)).isNone)
  let dates ← match j.getObjValAs? (Array Float) "referenceDates" with | .ok d => pure d | .error e => throw e
  let purposes ← match j.getObjValAs? (Array String) "walletPurposes" with | .ok d => pure d | .error e => throw e
  for (d, p) in dates.zip purposes do
    check s!"swift purpose for {d}: {p}" (CloudWalletBackup.walletPurpose d == p) (CloudWalletBackup.walletPurpose d)
  let plainContents : CloudBackupContents := { bundle }
  let withApp : CloudBackupContents := { bundle, appState := some appState }
  check "swift digest without app data" (hex plainContents.digest == (← str "digestWithoutAppState"))
  check "swift digest with app data" (hex withApp.digest == (← str "digestWithAppState"))
  check "swift canonical contents JSON, byte for byte"
    (SwiftJSON.write ({ withApp with bundle := { bundle with mnemonic := none } }).toJV == (← str "contentsJSON"))
  -- A Lean-made backup of the same bundle for Swift to open.
  if let some dir := writeDir then
    let mine ← wm "create" (CloudWalletBackup.create bundle key (appState := some appState))
    IO.FS.writeBinFile (System.FilePath.mk dir / "lean-backup.json") (← wm "encode" mine.encoded)
    IO.FS.writeFile (System.FilePath.mk dir / "lean-backup.key") (hex key)
    IO.println s!"  wrote {dir}/lean-backup.json"

def main (args : List String) : IO UInt32 := do
  let writeDir := match args with | "--write" :: d :: _ => some d | _ => none
  runTest "roundTripRestoresSigningAndAddressCounters" roundTripRestoresSigningAndAddressCounters
  runTest "automaticUpdateKeepsTheSealedKeyAndNewHistoryFrontier" automaticUpdateKeepsTheSealedKeyAndNewHistoryFrontier
  runTest "wrongKeyAndModifiedMetadataAreRejected" wrongKeyAndModifiedMetadataAreRejected
  runTest "appContextIsEncryptedAndUpdatesWithoutReadingThePhrase" appContextIsEncryptedAndUpdatesWithoutReadingThePhrase
  runTest "legacyBackupRestoresAndUpgradesWithoutLosingItsKey" legacyBackupRestoresAndUpgradesWithoutLosingItsKey
  runTest "mismatchedWalletAndMissingPhraseAreRefused" mismatchedWalletAndMissingPhraseAreRefused
  runTest "cloudBackupRestores" cloudBackupRestores
  runTest "cloudContextRoundTrips" cloudContextRoundTrips
  runTest "existingContactsAndNewerPaymentCounterSurviveRestore" existingContactsAndNewerPaymentCounterSurviveRestore
  runTest "wrongNetworkOrMalformedLabelsAreRejectedBeforeStoreChanges" wrongNetworkOrMalformedLabelsAreRejectedBeforeStoreChanges
  runTest "swiftVectors" (swiftVectors writeDir)
  let f ← failures.get
  IO.println s!"cloud-backup-test: {← passed.get} passed, {f.size} failed"
  return if f.isEmpty then 0 else 1
