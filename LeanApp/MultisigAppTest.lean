import WinnowApp.Real

/-! `multisig-app-test`: upstream 1cf93fb's app-side multisig tests, ported.

* `AppTests/MultisigStoreTests.swift` (all 10 tests): sealed persistence, backups, and the coin bookkeeping
  the combined filter scan drives (payments, spends, conflicts, reorgs), against `MultisigStore`;
* `AppTests/MultisigAccountFlowTests.swift` without the Ledger: the builder (with another Winnow's key and a
  recovery path), a co-signer's spend signed on two phones with BIP326 sequences, the recovery path's age
  check and the Advanced-mode gate, through `Backend.real` (`Real/Multisig.lean`) on wallets opened from
  disk with no network.

Fixtures as `Tests/Support/TestKeys.swift` (masters from BIP39 over 16 repeated bytes: 0xA1, 0xB2, 0xC3;
0xD4 a recovery key; keys at m/86'/1'/0'). Exits 1 on any failure. -/

open Winnow WinnowApp WinnowApp.RecordsReal
open Tx (BitcoinNetwork)

initialize passed : IO.Ref Nat ← IO.mkRef 0
initialize failures : IO.Ref (Array String) ← IO.mkRef #[]

def check (name : String) (ok : Bool) (detail : String := "") : IO Unit := do
  if ok then passed.modify (· + 1)
  else
    failures.modify (·.push name)
    IO.println s!"FAIL {name}{if detail.isEmpty then "" else ": " ++ detail}"

def need {α} (name : String) (x : RM α) : IO α := do
  match ← x.run with
  | .ok a => return a
  | .error e => throw (IO.userError s!"{name}: {e.name}: {e.description}")

def needM {α} (name : String) (r : MAM α) : IO α := do
  match r with
  | .ok a => return a
  | .error e => throw (IO.userError s!"{name}: {e.name}")

def needE {ε α} (name : String) (r : Except ε α) : IO α := do
  match r with
  | .ok a => return a
  | .error _ => throw (IO.userError s!"{name} failed")

/-- Expects the failure `kind` (any kind when empty). -/
def refused {α} (name : String) (x : RM α) (kind : String := "") : IO Unit := do
  match ← x.run with
  | .ok _ => check name false "accepted"
  | .error e => check name (kind.isEmpty || e.name == kind) s!"got {e.name}: {e.description}"

def runTest (name : String) (t : IO Unit) : IO Unit := do
  let start ← IO.monoMsNow
  try t catch e =>
    failures.modify (·.push name)
    IO.println s!"FAIL {name} (aborted): {e}"
  IO.println s!"  {name}: {(← IO.monoMsNow) - start} ms"
  (← IO.getStdout).flush

/-! ## Fixtures -/

initialize masterCache : IO.Ref (Array (UInt8 × Keys.HDKey)) ← IO.mkRef #[]

def master (entropyByte : UInt8) : IO Keys.HDKey := do
  if let some (_, m) := (← masterCache.get).find? (·.1 == entropyByte) then return m
  let words ← needE "mnemonic" (Keys.BIP39.mnemonic (ByteArray.mk (Array.replicate 16 entropyByte)))
  let m ← needE "master" (Keys.HDKey.ofSeed (Keys.BIP39.seed words))
  masterCache.modify (·.push (entropyByte, m))
  return m

def masters : IO (Array Keys.HDKey) := #[0xA1, 0xB2, 0xC3].mapM master

def keyExpression (m : Keys.HDKey) : IO String := do
  let account ← needE "account key" (m.derived "m/86'/1'/0'")
  return s!"[{Descriptor.hex8 m.fingerprint}/86'/1'/0']{account.neutered.serialized .testnet}/<0;1>/*"

def signet : BitcoinNetwork := .signet

def twoOfTwo : IO MultisigAccount := do
  let keys ← ((← masters).extract 0 2).mapM keyExpression
  let d ← needM "descriptor" (MultisigAccount.makeDescriptor 2 keys none signet)
  needM "account" (MultisigAccount.make d signet)

def spk (a : MultisigAccount) (index : UInt32) (choice : Nat := 0) : IO ByteArray :=
  needM "scriptPubKey" (a.scriptPubKey index choice)

def zeros (n : Nat) (b : UInt8 := 0) : ByteArray := ByteArray.mk (Array.replicate n b)

def coinbaseInput : Transaction.Input :=
  { previousOutput := ⟨zeros 32, 0xFFFF_FFFF⟩, scriptSig := ByteArray.mk #[0x01], sequence := 0xFFFF_FFFF }

def fakeMatch (height : UInt32) (txs : Array Transaction) : Net.BlockMatch :=
  let header : Net.BlockHeader := {
    version := 2, previousHash := zeros 32, merkleRoot := zeros 32 0xAA, time := 1_700_000_000 + height,
    bits := 0x207F_FFFF, nonce := 0, hash := .empty }
  { height, blockHash := .empty, block := { header := header, transactions := txs } }

/-- A block whose first transaction is a coinbase paying no one we watch. -/
def block (height : UInt32) (txs : Array Transaction) : Net.BlockMatch :=
  let coinbase : Transaction := {
    version := 1, inputs := #[coinbaseInput],
    outputs := #[{ value := 50, scriptPubKey := ByteArray.mk #[0x51] }], locktime := height }
  fakeMatch height (#[coinbase] ++ txs)

def spend (outpoints : Array Transaction.Outpoint) (outputs : Array Transaction.Output) : Transaction :=
  { version := 2, inputs := outpoints.map fun o => { previousOutput := o, scriptSig := .empty, sequence := 0xFFFF_FFFD },
    outputs, locktime := 0 }

def payment (script : ByteArray) (amount : Int64) (from_ : Transaction.Outpoint) (change : Option Transaction.Output := none) :
    Transaction :=
  spend #[from_] (#[{ value := amount, scriptPubKey := script }] ++ change.toArray)

/-- An outpoint of a transaction this store never saw. -/
def foreign (b : UInt8) : Transaction.Outpoint := ⟨zeros 32 b, 0⟩

def elsewhere : ByteArray := ByteArray.mk (#[0x51, 0x20] ++ Array.replicate 32 0x77)

def coin (a : MultisigAccount) (amount : Int64) (height : UInt32 := 100) : IO WalletUTXO := do
  return { txid := zeros 32 0x5A, vout := 0, amount, scriptPubKey := ← spk a 0, chain := .receive, index := 0, height }

def recordOf (a : MultisigAccount) (coins : Array WalletUTXO) : MultisigAccountRecord :=
  { id := a.id, name := "Phone and desktop", descriptor := a.descriptor.serialized, createdAtHeight := 0,
    nextReceiveIndex := 1, allUtxos := coins }

def memoryKeys : IO StoreKeyVault := do return StoreKeyVault.inMemory (← IO.mkRef {})

initialize tempRoot : IO.Ref System.FilePath ← IO.mkRef (System.FilePath.mk ".")
initialize tempCount : IO.Ref Nat ← IO.mkRef 0

def tempFile (name : String) : IO System.FilePath := do
  let k ← tempCount.modifyGet fun n => (n, n + 1)
  let dir := (← tempRoot.get) / s!"t{k}"
  IO.FS.createDirAll dir
  return dir / name

/-- A store under test: the value, its keys, and the actor-like calls. -/
structure S where
  keys : StoreKeyVault
  ref : IO.Ref MultisigStore

def S.open (keys : StoreKeyVault) (path : Option System.FilePath) (network : BitcoinNetwork := signet) : IO (S × OpenResult) := do
  let (store, r) ← MultisigStore.configure keys path network
  return ({ keys, ref := ← IO.mkRef store }, r)

def S.step {α} (s : S) (f : MultisigStore → RM (MultisigStore × α)) : RM α := do
  let (next, a) ← f (← RM.io s.ref.get)
  RM.io (s.ref.set next)
  return a

def S.stepU (s : S) (f : MultisigStore → RM MultisigStore) : RM Unit := s.step fun st => do return (← f st, ())

def S.all (s : S) : IO (Array MultisigAccountRecord) := return (← s.ref.get).records
def S.fetch (s : S) (id : String) : IO MultisigAccountRecord := do
  let some r := (← s.ref.get).record? id | throw (IO.userError s!"no record {id}")
  return r
def S.add (s : S) (name : String) (a : MultisigAccount) (h : UInt32) : RM MultisigAccountRecord :=
  s.step fun st => st.add s.keys writeAtomically name a h
def S.restore (s : S) (rs : Array MultisigAccountRecord) : RM Unit := s.stepU fun st => st.restore s.keys writeAtomically rs
def S.apply (s : S) (m : Net.BlockMatch) (network : BitcoinNetwork := signet) : RM (Array ByteArray) :=
  s.step fun st => st.apply s.keys writeAtomically m network
def S.recordSpend (s : S) (id : String) (tx : Transaction) (ci : Option UInt32) : RM Bool :=
  s.step fun st => st.recordSpend s.keys writeAtomically id tx ci
def S.rollBack (s : S) (fork : UInt32) : RM Unit := s.stepU fun st => st.rollBack s.keys writeAtomically fork
def S.backup (s : S) : RM (Array MultisigAccountRecord) := do (← RM.io s.ref.get).backupRecords
def S.watch (s : S) (network : BitcoinNetwork := signet) : RM (Array ByteArray) := s.step fun st => do
  let (scripts, next) ← st.watchScripts network
  return (next, scripts)

def unsealedPayload (path : System.FilePath) : IO ByteArray := do
  let data ← IO.FS.readBinFile path
  if !SealedStoreFile.isSealed data then return data
  let some nl := SealedStoreFile.firstNewline data | return data
  return data.extract (nl + 1) data.size

def spentOf (r : MultisigAccountRecord) (o : Transaction.Outpoint) : Option SpentMarker :=
  (r.allUtxos.find? (·.outpoint == o)).bind (·.spent)

def marker (by_ : ByteArray) (h : Option UInt32) : Option SpentMarker := some { spentBy := by_, height := h }

/-! ## MultisigStoreTests -/

def testBackupPreservesAccountsAndRejectsChangedOwnership : IO Unit := do
  let keys ← memoryKeys
  let url ← tempFile "multisig.json"
  let a ← twoOfTwo
  let record := recordOf a #[← coin a 80_000]
  let (store, _) ← S.open keys (some url)
  need "restore" (store.restore #[record])
  let backup : ImportBundle := { network := "signet", lastKnownHeight := 100, vaults := some (← need "backup" store.backup) }
  let decoded ← needE "decode" (ImportBundle.decode backup.serialized)
  check "backup: the bundle carries the record" (decoded.vaults == some #[record])
  let (restarted, opened) ← S.open keys (some url)
  check "backup: the store reopens loaded" (opened == .loaded)
  check "backup: the same records" ((← restarted.all) == #[record])
  let changed := { record with allUtxos := record.allUtxos.modify 0 fun u => { u with scriptPubKey := ByteArray.mk #[0x51] } }
  refused "backup: a foreign coin is refused" (restarted.restore #[changed])
  check "backup: the refused restore changed nothing" ((← restarted.all) == #[record])
  let payload ← unsealedPayload url
  let onDisk := (String.fromUTF8? payload).bind fun t =>
    (SwiftJSON.decodeText t (SwiftJSON.asArray MultisigAccountRecord.ofJV)).toOption
  check "backup: the file holds exactly the record" (onDisk == some #[record])

def testBackupWaitsForPendingAccountPayments : IO Unit := do
  let a ← twoOfTwo
  let (store, _) ← S.open (← memoryKeys) none
  need "restore" (store.restore #[recordOf a #[← coin a 80_000 0]])
  refused "an unconfirmed account snapshot is not exported" store.backup "invalidBundle"

def testPaymentsSpendsAndRollbacks : IO Unit := do
  let keys ← memoryKeys
  let url ← tempFile "multisig.json"
  let a ← twoOfTwo
  let (store, _) ← S.open keys (some url)
  let added ← need "add" (store.add "Shared" a 100)
  let initial ← need "watch" store.watch
  check "receive and change up to the gap limit" (initial.size == 2 * Wallet.gapLimit.toNat)
  let funding := payment (← spk a 0) 60_000 ⟨zeros 32 0x11, 0⟩
  discard <| need "apply 101" (store.apply (block 101 #[funding]))
  let later := payment (← spk a 2) 7_000 ⟨zeros 32 0x12, 0⟩
  discard <| need "apply 102" (store.apply (block 102 #[later]))
  let mut current ← store.fetch added.id
  check "payments: balance" (current.balance == 67_000) s!"{current.balance}"
  check "a payment at index 2 moves the frontier past it" (current.nextReceiveIndex == 3)
  check "no coinbase coin" (!current.utxos.any (·.isCoinbase))
  -- Our own spend, recorded at broadcast: the input is reserved and the change waits at height 0.
  let changeScript ← spk a 0 1
  let sp := payment elsewhere 40_000 ⟨funding.txid, 0⟩ (some { value := 19_000, scriptPubKey := changeScript })
  check "recordSpend touches the coin" (← need "recordSpend" (store.recordSpend added.id sp (some 0)))
  check "a repeated relay changes nothing" (!(← need "recordSpend again" (store.recordSpend added.id sp (some 0))))
  current ← store.fetch added.id
  check "spend recorded: balance" (current.balance == 26_000) s!"{current.balance}"
  check "spend recorded: change frontier" (current.nextChangeIndex == 1)
  check "no backup while a spend is pending" ((← store.backup.run) matches .error _)
  -- A reorg below the later payment drops it, and keeps the in-flight spend's input reserved.
  need "rollBack 101" (store.rollBack 101)
  current ← store.fetch added.id
  check "rollback: balance" (current.balance == 19_000) s!"{current.balance}"
  check "a reorg never costs an address gap" (current.nextReceiveIndex == 3)
  -- The spend confirms; a reorg below it puts it back in flight.
  discard <| need "apply 103" (store.apply (block 103 #[sp]))
  current ← store.fetch added.id
  check "the spend's tombstone is heighted" ((spentOf current ⟨funding.txid, 0⟩).bind (·.height) == some 103)
  check "the change is confirmed" ((current.utxos.find? (·.txid == sp.txid)).map (·.height) == some 103)
  check "a confirmed spend can be backed up" ((← store.backup.run) matches .ok _)
  need "rollBack 102" (store.rollBack 102)
  current ← store.fetch added.id
  check "the fallen spend is in flight again" (spentOf current ⟨funding.txid, 0⟩ == marker sp.txid none)
  check "and its change left" (current.balance == 0) s!"{current.balance}"
  let (restarted, _) ← S.open keys (some url)
  check "reopened from disk: the same records" ((← restarted.all) == #[current])

def testARollbackKeepsTheInputsOfAFallenSpendReserved : IO Unit := do
  let a ← twoOfTwo
  let (store, _) ← S.open (← memoryKeys) (some (← tempFile "multisig.json"))
  let added ← need "add" (store.add "Shared" a 100)
  let funding := payment (← spk a 0) 60_000 (foreign 0x51)
  let other := payment (← spk a 1) 5_000 (foreign 0x52)
  discard <| need "apply 101" (store.apply (block 101 #[funding, other]))
  let fundingCoin : Transaction.Outpoint := ⟨funding.txid, 0⟩
  let sp := payment elsewhere 40_000 fundingCoin (some { value := 19_000, scriptPubKey := ← spk a 0 1 })
  discard <| need "recordSpend" (store.recordSpend added.id sp (some 0))
  discard <| need "apply 103" (store.apply (block 103 #[sp]))
  let mut current ← store.fetch added.id
  check "fallen spend: balance before" (current.balance == 24_000)
  need "rollBack" (store.rollBack 102)
  current ← store.fetch added.id
  check "fallen spend: in flight again" (spentOf current fundingCoin == marker sp.txid none)
  check "only the coin no spend holds can go into a new one" (current.utxos.map (·.outpoint) == #[⟨other.txid, 0⟩])
  check "the change left with its block" (current.balance == 5_000)
  check "no backup while in flight" ((← store.backup.run) matches .error _)
  need "rollBack again" (store.rollBack 102)
  check "a rollback redone after a crash changes nothing" ((← store.fetch added.id) == current)
  let discarded ← need "apply 104" (store.apply (block 104 #[sp]))
  check "nothing discarded" discarded.isEmpty
  current ← store.fetch added.id
  check "the reservation takes its height" (spentOf current fundingCoin == marker sp.txid (some 104))
  check "and the change is back" (current.balance == 24_000)

def testARollbackKeepsAReservedCoinFromAFallenBlock : IO Unit := do
  let a ← twoOfTwo
  let (store, _) ← S.open (← memoryKeys) (some (← tempFile "multisig.json"))
  let added ← need "add" (store.add "Shared" a 100)
  let funding := payment (← spk a 0) 60_000 (foreign 0x61)
  discard <| need "apply 101" (store.apply (block 101 #[funding]))
  let first := payment elsewhere 40_000 ⟨funding.txid, 0⟩ (some { value := 19_000, scriptPubKey := ← spk a 0 1 })
  let changeCoin : Transaction.Outpoint := ⟨first.txid, 1⟩
  let second := payment elsewhere 18_000 changeCoin
  discard <| need "apply 103" (store.apply (block 103 #[first]))
  discard <| need "apply 104" (store.apply (block 104 #[second]))
  need "rollBack" (store.rollBack 102)
  let mut current ← store.fetch added.id
  match current.allUtxos.find? (·.outpoint == changeCoin) with
  | some kept =>
    check "the reserved row stays, not in a block yet" (kept.height == 0)
    check "reserved for the second spend" (kept.spent == marker second.txid none)
  | none => check "the reserved row stays" false
  check "reserved coin: balance 0" (current.balance == 0)
  discard <| need "apply 103 again" (store.apply (block 103 #[first]))
  current ← store.fetch added.id
  check "the change is re-heighted, not admitted twice"
    ((current.allUtxos.filter (·.outpoint == changeCoin)).map (·.height) == #[103])
  check "the change is still the second spend's" (current.balance == 0)
  discard <| need "apply 104 again" (store.apply (block 104 #[second]))
  current ← store.fetch added.id
  check "the second spend confirms" (spentOf current changeCoin == marker second.txid (some 104))
  check "nothing pending" (!current.allUtxos.any fun u => u.height == 0 || MultisigStore.isPending u)

def testZeroValueOutputIsIgnoredAndTheScanMovesOn : IO Unit := do
  let a ← twoOfTwo
  let (store, _) ← S.open (← memoryKeys) (some (← tempFile "multisig.json"))
  let added ← need "add" (store.add "Shared" a 100)
  let dust := spend #[foreign 0x21] #[{ value := 0, scriptPubKey := ← spk a 1 }, { value := 5_000, scriptPubKey := ← spk a 0 }]
  discard <| need "apply 101" (store.apply (block 101 #[dust]))
  let mut current ← store.fetch added.id
  check "the zero-value output is not a coin" (current.allUtxos.map (·.amount) == #[5_000])
  check "and does not use up its address" (current.nextReceiveIndex == 1)
  let later := payment (← spk a 1) 7_000 (foreign 0x22)
  discard <| need "apply 102" (store.apply (block 102 #[later]))
  current ← store.fetch added.id
  check "the scan moves on" (current.balance == 12_000 && current.nextReceiveIndex == 2)

def testALosingInFlightSpendReleasesItsCoinsAndDropsItsChange : IO Unit := do
  let a ← twoOfTwo
  let (store, _) ← S.open (← memoryKeys) (some (← tempFile "multisig.json"))
  let added ← need "add" (store.add "Shared" a 100)
  let first := payment (← spk a 0) 60_000 (foreign 0x31)
  let second := payment (← spk a 1) 30_000 (foreign 0x32)
  discard <| need "apply 101" (store.apply (block 101 #[first, second]))
  let firstCoin : Transaction.Outpoint := ⟨first.txid, 0⟩
  let secondCoin : Transaction.Outpoint := ⟨second.txid, 0⟩
  let ours := spend #[firstCoin, secondCoin] #[{ value := 70_000, scriptPubKey := elsewhere }, { value := 19_000, scriptPubKey := ← spk a 0 1 }]
  discard <| need "recordSpend ours" (store.recordSpend added.id ours (some 0))
  let chained := payment elsewhere 10_000 ⟨ours.txid, 1⟩ (some { value := 8_000, scriptPubKey := ← spk a 1 1 })
  discard <| need "recordSpend chained" (store.recordSpend added.id chained (some 1))
  let mut current ← store.fetch added.id
  check "losing spend: balance before" (current.balance == 8_000) s!"{current.balance}"
  let theirs := payment elsewhere 45_000 firstCoin (some { value := 14_000, scriptPubKey := ← spk a 0 1 })
  let discarded ← need "apply theirs" (store.apply (block 102 #[theirs]))
  check "the broadcaster stops relaying both" (discarded == #[ours.txid, chained.txid])
  current ← store.fetch added.id
  check "the winner holds the coin" (spentOf current firstCoin == marker theirs.txid (some 102))
  let live := current.utxos.map (·.outpoint)
  check "the coins left" (live.size == 2 && live.contains secondCoin && live.contains ⟨theirs.txid, 1⟩)
  check "losing spend: balance after" (current.balance == 44_000) s!"{current.balance}"
  check "the losing spends' outputs never existed" (!current.allUtxos.any fun u => u.txid == ours.txid || u.txid == chained.txid)
  check "nothing stays reserved" (!current.allUtxos.any MultisigStore.isPending)
  check "nothing is left in flight: backup" ((← store.backup.run) matches .ok _)
  need "rollBack 101" (store.rollBack 101)
  current ← store.fetch added.id
  check "the winner is back in flight" (spentOf current firstCoin == marker theirs.txid none)
  check "its change left with the block" (current.balance == 30_000) s!"{current.balance}"
  let beaten ← need "apply ours" (store.apply (block 102 #[ours]))
  check "ours beats it on the new branch" (beaten == #[theirs.txid])
  current ← store.fetch added.id
  check "ours confirmed: the change" (current.utxos.map (·.outpoint) == #[⟨ours.txid, 1⟩] && current.balance == 19_000)

def testLookaheadFindsPaymentsUpToTheGapLimitAhead : IO Unit := do
  let a ← twoOfTwo
  let (store, _) ← S.open (← memoryKeys) none
  let added ← need "add" (store.add "Shared" a 100)
  let last := Wallet.gapLimit - 1
  let watched ← need "watch" store.watch
  check "watches the last receive index" (watched.contains (← spk a last))
  check "watches the last change index" (watched.contains (← spk a last 1))
  check "not past the gap limit" (!watched.contains (← spk a Wallet.gapLimit))
  discard <| need "apply 101" (store.apply (block 101 #[payment (← spk a last) 9_000 (foreign 0x41)]))
  let mut current ← store.fetch added.id
  check "lookahead: the far payment" (current.balance == 9_000 && current.nextReceiveIndex == Wallet.gapLimit)
  let furthest := 2 * Wallet.gapLimit - 1
  let receive := payment (← spk a furthest) 3_000 (foreign 0x42)
  let toChange := payment (← spk a furthest 1) 2_000 (foreign 0x43)
  discard <| need "apply 102" (store.apply (block 102 #[receive, toChange]))
  current ← store.fetch added.id
  check "the window moved with the frontier" (current.balance == 14_000 &&
    current.nextReceiveIndex == 2 * Wallet.gapLimit && current.nextChangeIndex == 2 * Wallet.gapLimit)

def testTamperedUnsealedAndOversizedFilesAreRefusedAndKept : IO Unit := do
  let keys ← memoryKeys
  let url ← tempFile "multisig.json"
  let a ← twoOfTwo
  let (store, _) ← S.open keys (some url)
  discard <| need "add" (store.add "Shared" a 100)
  check "the file is sealed" (SealedStoreFile.isSealed (← IO.FS.readBinFile url))
  check "the key is established" (((← (keys.key "multisig.signet").run).toOption.join).isSome)
  -- One payload byte changed: the seal refuses it, and nothing is written.
  let bytes ← IO.FS.readBinFile url
  let some i := (List.range bytes.size).reverse.find? (bytes[·]! == 'S'.toNat.toUInt8) | throw (IO.userError "no S")
  let tamperedBytes := bytes.set! i 'T'.toNat.toUInt8
  IO.FS.writeBinFile url tamperedBytes
  let (tampered, r) ← S.open keys (some url)
  check "a tampered account file is not read" (r == .damaged MultisigStore.unverifiedStorageMessage)
  refused "a damaged store accepts no change" (tampered.add "Other" a 1) "damaged"
  check "the damaged file is left as it was" ((← IO.FS.readBinFile url) == tamperedBytes)
  -- A well-formed but unsealed file, on a phone that never sealed one.
  let planted ← tempFile "multisig.json"
  IO.FS.writeBinFile planted (MultisigStore.encode #[recordOf a #[]])
  let (_, r2) ← S.open (← memoryKeys) (some planted)
  check "an unsealed account file is not adopted" (r2 == .damaged MultisigStore.unverifiedStorageMessage)
  let oversized ← tempFile "multisig.json"
  let h ← IO.FS.Handle.mk oversized .write
  h.truncate
  h.write (zeros (MultisigStore.maximumFileBytes + 1))
  h.flush
  let (_, r3) ← S.open keys (some oversized)
  check "an oversized account file is not read" (r3 == .damaged MultisigStore.damagedStorageMessage)

def testDuplicateWrongNetworkAndBadNamesAreRefused : IO Unit := do
  let a ← twoOfTwo
  let (store, _) ← S.open (← memoryKeys) (some (← tempFile "multisig.json"))
  discard <| need "add" (store.add "Shared" a 1)
  refused "the same account twice" (store.add "Again" a 1) "duplicate"
  let regtest ← needM "regtest account" (MultisigAccount.make a.descriptor .regtest)
  refused "another network's account" (store.add "Regtest" regtest 1) "invalidState"
  for name in ["", "two\nlines", String.ofList (List.replicate (DisplayName.maximumLength + 1) 'x')] do
    let (fresh, _) ← S.open (← memoryKeys) none
    refused s!"an unusable name ({name.length} characters)" (fresh.add name a 1) "invalidState"
  check "one account" ((← store.all).size == 1)


/-! ## MultisigAccountFlowTests (no Ledger) -/

/-- A ready phone (`readyMultisigModel`): a signet wallet created from one repeated entropy byte in its own
directory, opened by `Backend.real` with no network. -/
structure Phone where
  backend : Backend
  env : Real.Env
  multisig : Real.MultisigApp

def phoneWith (entropyByte : UInt8) : IO Phone := do
  let dir := (← tempFile "wallet.json").parent.get!
  let secrets ← IO.mkRef ({} : Keys.InMemorySecrets)
  let ks := Winnow.inMemoryKeyStore secrets
  match ← (Wallet.create .signet ks (some (dir / "wallet.json")) (entropy := some (zeros 16 entropyByte))).run with
  | .ok _ => pure ()
  | .error e => throw (IO.userError s!"Wallet.create: {e.name}")
  let (backend, env, multisig) ← Backend.realWithMultisig { keyStore := ks, fetch := fun _ => throw (.other "offline") }
  let r ← backend.openWallet .signet dir.toString
  check "the phone boots ready" (r matches .opened _)
  return { backend, env, multisig }

def failsWith {α} (name : String) (x : IO α) (text : String) : IO Unit := do
  match ← (x.toBaseIO) with
  | .ok _ => check name false "accepted"
  | .error e => check name (toString e == text) s!"got {e}"

def Phone.keyExpression (p : Phone) : IO String := Real.multisigKeyExpression p.env
def Phone.record (p : Phone) (id : String) : IO MultisigAccountRecord := Real.record p.multisig id
def Phone.accounts (p : Phone) : IO (List MultisigInfo) := do return (← p.backend.multisigOverview).accounts

def testBuilderMakesAccountWithAnotherWinnowAndRecovery : IO Unit := do
  let phone ← phoneWith 0xA1
  let ms ← masters
  let otherWinnow ← keyExpression ms[2]!
  let (id, descriptor) ← phone.backend.createMultisigAccount true "Family 2-of-2" 2 [s!" {otherWinnow} "] false (some (.fewerSigners 1 4320))
  let account ← needM "account" (MultisigAccount.parse descriptor signet)
  check "builder: 2 of 2 with a recovery path of 1 after 4320 blocks" (account.threshold == 2 && account.signers.size == 2 &&
    (account.recovery.map (·.blocks)) == some 4320 && (account.recovery.map (·.threshold)) == some 1)
  check "builder: the record is the account" (id == account.id)
  let otherKey ← needE "other account key" (ms[2]!.derived "m/86'/1'/0'")
  check "the other Winnow's key is a signer" (account.includes otherKey.neutered)
  -- The same account with this phone's recovery copy under another fingerprint (SEC-037).
  let phoneKey ← phone.keyExpression
  let bare := (phoneKey.dropEnd "/<0;1>/*".length).copy
  let body := (descriptor.splitOn "#")[0]!
  let relabelled := body.replace (bare ++ "/<2;3>/*") ("[deadbeef" ++ (bare.drop 9).copy ++ "/<2;3>/*")
  check "the relabelled descriptor differs" (relabelled != body)
  failsWith "joining refuses a recovery leaf that relabels a signer" (phone.backend.addMultisigAccount "Relabelled" relabelled)
    (MultisigAccountError.invalidDescriptor "a signer reused for recovery must keep its own fingerprint and path there").description
  check "one account" ((← phone.accounts).length == 1)
  -- Phone and another Winnow with a separate recovery key.
  let recoveryKey ← keyExpression (← master 0xD4)
  let (_, pair) ← phone.backend.createMultisigAccount true "Two phones" 2 [otherWinnow] false (some (.separateKey recoveryKey 144))
  let pairAccount ← needM "pair" (MultisigAccount.parse pair signet)
  check "a separate recovery key" ((pairAccount.recovery.map (·.keys.size)) == some 1)
  check "two accounts" ((← phone.accounts).length == 2)
  let info := (← phone.accounts).find? (·.id == id)
  check "the overview: policy and recovery text" ((info.bind (·.policy)) == some "2 of 2" &&
    (info.bind (·.recovery)) == some "after 4320 blocks: any 1 of the signers")
  let pairInfo := (← phone.accounts).find? (·.name == "Two phones")
  check "the overview: a separate recovery key" ((pairInfo.bind (·.recovery)) == some "after 144 blocks: the recovery key")

def fundingTx (seed : UInt8) (script : ByteArray) : Transaction :=
  spend #[⟨zeros 32 seed, 0⟩] #[{ value := 60_000, scriptPubKey := script }]

def coinbaseAt (height : UInt32) : Transaction := {
  version := 1, inputs := #[coinbaseInput],
  outputs := #[{ value := 50, scriptPubKey := ByteArray.mk #[0x51] }], locktime := height }

def testTwoPhonesSignACoSignersSpendWithBIP326Sequences : IO Unit := do
  let phone ← phoneWith 0xA1
  let otherPhone ← phoneWith 0xC3
  let recoveryKey ← keyExpression (← master 0xD4)
  let (id, descriptor) ← phone.backend.createMultisigAccount true "Two phones" 2 [← otherPhone.keyExpression] false
    (some (.separateKey recoveryKey 144))
  let otherID ← otherPhone.backend.addMultisigAccount "Two phones" descriptor
  check "the other phone joins the same account" (otherID == id)
  let account ← needM "account" (MultisigAccount.parse descriptor signet)
  let created ← phone.record id
  -- Two coins 300 blocks apart reach both phones.
  let height := created.createdAtHeight + 1
  let mut coins : Array Transaction := #[]
  for (offset, index) in [((0 : UInt32), (0 : UInt32)), (300, 1)] do
    let funding := fundingTx (0x35 + index.toUInt8) (← spk account index)
    coins := coins.push funding
    for p in [phone, otherPhone] do
      discard <| p.multisig.applyMatch (fakeMatch (height + offset) #[coinbaseAt (height + offset), funding]) signet
  let record ← phone.record id
  check "both coins credited" (record.balance == 120_000) s!"{record.balance}"
  check "the overview shows the balance" (((← phone.accounts).find? (·.id == id)).map (·.balance) == some 120_000)
  -- A co-signer's wallet sets each input's sequence to its coin's confirmations (BIP326): one meets the
  -- 144-block recovery lock, one does not. Both phones take it as the signers' path.
  let destination ← do
    let d ← needE "destination descriptor" (Descriptor.parse s!"tr({← keyExpression (← masters)[1]!})")
    pure ((← needE "derived" (d.derived 0 signet))[0]!.address)
  let created ← phone.backend.createMultisigSpend id destination 100_000 2.0 false
  let proposal ← needE "proposal" (PSBT.ofBase64 created.psbt)
  let tx ← needE "unsigned" proposal.unsignedTransaction
  let mut edited := proposal
  for h : k in [0:tx.inputs.size] do
    let seq : UInt32 := if tx.inputs[k].previousOutput.txid == coins[0]!.txid then 305 else 5
    edited := { edited with inputs := edited.inputs.modify k (·.setSequence (some seq)) }
  let proposalText := edited.base64
  for p in [phone, otherPhone] do
    let shown ← p.backend.reviewMultisigPSBT id proposalText
    check "the signers' path only" ((shown.screen.map (·.signatures.map (·.1))) == some [false]) s!"{shown.reviewError}"
    check "this phone has not signed" ((shown.screen.map (·.progress.phoneUnsigned)) == some true)
  let mine ← phone.backend.signMultisigSpend id proposalText
  let theirs ← otherPhone.backend.signMultisigSpend id proposalText
  check "one signature after signing here" ((mine.screen.map (·.signatures)) == some [(false, 1, 2)])
  check "signed here: share it" ((mine.screen.map (·.progress.nextStep)) ==
    some "Share the PSBT below with the other signers, then combine their signed copies here.")
  let combined ← phone.backend.addMultisigPSBT id (some mine.psbt) theirs.output.get!
  check "combined: complete" ((combined.screen.map (·.progress.complete)) == some true)
  check "combined: next step" ((combined.screen.map (·.progress.nextStep)) == some "Enough signatures verify. Finalize and broadcast.")
  let full ← needE "combined psbt" (PSBT.ofBase64 combined.psbt)
  let (_, final) ← needM "finalize" (account.finalizeSpend full record.utxos (Real.ownedCoordinates record) (height + 304))
  check "the BIP326 sequences survive" ((final.inputs.map (·.sequence)).qsort (· < ·) == #[5, 305])

def testRecoveryPathRefusesCoinsThatAreTooYoung : IO Unit := do
  let phone ← phoneWith 0xA1
  let (id, descriptor) ← phone.backend.createMultisigAccount true "Two phones" 2 [← keyExpression (← masters)[2]!] false
    (some (.fewerSigners 1 1000))
  let account ← needM "account" (MultisigAccount.parse descriptor signet)
  let height := (← phone.record id).createdAtHeight + 1
  discard <| phone.multisig.applyMatch (fakeMatch height #[coinbaseAt height, fundingTx 0x34 (← spk account 0)]) signet
  let destination ← do
    let d ← needE "destination descriptor" (Descriptor.parse s!"tr({← keyExpression (← masters)[0]!})")
    pure ((← needE "derived" (d.derived 5 signet))[0]!.address)
  match ← (phone.backend.createMultisigSpend id destination 20_000 2.0 true).toBaseIO with
  | .ok _ => check "a coin younger than the recovery delay is not offered to the recovery path" false
  | .error e =>
    check "a coin younger than the recovery delay is not offered to the recovery path"
      ((toString e).startsWith "This multisig spend is unsafe:") (toString e)
  match ← (phone.backend.createMultisigSpend id destination 20_000 2.0 false).toBaseIO with
  | .ok p => check "the signers' path spends it at once" p.screen.isSome
  | .error e => check "the signers' path spends it at once" false (toString e)

def testBuilderIsAdvancedModeOnly : IO Unit := do
  let phone ← phoneWith 0xA1
  failsWith "the builder refuses Simple mode"
    (phone.backend.createMultisigAccount false "Two phones" 2 [← keyExpression (← masters)[2]!] false none) Real.advancedModeOnlyText

def flowTests : List (String × IO Unit) :=
  [ ("testBuilderMakesAccountWithAnotherWinnowAndRecovery", testBuilderMakesAccountWithAnotherWinnowAndRecovery)
  , ("testTwoPhonesSignACoSignersSpendWithBIP326Sequences", testTwoPhonesSignACoSignersSpendWithBIP326Sequences)
  , ("testRecoveryPathRefusesCoinsThatAreTooYoung", testRecoveryPathRefusesCoinsThatAreTooYoung)
  , ("testBuilderIsAdvancedModeOnly", testBuilderIsAdvancedModeOnly) ]


/-! ## LedgerPairingTests and LedgerBluetoothTests -/

/-- `SimulatorConnector`: the phone's Ledger is the simulator; `relabelsLeaves` rewrites the leaf hash in
every signature the device yields, as a faulty or tampered device or link would. -/
def Phone.useLedger (p : Phone) (device : IO.Ref Ledger.Simulator) (relabelsLeaves : Bool := false) : IO Unit :=
  p.multisig.ledger.set do
    let base ← Real.simulatedLedger device
    if !relabelsLeaves then return base
    return { base with exchange := fun apdu => do
      let reply ← base.exchange apdu
      -- a yielded script-path signature: tag, input, key length 64, x-only key, leaf hash, signature
      if reply.size > 70 && reply[0]! == 0x10 && reply[2]! == 64 && reply[reply.size - 2]! == 0xE0 && reply[reply.size - 1]! == 0x00 then
        return reply.extract 0 35 ++ zeros 32 0xEE ++ reply.extract 67 reply.size
      return reply }

def simulator (entropyByte : UInt8) : IO (IO.Ref Ledger.Simulator) := do
  IO.mkRef (Ledger.Simulator.new (← master entropyByte))

def testLedgerSigningIsAdvancedModeOnly : IO Unit := do
  let phone ← phoneWith 0xA1
  phone.useLedger (← simulator 0xB2)
  failsWith "pairing refuses Simple mode" (phone.backend.pairLedger false "Phone and Ledger") Real.advancedModeOnlyText
  check "no account" (← phone.accounts).isEmpty

def screenOf (p : MultisigPSBT) : IO MultisigScreen := do
  let some s := p.screen | throw (IO.userError s!"no review: {p.reviewError}")
  return s

def testPairVerifyAndSpendWithBothSigners : IO Unit := do
  let phone ← phoneWith 0xA1
  let device ← simulator 0xB2
  phone.useLedger device
  let id ← phone.backend.pairLedger true "Phone and Ledger"
  let record ← phone.record id
  let account ← needM "account" (MultisigAccount.parse record.descriptor signet)
  check "paired: 2 of 2" (account.threshold == 2 && account.signers.size == 2)
  let ledgerFingerprint := (← master 0xB2).fingerprint
  check "the registration names the Ledger's master and BIP87 path" (match record.ledger with
    | some r => r.masterFingerprint == ledgerFingerprint && r.keyPath == Ledger.Multisig.keyPath .signet
    | none => false)
  check "the Ledger approved the account by name" ((← device.get).registeredNames == #["Phone and Ledger"])
  let again ← phone.backend.pairLedger true "Phone and Ledger"
  check "pairing again refiles the same account" (again == id && (← phone.accounts).length == 1)
  let shown ← phone.backend.verifyLedgerAddress true id 0
  check "the Ledger shows the phone's first address" ((account.address 0).toOption == some shown)
  check "on its screen" ((← device.get).displayedAddresses == #[shown])
  check "the account screen shows the Ledger" (((← phone.accounts).find? (·.id == id)).bind (·.ledgerFingerprint) ==
    some (Descriptor.hex8 (← master 0xB2).fingerprint))
  -- Fund the account, then spend: the phone and the Ledger each sign.
  let height := record.createdAtHeight + 1
  discard <| phone.multisig.applyMatch (fakeMatch height #[coinbaseAt height, fundingTx 0x33 (← spk account 0)]) signet
  let record ← phone.record id
  check "funded" (record.balance == 60_000)
  let destination ← do
    let d ← needE "destination descriptor" (Descriptor.parse s!"tr({← keyExpression (← masters)[2]!})")
    pure ((← needE "derived" (d.derived 0 signet))[0]!.address)
  let created ← phone.backend.createMultisigSpend id destination 40_000 2.0 false
  let screen ← screenOf created
  check "before signing: the signers' path, nothing signed" (screen.signatures == [(false, 0, 2)])
  check "both still to sign" (screen.progress == { phoneHolds := true, phoneUnsigned := true, ledgerHolds := true, ledgerUnsigned := true })
  check "the footer asks for both" (screen.progress.nextStep.startsWith "Add this phone's signature and the Ledger's")
  let byLedger ← phone.backend.signMultisigSpendWithLedger true id created.psbt
  let screen ← screenOf byLedger
  check "the Ledger's signature verifies" (screen.signatures == [(false, 1, 2)] && !screen.progress.ledgerUnsigned && !screen.progress.complete)
  check "then the footer asks for the phone" (screen.progress.nextStep ==
    "Check the payment, then add this phone's signature. Signers can sign in any order.")
  -- A device whose signatures name a leaf they were not made for is refused (SEC-036), nothing added.
  phone.useLedger device (relabelsLeaves := true)
  failsWith "a relabelled Ledger signature is refused" (phone.backend.signMultisigSpendWithLedger true id byLedger.psbt)
    (LedgerError.mismatch "a Ledger signature does not verify").description
  phone.useLedger device
  let both ← phone.backend.signMultisigSpend id byLedger.psbt
  let screen ← screenOf both
  check "both signed: complete" (screen.signatures == [(false, 2, 2)] && screen.progress.complete &&
    screen.progress.nextStep == "Enough signatures verify. Finalize and broadcast.")
  let full ← needE "psbt" (PSBT.ofBase64 both.psbt)
  let (_, tx) ← needM "finalize" (account.finalizeSpend full record.utxos (Real.ownedCoordinates record) height)
  check "finalized with one input" (tx.inputs.size == 1)
  -- A refusal on the Ledger reaches the user as that, and signs nothing.
  device.modify (·.setDecision .reject)
  let unsigned ← phone.backend.createMultisigSpend id destination 40_000 2.0 false
  failsWith "a refusal on the Ledger" (phone.backend.signMultisigSpendWithLedger true id unsigned.psbt)
    LedgerError.rejectedOnDevice.description
  failsWith "Ledger signing refuses Simple mode" (phone.backend.signMultisigSpendWithLedger false id unsigned.psbt)
    Real.advancedModeOnlyText

def testBuilderMakesTwoOfThreeWithAnotherWinnowALedgerAndRecovery : IO Unit := do
  let phone ← phoneWith 0xA1
  let device ← simulator 0xB2
  phone.useLedger device
  let ms ← masters
  let otherWinnow ← keyExpression ms[2]!
  let (id, descriptor) ← phone.backend.createMultisigAccount true "Family 2-of-3" 2 [s!" {otherWinnow} "] true
    (some (.fewerSigners 1 4320))
  let account ← needM "account" (MultisigAccount.parse descriptor signet)
  check "2 of 3 with recovery" (account.threshold == 2 && account.signers.size == 3 &&
    (account.recovery.map (·.blocks)) == some 4320 && (account.recovery.map (·.threshold)) == some 1)
  check "registered" ((← phone.record id).ledger.isSome && (← device.get).registeredNames == #["Family 2-of-3"])
  let otherKey ← needE "other account key" (ms[2]!.derived "m/86'/1'/0'")
  check "the other Winnow's key is a signer" (account.includes otherKey.neutered)
  check "one account" ((← phone.accounts).length == 1)
  failsWith "a name the Ledger cannot show" (phone.backend.createMultisigAccount true "Family é" 2 [otherWinnow] true none)
    Real.invalidNameText

def testStoreRefusesARegistrationForAnotherAccount : IO Unit := do
  let phone ← phoneWith 0xA1
  phone.useLedger (← simulator 0xB2)
  let id ← phone.backend.pairLedger true "Phone and Ledger"
  let record ← phone.record id
  let some registration := record.ledger | throw (IO.userError "no registration")
  let forged := { registration with policyID := zeros 32 0x11 }
  match ← (Real.setLedger phone.multisig id forged).toBaseIO with
  | .ok _ => check "a registration for another policy is not filed" false
  | .error _ => check "a registration for another policy is not filed" true
  check "the store keeps the real one" ((← phone.record id).ledger == some registration)
  check "validate refuses a tampered record"
    ((← (MultisigStore.validate #[{ record with ledger := some forged }] signet).run) matches .error _)
  check "validate accepts the record" ((← (MultisigStore.validate #[record] signet).run) matches .ok _)

def testBluetoothStatesStartFailOrWait : IO Unit := do
  check "poweredOn starts" (match Ledger.Bluetooth.readiness "poweredOn" with | some (.ok ()) => true | _ => false)
  for state in ["poweredOff", "unauthorized", "unsupported"] do
    check s!"{state} fails with a step the user can take" (match Ledger.Bluetooth.readiness state with
      | some (.error (.transport _)) => true | _ => false)
  check "resetting and unknown wait" ((Ledger.Bluetooth.readiness "resetting").isNone && (Ledger.Bluetooth.readiness "unknown").isNone)
  -- the app's transport over a shell answering `unsupported` (the simulator has no Bluetooth)
  let ask : Real.Ask := fun name _ => pure (Task.pure (if name == "ble.state" then
    Lean.Json.mkObj [("state", .str "unsupported")] else Lean.Json.mkObj [("ok", .bool false)]))
  match ← (Real.openLedger ask).toBaseIO with
  | .ok _ => check "no Bluetooth: opening fails" false
  | .error e => check "no Bluetooth: Swift's text" (toString e ==
      (LedgerError.transport "this device has no Bluetooth Low Energy").description) (toString e)

def testNotificationsReachOnlyTheStepInFlight : IO Unit := do
  let router : Ledger.Bluetooth.NotificationRouter := {}
  let mtu := ByteArray.mk #[0x08, 0, 0, 0, 1, 153]
  check "the frame-size reply while asking for it" (((router.receive mtu (some .frameSize)).2.map (·.toOption)) == some (some mtu))
  check "a reply frame is not a frame size" (router.receive (ByteArray.mk #[0x05, 0, 0, 0, 2, 0x90, 0x00]) (some .frameSize)).2.isNone
  check "nothing reaches a written step" (router.receive mtu (some .written)).2.isNone
  check "nothing reaches no step" (router.receive mtu none).2.isNone
  let reply := zeros 30 0x42
  let frames ← needE "frames" (Ledger.BluetoothFraming.frames reply 20)
  check "two frames" (frames.size == 2)
  let (r1, first) := router.receive frames[0]! (some .reply)
  check "the first frame completes nothing" first.isNone
  check "the second completes the reply" (((r1.receive frames[1]! (some .reply)).2.map (·.toOption)) == some (some reply))
  check "a frame without the APDU tag fails the reply" (match ((({} : Ledger.Bluetooth.NotificationRouter).receive
    (ByteArray.mk #[0x07, 0, 0]) (some .reply)).2) with | some (.error _) => true | _ => false)

def ledgerTests : List (String × IO Unit) :=
  [ ("testLedgerSigningIsAdvancedModeOnly", testLedgerSigningIsAdvancedModeOnly)
  , ("testPairVerifyAndSpendWithBothSigners", testPairVerifyAndSpendWithBothSigners)
  , ("testBuilderMakesTwoOfThreeWithAnotherWinnowALedgerAndRecovery", testBuilderMakesTwoOfThreeWithAnotherWinnowALedgerAndRecovery)
  , ("testStoreRefusesARegistrationForAnotherAccount", testStoreRefusesARegistrationForAnotherAccount)
  , ("testBluetoothStatesStartFailOrWait", testBluetoothStatesStartFailOrWait)
  , ("testNotificationsReachOnlyTheStepInFlight", testNotificationsReachOnlyTheStepInFlight) ]

/-! ## main -/

def storeTests : List (String × IO Unit) :=
  [ ("testBackupPreservesAccountsAndRejectsChangedOwnership", testBackupPreservesAccountsAndRejectsChangedOwnership)
  , ("testBackupWaitsForPendingAccountPayments", testBackupWaitsForPendingAccountPayments)
  , ("testPaymentsSpendsAndRollbacks", testPaymentsSpendsAndRollbacks)
  , ("testARollbackKeepsTheInputsOfAFallenSpendReserved", testARollbackKeepsTheInputsOfAFallenSpendReserved)
  , ("testARollbackKeepsAReservedCoinFromAFallenBlock", testARollbackKeepsAReservedCoinFromAFallenBlock)
  , ("testZeroValueOutputIsIgnoredAndTheScanMovesOn", testZeroValueOutputIsIgnoredAndTheScanMovesOn)
  , ("testALosingInFlightSpendReleasesItsCoinsAndDropsItsChange", testALosingInFlightSpendReleasesItsCoinsAndDropsItsChange)
  , ("testLookaheadFindsPaymentsUpToTheGapLimitAhead", testLookaheadFindsPaymentsUpToTheGapLimitAhead)
  , ("testTamperedUnsealedAndOversizedFilesAreRefusedAndKept", testTamperedUnsealedAndOversizedFilesAreRefusedAndKept)
  , ("testDuplicateWrongNetworkAndBadNamesAreRefused", testDuplicateWrongNetworkAndBadNamesAreRefused) ]

def main : IO UInt32 := do
  let root ← IO.FS.createTempDir
  tempRoot.set root
  IO.println s!"multisig-app-test in {root}"
  IO.println "MultisigStoreTests"
  for (name, t) in storeTests do runTest name t
  IO.println "MultisigAccountFlowTests"
  for (name, t) in flowTests do runTest name t
  IO.println "LedgerPairingTests, LedgerBluetoothTests"
  for (name, t) in ledgerTests do runTest name t
  try IO.FS.removeDirAll root catch _ => pure ()
  let failed ← failures.get
  IO.println s!"multisig-app-test: {← passed.get} passed, {failed.size} failed"
  return if failed.isEmpty then 0 else 1
