import SpendReview.Model

/-!
# What an accepted review guarantees, and that review refuses only for a reason

Proved about the model in `Model.lean`, by induction over the inputs and
outputs, with Lean core tactics only (`simp`, `omega`, `split`, `cases`):
`review_ok` and its corollaries say what acceptance establishes,
`review_ignores_output_metadata` that output metadata is never read, and
`review_complete` that every spend meeting the rules is accepted.
No `sorry`, `native_decide` or `bv_decide`, so the kernel checks every step.

That the Swift computes the same function is not proved here: the
differential suite (`SpendReviewSpecificationTests`) tests it on the
generated vectors.
-/

namespace SpendReview

/-- `R` holds between the two lists element by element. -/
inductive Forall2 {α β} (R : α → β → Prop) : List α → List β → Prop
  | nil : Forall2 R [] []
  | cons {a b as bs} : R a b → Forall2 R as bs → Forall2 R (a :: as) (b :: bs)

theorem Forall2.imp {α β} {R S : α → β → Prop} (f : ∀ a b, R a b → S a b) :
    ∀ {as bs}, Forall2 R as bs → Forall2 S as bs
  | _, _, .nil => .nil
  | _, _, .cons h rest => .cons (f _ _ h) (Forall2.imp f rest)

theorem Forall2.left {α β} {R : α → β → Prop} {P : α → Prop} (f : ∀ a b, R a b → P a) :
    ∀ {as bs}, Forall2 R as bs → ∀ a ∈ as, P a
  | _, _, .nil => by simp
  | _, _, .cons h rest => by
    intro a ha
    cases List.mem_cons.mp ha with
    | inl he => subst he; exact f _ _ h
    | inr hin => exact Forall2.left f rest a hin

/-- What review establishes about one input and the known coin it spends. -/
structure Spends (a : Account) (known : List Coin) (tip : Nat) (path : Path) (inp : Input) (k : Coin) : Prop where
  outpoint : inp.txid = some k.txid ∧ inp.vout = some k.vout
  known : findCoin known k.txid k.vout = some k
  witness : inp.witness = some (k.amount, k.script)
  amount : 0 < k.amount ∧ k.amount ≤ maxMoney
  derived : k.index < 2 ^ 31 ∧ k.script = .account k.chain.toNat k.index
  mature : k.coinbase = true → k.height + coinbaseMaturity - 1 ≤ tip
  hashType : inp.sighash.getD 0 = 0 ∨ inp.sighash.getD 0 = 1
  internalKey : inp.internalKey = some (.internal k.chain.toNat k.index)
  leaves : inp.leaves.Perm (a.expectedLeaves k.chain.toNat k.index)
  unlocked : path = .recovery → a.unlocked k tip = true

theorem checkInput_ok {a : Account} {tip : Nat} {k : Coin} {inp : Input} {i : Nat}
    (h : checkInput a tip k inp i = .ok ()) :
    (0 < k.amount ∧ k.amount ≤ maxMoney ∧ inp.witness = some (k.amount, k.script)) ∧
    (k.coinbase = true → k.height + coinbaseMaturity - 1 ≤ tip) ∧
    (k.index < 2 ^ 31 ∧ k.script = .account k.chain.toNat k.index) ∧
    (inp.sighash.getD 0 = 0 ∨ inp.sighash.getD 0 = 1) ∧
    inp.internalKey = some (.internal k.chain.toNat k.index) ∧
    inp.leaves.Perm (a.expectedLeaves k.chain.toNat k.index) := by
  unfold checkInput derive at h
  by_cases h1 : 0 < k.amount ∧ k.amount ≤ maxMoney ∧ inp.witness = some (k.amount, k.script)
  · by_cases h2 : k.coinbase = true ∧ tip < k.height + coinbaseMaturity - 1
    · simp [h1, h2] at h
    · by_cases h3 : k.index < 2 ^ 31
      · by_cases h4 : Script.account k.chain.toNat k.index = k.script
        · by_cases h5 : inp.sighash.getD 0 = 0 ∨ inp.sighash.getD 0 = 1
          · by_cases h6 : inp.internalKey = some (.internal k.chain.toNat k.index) ∧
                inp.leaves.isPerm (a.expectedLeaves k.chain.toNat k.index) = true
            · refine ⟨h1, fun hc => ?_, ⟨h3, h4.symm⟩, h5, h6.1, List.isPerm_iff.mp h6.2⟩
              have := not_and.mp h2 hc
              omega
            · simp [h1, h2, h3, h4, h5, h6] at h
          · simp [h1, h2, h3, h4, h5] at h
        · simp [h1, h2, h3, h4] at h
      · simp [h1, h2, h3] at h
  · simp [h1] at h

theorem findCoin_some {known : List Coin} {t v : Nat} {k : Coin} (h : findCoin known t v = some k) :
    k ∈ known ∧ k.txid = t ∧ k.vout = v := by
  unfold findCoin at h
  have hp := List.find?_some h
  simp at hp
  exact ⟨List.mem_of_find?_eq_some h, hp.1, hp.2⟩

theorem reviewInputs_ok {a : Account} {known : List Coin} {tip : Nat} {path : Path} :
    ∀ {inps : List Input} {i : Nat} {seen : List (Nat × Nat)} {total : Int} {coins : List Coin} {sum : Int},
      reviewInputs a known tip path inps i seen total = .ok (coins, sum) →
      Forall2 (Spends a known tip path) inps coins ∧
      sum = total + (coins.map (·.amount)).sum ∧
      (total ≤ maxMoney → sum ≤ maxMoney) ∧
      (coins.map fun k => (k.txid, k.vout)).Nodup ∧
      (∀ k ∈ coins, (k.txid, k.vout) ∉ seen)
  | [], i, seen, total, coins, sum, h => by
    simp [reviewInputs] at h
    obtain ⟨rfl, rfl⟩ := h
    exact ⟨.nil, by simp, id, by simp, by simp⟩
  | inp :: rest, i, seen, total, coins, sum, h => by
    unfold reviewInputs at h
    match ht : inp.txid, hv : inp.vout with
    | some t, some v =>
      simp only [ht, hv] at h
      by_cases hs : (t, v) ∈ seen
      · simp [hs] at h
      · simp only [hs, ite_false] at h
        match hf : findCoin known t v with
        | none => simp [hf] at h
        | some k =>
          simp only [hf] at h
          match hc : checkInput a tip k inp i with
          | .error e => simp [hc] at h
          | .ok () =>
            simp only [hc] at h
            by_cases hl : path = .recovery ∧ a.unlocked k tip = false
            · simp [hl] at h
            · by_cases hm : maxMoney < total + k.amount
              · simp [hl, hm] at h
              · simp only [hl, hm, ite_false] at h
                match hr : reviewInputs a known tip path rest (i + 1) ((t, v) :: seen) (total + k.amount) with
                | .error e => simp [hr] at h
                | .ok (coins', sum') =>
                  simp only [hr, Except.ok.injEq, Prod.mk.injEq] at h
                  obtain ⟨rfl, rfl⟩ := h
                  obtain ⟨hall, hsum, hbound, hnodup, hfresh⟩ := reviewInputs_ok hr
                  obtain ⟨hk, hkt, hkv⟩ := findCoin_some hf
                  subst hkt hkv
                  obtain ⟨hamount, hmature, hderived, hhash, hkey, hleaves⟩ := checkInput_ok hc
                  have hunlocked : path = .recovery → a.unlocked k tip = true := by
                    intro hp
                    cases hu : a.unlocked k tip
                    · exact absurd ⟨hp, hu⟩ hl
                    · rfl
                  refine ⟨.cons ⟨⟨ht, hv⟩, hf, hamount.2.2, ⟨hamount.1, hamount.2.1⟩, hderived, hmature, hhash,
                      hkey, hleaves, hunlocked⟩ hall, ?_, ?_, ?_, ?_⟩
                  · simp [hsum]
                    omega
                  · intro _
                    exact hbound (by omega)
                  · refine List.nodup_cons.mpr ⟨?_, hnodup⟩
                    intro hmem
                    obtain ⟨k', hk', heq⟩ := List.mem_map.mp hmem
                    exact hfresh k' hk' (by simp [heq])
                  · intro k' hk'
                    cases List.mem_cons.mp hk' with
                    | inl he => subst he; exact hs
                    | inr hin => exact fun hseen => hfresh k' hin (List.mem_cons_of_mem _ hseen)
    | none, _ => simp [ht] at h
    | some _, none => simp [ht, hv] at h

theorem reviewOutputs_ok {owned : List Script} :
    ∀ {outs : List Output} {j : Nat} {total : Int} {shown : List Shown} {sum : Int},
      reviewOutputs owned outs j total = .ok (shown, sum) →
      shown.map (fun s => (some s.amount, some s.script)) = outs.map (fun o => (o.amount, o.script)) ∧
      (∀ s ∈ shown, 0 < s.amount ∧ s.amount ≤ maxMoney ∧ s.script ≠ .empty ∧ (s.owned = true ↔ s.script ∈ owned)) ∧
      sum = total + (shown.map (·.amount)).sum ∧
      (total ≤ maxMoney → sum ≤ maxMoney)
  | [], j, total, shown, sum, h => by
    simp [reviewOutputs] at h
    obtain ⟨rfl, rfl⟩ := h
    exact ⟨rfl, by simp, by simp, id⟩
  | o :: rest, j, total, shown, sum, h => by
    unfold reviewOutputs at h
    match ha : o.amount, hs : o.script with
    | some amount, some script =>
      simp only [ha, hs] at h
      by_cases hbad : amount ≤ 0 ∨ maxMoney < amount ∨ script = .empty
      · simp [hbad] at h
      · by_cases hm : maxMoney < total + amount
        · simp [hbad, hm] at h
        · simp only [hbad, hm, ite_false] at h
          match hr : reviewOutputs owned rest (j + 1) (total + amount) with
          | .error e => simp [hr] at h
          | .ok (shown', sum') =>
            simp only [hr, Except.ok.injEq, Prod.mk.injEq] at h
            obtain ⟨rfl, rfl⟩ := h
            obtain ⟨hmap, hall, hsum, hbound⟩ := reviewOutputs_ok hr
            refine ⟨?_, ?_, ?_, ?_⟩
            · simp [ha, hs, hmap]
            · intro s hmem
              cases List.mem_cons.mp hmem with
              | inl he =>
                subst he
                simp only [not_or] at hbad
                exact ⟨by dsimp only; omega, by dsimp only; omega, hbad.2.2, by simp⟩
              | inr hin => exact hall s hin
            · simp [hsum]
              omega
            · intro _
              exact hbound (by omega)
    | none, _ => simp [ha] at h
    | some _, none => simp [ha, hs] at h

theorem deriveAll_ok : ∀ {cs : List (Int × Nat)} {ss : List Script}, deriveAll cs = .ok ss →
    ss = cs.map (fun c => Script.account c.1.toNat c.2) ∧ ∀ c ∈ cs, c.2 < 2 ^ 31
  | [], ss, h => by
    simp [deriveAll] at h
    subst h
    simp
  | c :: cs, ss, h => by
    unfold deriveAll derive at h
    by_cases hc : c.2 < 2 ^ 31
    · simp only [hc, ite_true] at h
      match hr : deriveAll cs with
      | .error e => simp [hr] at h
      | .ok ss' =>
        simp only [hr, Except.ok.injEq] at h
        subst h
        obtain ⟨hmap, hall⟩ := deriveAll_ok hr
        refine ⟨by simp [hmap], ?_⟩
        intro c' hc'
        cases List.mem_cons.mp hc' with
        | inl he => subst he; exact hc
        | inr hin => exact hall c' hin
    · simp [hc] at h

theorem spendPath_ok {a : Account} {p : Psbt} {path : Path} (h : spendPath a p = .ok path) :
    path = .recovery ↔ ∃ b, a.recovery = some b ∧ ∀ x ∈ p.inputs, lockMet b x.seq p.txVersion = true := by
  unfold spendPath at h
  match hr : a.recovery with
  | none =>
    simp only [hr, Except.ok.injEq] at h
    subst h
    simp
  | some b =>
    simp only [hr] at h
    by_cases h1 : p.inputs.any (fun i => i.txid.isNone || i.vout.isNone) = true
    · simp [h1] at h
    · by_cases h2 : p.outputs.any (fun o => o.amount.isNone || o.script.isNone) = true
      · simp [h1, h2] at h
      · by_cases h3 : p.inputs.all (fun i => lockMet b i.seq p.txVersion) = true
        · simp only [h1, h2, h3, ite_true, ite_false, Bool.false_eq_true, Except.ok.injEq] at h
          subst h
          simp only [true_iff]
          exact ⟨b, rfl, List.all_eq_true.mp h3⟩
        · simp only [h1, h2, h3, ite_false, Bool.false_eq_true, Except.ok.injEq] at h
          subst h
          simp only [reduceCtorEq, false_iff, not_exists, not_and]
          intro b' hb hall
          cases hb
          exact h3 (List.all_eq_true.mpr hall)

/-- Everything an accepted review establishes. -/
structure Accepted (a : Account) (p : Psbt) (known : List Coin) (coords : List (Int × Nat)) (tip : Nat)
    (r : Review) : Prop where
  shape : p.inputs ≠ [] ∧ p.outputs ≠ [] ∧ p.outputs.length ≤ 1000 ∧ (p.txVersion = 1 ∨ p.txVersion = 2)
  shown : r.outputs.map (fun s => (some s.amount, some s.script)) = p.outputs.map (fun o => (o.amount, o.script))
  lines : ∀ s ∈ r.outputs, 0 < s.amount ∧ s.amount ≤ maxMoney ∧ s.script ≠ .empty
  owned : ∀ s ∈ r.outputs, s.owned = true ↔ ∃ c ∈ coords, (c.1 = 0 ∨ c.1 = 1) ∧ s.script = .account c.1.toNat c.2
  coins : ∃ coins, Forall2 (Spends a known tip r.path) p.inputs coins ∧
    (coins.map fun k => (k.txid, k.vout)).Nodup ∧ r.inputTotal = (coins.map (·.amount)).sum
  inputTotal : r.inputTotal ≤ maxMoney
  outputTotal : r.outputTotal = (r.outputs.map (·.amount)).sum
  fee : r.fee = r.inputTotal - r.outputTotal ∧ 0 ≤ r.fee ∧ r.fee ≤ r.inputTotal / 10
  path : r.path = .recovery ↔ ∃ b, a.recovery = some b ∧ ∀ x ∈ p.inputs, lockMet b x.seq p.txVersion = true

theorem review_ok {a : Account} {p : Psbt} {known : List Coin} {coords : List (Int × Nat)} {tip : Nat} {r : Review}
    (h : review a p known coords tip = .ok r) : Accepted a p known coords tip r := by
  unfold review at h
  by_cases h1 : p.inputs = []
  · simp [h1] at h
  by_cases h2 : p.outputs = [] ∨ 1000 < p.outputs.length
  · simp [h1, h2] at h
  by_cases h3 : p.txVersion = 1 ∨ p.txVersion = 2
  · simp only [h1, h2, h3, ite_false, not_true_eq_false] at h
    match hp : spendPath a p with
    | .error e => simp [hp] at h
    | .ok path =>
      simp only [hp] at h
      match hi : reviewInputs a known tip path p.inputs 0 [] 0 with
      | .error e => simp [hi] at h
      | .ok (coins, inputTotal) =>
        simp only [hi] at h
        by_cases hc : 1024 < (distinct (candidateCoordinates coords)).length
        · simp [hc] at h
        · simp only [hc, ite_false] at h
          match hd : deriveAll (candidateCoordinates coords) with
          | .error e => simp [hd] at h
          | .ok owned =>
            simp only [hd] at h
            match ho : reviewOutputs owned p.outputs 0 0 with
            | .error e => simp [ho] at h
            | .ok (shown, outputTotal) =>
              simp only [ho] at h
              by_cases he : inputTotal < outputTotal
              · simp [he] at h
              · by_cases hf : inputTotal / 10 < inputTotal - outputTotal
                · simp [he, hf] at h
                · simp only [he, hf, ite_false, Except.ok.injEq] at h
                  subst h
                  obtain ⟨hall, hsum, hbound, hnodup, -⟩ := reviewInputs_ok hi
                  obtain ⟨hmap, hlines, hosum, -⟩ := reviewOutputs_ok ho
                  obtain ⟨howned, -⟩ := deriveAll_ok hd
                  simp only [not_or, Nat.not_lt] at h2
                  refine ⟨⟨h1, h2.1, h2.2, h3⟩, hmap, fun s hs => ?_, fun s hs => ?_,
                    ⟨coins, hall, hnodup, by simpa using hsum⟩, hbound (by decide), by simpa using hosum,
                    ⟨rfl, by dsimp only; omega, by dsimp only; omega⟩, spendPath_ok hp⟩
                  · exact ⟨(hlines s hs).1, (hlines s hs).2.1, (hlines s hs).2.2.1⟩
                  · rw [(hlines s hs).2.2.2, howned]
                    simp only [List.mem_map, candidateCoordinates, List.mem_filter, decide_eq_true_eq]
                    constructor
                    · rintro ⟨c, ⟨hc, hrange⟩, heq⟩
                      exact ⟨c, hc, by omega, heq.symm⟩
                    · rintro ⟨c, hc, hrange, heq⟩
                      exact ⟨c, ⟨hc, by omega⟩, heq.symm⟩
  · simp [h1, h2, h3] at h

/-! ## The guarantees, one at a time -/

/-- What review shows is the PSBT's outputs: every one, in order, with its
amount and script, and nothing else. -/
theorem shows_every_output {a p known coords tip r} (h : review a p known coords tip = .ok r) :
    r.outputs.map (fun s => (some s.amount, some s.script)) = p.outputs.map (fun o => (o.amount, o.script)) :=
  (review_ok h).shown

/-- The fee shown is the inputs' known amounts less every output, between
zero and a tenth of the inputs. -/
theorem fee_is_what_the_miner_gets {a p known coords tip r} (h : review a p known coords tip = .ok r) :
    ∃ coins : List Coin, Forall2 (Spends a known tip r.path) p.inputs coins ∧
      r.fee = (coins.map (·.amount)).sum - (r.outputs.map (·.amount)).sum ∧
      0 ≤ r.fee ∧ r.fee ≤ (coins.map (·.amount)).sum / 10 := by
  obtain ⟨coins, hall, -, hin⟩ := (review_ok h).coins
  have hfee := (review_ok h).fee
  exact ⟨coins, hall, by rw [hfee.1, ← hin, (review_ok h).outputTotal], hfee.2.1, by rw [← hin]; exact hfee.2.2⟩

/-- "Back to this account" appears exactly on outputs a caller-supplied
coordinate derives, never from anything the PSBT says (SEC-004). -/
theorem ownership_comes_from_coordinates {a p known coords tip r} (h : review a p known coords tip = .ok r) :
    ∀ s ∈ r.outputs, s.owned = true ↔ ∃ c ∈ coords, (c.1 = 0 ∨ c.1 = 1) ∧ s.script = .account c.1.toNat c.2 :=
  (review_ok h).owned

/-- No two inputs spend the same coin. -/
theorem inputs_are_distinct_coins {a p known coords tip r} (h : review a p known coords tip = .ok r) :
    ∃ coins : List Coin, Forall2 (Spends a known tip r.path) p.inputs coins ∧
      (coins.map fun k => (k.txid, k.vout)).Nodup := by
  obtain ⟨coins, hall, hnodup, -⟩ := (review_ok h).coins
  exact ⟨coins, hall, hnodup⟩

/-- The recovery path is chosen exactly when the account has one and every
input's sequence meets its lock; a mix is the signers' path (SEC-035). -/
theorem recovery_path_iff {a p known coords tip r} (h : review a p known coords tip = .ok r) :
    r.path = .recovery ↔ ∃ b, a.recovery = some b ∧ ∀ x ∈ p.inputs, lockMet b x.seq p.txVersion = true :=
  (review_ok h).path

theorem mixed_sequences_take_signers_path {a p known coords tip r} (h : review a p known coords tip = .ok r)
    {b : Nat} (hb : a.recovery = some b) {x : Input} (hx : x ∈ p.inputs) (hlock : lockMet b x.seq p.txVersion = false) :
    r.path = .signers := by
  cases hpath : r.path with
  | signers => rfl
  | recovery =>
    obtain ⟨b', hb', hall⟩ := (recovery_path_iff h).mp hpath
    rw [hb] at hb'
    cases hb'
    simp [hall x hx] at hlock

/-- A recovery-path review only spends coins already unlocked for it, and a
plain account never reviews as a recovery spend. -/
theorem recovery_spends_only_unlocked_coins {a p known coords tip r} (h : review a p known coords tip = .ok r)
    (hpath : r.path = .recovery) :
    ∃ coins : List Coin, Forall2 (fun _ k => a.unlocked k tip = true) p.inputs coins := by
  obtain ⟨coins, hall, -, -⟩ := (review_ok h).coins
  exact ⟨coins, hall.imp fun _ _ hs => hs.unlocked hpath⟩

theorem plain_account_signers_path {a p known coords tip r} (h : review a p known coords tip = .ok r)
    (hplain : a.recovery = none) : r.path = .signers := by
  cases hpath : r.path with
  | signers => rfl
  | recovery =>
    obtain ⟨b, hb, -⟩ := (recovery_path_iff h).mp hpath
    simp [hplain] at hb

/-- Every input's hash type commits to every output (SIGHASH_DEFAULT or
SIGHASH_ALL), so with BIP341 each signature binds the outputs review showed. -/
theorem every_signature_commits_to_all_outputs {a p known coords tip r} (h : review a p known coords tip = .ok r) :
    ∀ x ∈ p.inputs, x.sighash.getD 0 = 0 ∨ x.sighash.getD 0 = 1 := by
  obtain ⟨coins, hall, -, -⟩ := (review_ok h).coins
  exact hall.left fun _ _ hs => hs.hashType

/-! ## What review never reads -/

theorem reviewOutputs_map {owned : List Script} (f : Output → Output)
    (hamount : ∀ o, (f o).amount = o.amount) (hscript : ∀ o, (f o).script = o.script) :
    ∀ (outs : List Output) (j : Nat) (total : Int),
      reviewOutputs owned (outs.map f) j total = reviewOutputs owned outs j total
  | [], _, _ => rfl
  | o :: rest, j, total => by
    simp only [List.map_cons]
    unfold reviewOutputs
    rw [hamount o, hscript o]
    simp only [reviewOutputs_map f hamount hscript rest]

/-- Nothing a PSBT says about an output beyond its amount and script, such
as BIP371 metadata calling it the account's change, changes what review
shows or decides (SEC-004). -/
theorem review_ignores_output_metadata (f : Output → Output)
    (hamount : ∀ o, (f o).amount = o.amount) (hscript : ∀ o, (f o).script = o.script)
    (a : Account) (p : Psbt) (known : List Coin) (coords : List (Int × Nat)) (tip : Nat) :
    review a { p with outputs := p.outputs.map f } known coords tip = review a p known coords tip := by
  have hpath : spendPath a { p with outputs := p.outputs.map f } = spendPath a p := by
    unfold spendPath
    simp [List.any_map, Function.comp_def, hamount, hscript]
  unfold review
  simp only [List.map_eq_nil_iff, List.length_map, hpath, reviewOutputs_map f hamount hscript]

/-! ## Review refuses only for a stated reason

The converse of `review_ok`: a spend whose every input is a distinct
known coin carrying the account's own fields, whose outputs are valid and
whose fee is within the ceiling is accepted. An over-refusal like SEC-035
(a co-signer's BIP326 spend refused for mixing sequences) contradicts it. -/

/-- The path `spendPath` takes once the PSBT's fields are present. -/
def Account.pathFor (a : Account) (p : Psbt) : Path :=
  match a.recovery with
  | none => .signers
  | some b => if p.inputs.all (fun i => lockMet b i.seq p.txVersion) then .recovery else .signers

theorem checkInput_complete {a : Account} {known : List Coin} {tip : Nat} {path : Path} {inp : Input} {k : Coin}
    (i : Nat) (hs : Spends a known tip path inp k) : checkInput a tip k inp i = .ok () := by
  have hmature : ¬(k.coinbase = true ∧ tip < k.height + coinbaseMaturity - 1) := by
    intro ⟨hc, hlt⟩
    have := hs.mature hc
    omega
  unfold checkInput derive
  simp [hs.amount.1, hs.amount.2, hs.witness, hmature, hs.derived.1, hs.derived.2, hs.hashType, hs.internalKey,
    List.isPerm_iff.mpr hs.leaves]

theorem Forall2.sum_nonneg {a : Account} {known : List Coin} {tip : Nat} {path : Path} :
    ∀ {inps : List Input} {coins : List Coin}, Forall2 (Spends a known tip path) inps coins →
      0 ≤ (coins.map (·.amount)).sum
  | _, _, .nil => by simp
  | _, _, .cons hs rest => by
    have := Forall2.sum_nonneg rest
    have := hs.amount.1
    simp only [List.map_cons, List.sum_cons]
    omega

theorem reviewInputs_complete {a : Account} {known : List Coin} {tip : Nat} {path : Path} :
    ∀ {inps : List Input} {coins : List Coin} (i : Nat) (seen : List (Nat × Nat)) (total : Int),
      Forall2 (Spends a known tip path) inps coins →
      (coins.map fun k => (k.txid, k.vout)).Nodup →
      (∀ k ∈ coins, (k.txid, k.vout) ∉ seen) →
      total + (coins.map (·.amount)).sum ≤ maxMoney →
      reviewInputs a known tip path inps i seen total = .ok (coins, total + (coins.map (·.amount)).sum)
  | _, _, _, _, total, .nil, _, _, _ => by simp [reviewInputs]
  | inp :: rest, k :: coins, i, seen, total, .cons hs hrest, hnodup, hfresh, hbound => by
    obtain ⟨hnot, hnodup'⟩ := List.nodup_cons.mp hnodup
    have hrestsum := Forall2.sum_nonneg hrest
    have hunlocked : ¬(path = .recovery ∧ a.unlocked k tip = false) := by
      intro ⟨hp, hu⟩
      rw [hs.unlocked hp] at hu
      cases hu
    have hfresh' : ∀ k' ∈ coins, (k'.txid, k'.vout) ∉ (k.txid, k.vout) :: seen := by
      intro k' hk' hmem
      cases List.mem_cons.mp hmem with
      | inl he => exact hnot (List.mem_map.mpr ⟨k', hk', he⟩)
      | inr hin => exact hfresh k' (List.mem_cons_of_mem _ hk') hin
    simp only [List.map_cons, List.sum_cons] at hbound ⊢
    have hstep : ¬(maxMoney < total + k.amount) := by omega
    have hrec := reviewInputs_complete (i + 1) ((k.txid, k.vout) :: seen) (total + k.amount) hrest hnodup' hfresh'
      (by omega)
    unfold reviewInputs
    rw [hs.outpoint.1, hs.outpoint.2]
    simp only [hfresh k List.mem_cons_self, hs.known,
      checkInput_complete i hs, hunlocked, hstep, hrec]
    simp only [ite_false, Except.ok.injEq, Prod.mk.injEq, true_and]
    omega

theorem deriveAll_complete : ∀ {cs : List (Int × Nat)}, (∀ c ∈ cs, c.2 < 2 ^ 31) →
    deriveAll cs = .ok (cs.map fun c => Script.account c.1.toNat c.2)
  | [], _ => rfl
  | c :: cs, h => by
    unfold deriveAll derive
    simp [h c List.mem_cons_self, deriveAll_complete (fun c' hc' => h c' (List.mem_cons_of_mem _ hc'))]

/-- An output review accepts on its own. -/
def Output.valid (o : Output) : Prop :=
  ∃ amount script, o.amount = some amount ∧ o.script = some script ∧ 0 < amount ∧ amount ≤ maxMoney ∧ script ≠ .empty

def outputSum (outs : List Output) : Int := (outs.map fun o => o.amount.getD 0).sum

theorem outputSum_nonneg : ∀ {outs : List Output}, (∀ o ∈ outs, o.valid) → 0 ≤ outputSum outs
  | [], _ => by simp [outputSum]
  | o :: rest, h => by
    obtain ⟨amount, _, ha, -, hpos, -⟩ := h o List.mem_cons_self
    have := outputSum_nonneg (fun o' ho' => h o' (List.mem_cons_of_mem _ ho'))
    simp only [outputSum, List.map_cons, List.sum_cons, ha, Option.getD_some] at this ⊢
    omega

theorem reviewOutputs_complete {owned : List Script} :
    ∀ {outs : List Output} (j : Nat) (total : Int), (∀ o ∈ outs, o.valid) → total + outputSum outs ≤ maxMoney →
      ∃ shown, reviewOutputs owned outs j total = .ok (shown, total + outputSum outs)
  | [], _, total, _, _ => ⟨[], by simp [reviewOutputs, outputSum]⟩
  | o :: rest, j, total, h, hbound => by
    obtain ⟨amount, script, ha, hs, hpos, hmax, hne⟩ := h o List.mem_cons_self
    have hrestvalid : ∀ o' ∈ rest, o'.valid := fun o' ho' => h o' (List.mem_cons_of_mem _ ho')
    have hrestsum := outputSum_nonneg hrestvalid
    simp only [outputSum, List.map_cons, List.sum_cons, ha, Option.getD_some] at hbound hrestsum ⊢
    have hbad : ¬(amount ≤ 0 ∨ maxMoney < amount ∨ script = .empty) := by
      simp only [not_or]
      exact ⟨by omega, by omega, hne⟩
    have hstep : ¬(maxMoney < total + amount) := by omega
    obtain ⟨shown, hrec⟩ := reviewOutputs_complete (owned := owned) (j + 1) (total + amount) hrestvalid
      (by simp only [outputSum]; omega)
    refine ⟨⟨amount, script, decide (script ∈ owned)⟩ :: shown, ?_⟩
    unfold reviewOutputs
    rw [ha, hs]
    simp only [outputSum] at hrec
    simp only [hbad, hstep, ite_false, hrec, Except.ok.injEq, Prod.mk.injEq, true_and]
    omega

theorem spendPath_complete {a : Account} {p : Psbt}
    (hin : ∀ x ∈ p.inputs, x.txid.isSome ∧ x.vout.isSome) (hout : ∀ o ∈ p.outputs, o.valid) :
    spendPath a p = .ok (a.pathFor p) := by
  have h1 : p.inputs.any (fun i => i.txid.isNone || i.vout.isNone) = false := by
    simp only [List.any_eq_false, Bool.or_eq_true, not_or]
    intro x hx
    obtain ⟨ht, hv⟩ := hin x hx
    simp [Option.isNone_iff_eq_none, Option.isSome_iff_ne_none.mp ht, Option.isSome_iff_ne_none.mp hv]
  have h2 : p.outputs.any (fun o => o.amount.isNone || o.script.isNone) = false := by
    simp only [List.any_eq_false, Bool.or_eq_true, not_or]
    intro o ho
    obtain ⟨amount, script, ha, hs, -⟩ := hout o ho
    simp [ha, hs]
  unfold spendPath Account.pathFor
  cases a.recovery with
  | none => rfl
  | some b =>
    simp only [h1, h2, Bool.false_eq_true, ite_false]
    split <;> rfl

/-- Review accepts every spend that meets its stated rules. -/
theorem review_complete {a : Account} {p : Psbt} {known : List Coin} {coords : List (Int × Nat)} {tip : Nat}
    {coins : List Coin}
    (hin : p.inputs ≠ []) (hout : p.outputs ≠ []) (hcount : p.outputs.length ≤ 1000)
    (hversion : p.txVersion = 1 ∨ p.txVersion = 2)
    (hspends : Forall2 (Spends a known tip (a.pathFor p)) p.inputs coins)
    (hdistinct : (coins.map fun k => (k.txid, k.vout)).Nodup)
    (hsupply : (coins.map (·.amount)).sum ≤ maxMoney)
    (hvalid : ∀ o ∈ p.outputs, o.valid)
    (hcandidates : (distinct (candidateCoordinates coords)).length ≤ 1024)
    (hderivable : ∀ c ∈ coords, c.2 < 2 ^ 31)
    (hconserve : outputSum p.outputs ≤ (coins.map (·.amount)).sum)
    (hfee : (coins.map (·.amount)).sum - outputSum p.outputs ≤ (coins.map (·.amount)).sum / 10) :
    ∃ r, review a p known coords tip = .ok r := by
  have hfields : ∀ x ∈ p.inputs, x.txid.isSome ∧ x.vout.isSome :=
    hspends.left fun x k hs => by simp [hs.outpoint.1, hs.outpoint.2]
  have hinputs := reviewInputs_complete 0 [] 0 hspends hdistinct (by simp) (by simpa using hsupply)
  have hderive := deriveAll_complete (cs := candidateCoordinates coords) fun c hc =>
    hderivable c (List.mem_filter.mp hc).1
  obtain ⟨shown, houtputs⟩ := reviewOutputs_complete (owned := (candidateCoordinates coords).map
    fun c => Script.account c.1.toNat c.2) 0 0 hvalid (by have := outputSum_nonneg hvalid; omega)
  unfold review
  simp only [hin, hout, false_or, ite_false, Nat.not_lt.mpr hcount, hversion, not_true_eq_false,
    spendPath_complete hfields hvalid, hinputs, Nat.not_lt.mpr hcandidates, hderive, houtputs]
  simp only [Int.zero_add]
  have hc : ¬((coins.map (·.amount)).sum < outputSum p.outputs) := by omega
  have hf : ¬((coins.map (·.amount)).sum / 10 < (coins.map (·.amount)).sum - outputSum p.outputs) := by omega
  simp only [hc, hf, ite_false]
  exact ⟨_, rfl⟩

/-- A co-signer's BIP326 spend mixes sequences that meet the recovery lock
with ones that do not; with valid coins it is accepted, on the signers'
path, whatever the coins' ages (SEC-035). -/
theorem mixed_sequences_accepted {a : Account} {b : Nat} (hb : a.recovery = some b) {p : Psbt}
    {x : Input} (hx : x ∈ p.inputs) (hlock : lockMet b x.seq p.txVersion = false) :
    a.pathFor p = .signers := by
  unfold Account.pathFor
  rw [hb]
  have : p.inputs.all (fun i => lockMet b i.seq p.txVersion) = false := by
    simp only [List.all_eq_false]
    exact ⟨x, hx, by simp [hlock]⟩
  simp [this]

end SpendReview
