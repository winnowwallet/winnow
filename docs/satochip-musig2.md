# Satochip as a MuSig2 cosigner

Design note, October 2026. It asks whether a Satochip card can be the first
hardware cosigner for the raw MuSig2 accounts of
[PR #235](https://github.com/winnowwallet/winnow/pull/235)
(`native-secp256k1-musig2`, dae4b74), and what building it would take.

## Status

Built on this branch, in the plan's order, with the two shortcuts the owner
chose for the first build (pysatochip for the card setup, a Mac for the
checker):

| Step | Where | Evidence |
| --- | --- | --- |
| 1 Card-side signing math | `MuSig.partialSignParameters`, `Satochip.signingContext`, `twoFactorApproval` | BIP327 vectors; the card's formula rebuilds every valid partial signature; approval checked against Python |
| 2 Satochip client | [Sources/WalletCore/Satochip](../Sources/WalletCore/Satochip/README.md) | NIST AES-CBC, channel keys checked against Python, full sessions against `SatochipEmulator` (TestSupport's model of the applet) |
| 4 Card as a MuSig2 signer | `MuSig2Account` card requests and verified attaches; `SatochipRegistration` on the record | A phone-and-card spend to valid key-path witnesses; refusals for a bad partial and 17 inputs |
| 5 Checker | `Satochip.Checker`, [`winnow-checker`](../Tools/Checker/README.md) and its setup runbook | Approvals for one payment do not sign another; the CLI prints approvals only after APPROVE |
| 6 App | `AppModel+Satochip`, `SatochipReader` (Core NFC), the Add and PSBT screens, the NFC entitlement | App build without first-party warnings; store tests |
| 7 UI journey | `test02SatochipCosigner` | Passed on the local signet: the node mined the phone-and-card spend |

Not yet done: step 3, the real applet in a simulator, which needs a Java
runtime and jCardSim downloaded; the physical card on an iPhone (step 8,
waiting on hardware); Seedkeeper support inside Winnow (pysatochip covers
setup for now); a checker app on a second iPhone. Every test above uses the
Swift model of the applet, not the applet itself.

The sources were read, not built or run:

| Source | Revision |
| --- | --- |
| [SatochipApplet](https://github.com/Toporin/SatochipApplet) | tag `v0.16-0.1`, 048d789 (prerelease; protocol 0.16, applet 0.1) |
| [pysatochip](https://github.com/Toporin/pysatochip) | tag `v0.18.5`, 49d1100 (`v0.18.6` changes packaging only) |
| Winnow's Satochip prototype | [3200521](https://github.com/winnowwallet/winnow/blob/3200521453173c0e9131c3331ec0c5ac3315ee82/Tools/Satochip/README.md) on `hardware/satochip-recovery` (PR #224, closed) |
| [JCardEngine](https://github.com/martinpaljak/JCardEngine), the applet's test simulator | 627dab3 (HEAD on 2026-10-20) |
| [SatochipSwift](https://github.com/Toporin/SatochipSwift) | 63404ed; reference only: it pulls in six third-party packages and predates v0.16 |

Line references point at those revisions. The Seedkeeper applet itself was not
read; what this note says about Seedkeeper comes from pysatochip's client code
and from the Satochip side of the import.

## Answer

**Yes, with conditions.** Applet v0.16-0.1 can complete a 2-of-2 MuSig2 key-path
spend with the phone as coordinator.

- The card implements only the two BIP327 algorithms that touch its secret key:
  NonceGen (`0x7E`) and Sign (`0x7F`) ([changelog][ch-150]). KeyAgg, the BIP328
  and TapTweak tweaks, NonceAgg, the session values, PartialSigVerify and
  PartialSigAgg stay on the host. They use only public data, and PR #235 already
  has all of them. The card's partial signature goes through `MuSig.partialVerify`
  and `PSBT.aggregateMuSig2` exactly as Bitcoin Core's does in the signet
  journey.
- The card can be **one of two signers** (`musig(phone, card)`), or the phone can
  be **coordinator only**, with the card as one participant and Core or a second
  card as the other. The app currently insists that one participant is the
  phone's own key (`AppModel.muSig2Account(validating:)`,
  [AppModel.swift:2138](../Sources/WinnowApp/AppModel.swift)). That check would
  have to accept an enrolled card.
- **The card signs blind.** It receives the nonce coefficient `b` and the product
  `e·a` already computed, and never sees the message
  ([changelog][ch-0150-blind]). With the stock flow, a hacked iPhone plus one tap
  and the PIN gets a partial signature over any transaction. That fails the
  requirement below. The applet has the fix: with 2FA enabled, Sign refuses to
  run without an HMAC over exactly those inputs, made with a key the card holds
  ([Satochip.java:3048-3072][a-sign-2fa]). A second "checker" device holds that
  key, recomputes every signing context from the PSBT, shows the payment and
  approves it.
- **Seedkeeper creates the card's seed**, and the 2FA secret too, on its own
  chip, then hands them to the Satochip encrypted. No phone ever holds the card's
  seed in readable form. Seedkeeper has no screen, so it covers setup and backup,
  not spend checks.
- **Not shown yet:** there is no physical card, no Core NFC session and no
  simulator run behind this note. v0.16-0.1 is a prerelease, and retail cards do
  not carry it.

## Requirement: a thief has to compromise both the iPhone and the card side

| Device | Holds | Does |
| --- | --- | --- |
| iPhone, Winnow | participant key A | Coordinator: builds the PSBT, aggregates nonces and signatures, hosts the card over NFC for both rounds, broadcasts |
| Satochip | participant key B, as a BIP32 seed | NonceGen and Sign only; with 2FA, signs only with the checker's approval |
| Checker device | the 2FA secret and the registered descriptor | Sets up the cards once; for every spend, recomputes each signing context from the PSBT, shows outputs and fee, returns an approval |
| Seedkeeper | the card's seed and the 2FA secret | Generates both on its chip, exports them encrypted to the Satochip, stays as their backup |

What an attacker gets from each compromise:

- **iPhone alone:** key A, and the card PIN at the next tap. The card still
  refuses to sign without an approval.
- **Satochip alone, PIN included:** key B can sign only with an approval, and
  key A is still missing.
- **Checker alone:** approvals, but no key.
- **iPhone + checker + the card in hand:** theft. The iPhone saw the PIN. This is
  the intended bar: the iPhone plus the card side.
- **iPhone + Seedkeeper, with its PIN:** theft. The Seedkeeper belongs to the
  card side and needs the same care.

Why 2FA rather than "only ever tap the card on the checker": the card cannot
tell which host is talking to it. With 2FA, the card enforces the checker's
approval on whichever phone it is tapped against.

What 2FA does not cover: factory reset (`0xFD`) needs neither the PIN nor 2FA
([changelog][ch-breaking]). Anyone holding the card, or a hacked phone it is
tapped on, can wipe it. That costs availability, not funds, but only if the
Seedkeeper backup exists. The account is 2-of-2 with no timelock fallback
(thresholds are deferred).

## One signing session on the wire (v0.16-0.1)

### Selection

- Satochip's applet ID is `5361746F4368697000` ([build.gradle:24][a-gradle]).
  SELECT returns the GET_STATUS bytes ([changelog][ch-select]). The command class
  is `0xB0` ([Satochip.java:135][a-cla]). Only short APDUs are used: Lc is read as
  one byte ([785-787][a-process]).
- GET_STATUS ([1832-1886][a-status]) returns versions (expect `00 10 00 01`), PIN
  and PUK tries, the 2FA flag (offset 8), seeded (9), setup done (10), and the
  MuSig2 policy (16, `0` = enabled). Winnow should refuse any other protocol
  version.
- Only GET_STATUS and INIT_SECURE_CHANNEL travel in clear. Every other command
  goes inside PROCESS_SECURE_CHANNEL (`0x82`), or the card answers `0x9C20`
  ([790-816][a-process]).

### Secure channel ([SecureChannel.java][a-sc])

1. The phone makes a fresh secp256k1 key `c` and sends `0x81` with the 65-byte
   uncompressed `c·G`. The card checks the point is on the curve
   ([149-151][a-sc-init]).
2. The card makes a fresh key `e`. It computes the shared secret `s = x(e·cG)`,
   then `mac_key = HMAC-SHA1(s, "sc_mac")` and
   `session_key = HMAC-SHA1(s, "sc_key")[0..16)` ([164-171][a-sc-init]; pysatochip
   [SecureChannel.py:41-58][p-sc]). It returns
   `[0x0020 | x(eG) | len | ECDSA_e | len | ECDSA_authentikey | 0x0020 | x(authentikey)]`
   ([139, 178-209][a-sc-init]).
3. The phone computes `s = x(c · lift_x(x(eG)))`. Both y values give the same x,
   so the two ECDSA signatures are not needed to finish the exchange. They
   authenticate the card (see Gaps).
4. Each command is sent as
   `[IV(16) | len(2) | AES-128-CBC(session_key, IV, PKCS#7(apdu)) | 0x0014 | HMAC-SHA1(mac_key, IV|len|ciphertext)]`.
   The IV is 12 random bytes and a 4-byte counter, which must be odd and
   increasing ([260-278][a-sc-unwrap]). pysatochip starts the counter at 1 and
   steps by 2 ([SecureChannel.py:61-83][p-sc]).
5. Each response is `[IV | len | ciphertext]`, with **no MAC**
   ([316-339][a-sc-wrap]; [SecureChannel.py:85-107][p-sc]). A response can carry
   at most 223 bytes of plaintext ([56-61][a-sc]).

INIT_SECURE_CHANNEL logs the PIN out and closes the previous channel
([Satochip.java:797-806][a-process]), and so does SELECT ([727-745][a-select]).

### PIN

VERIFY_PIN is `0x42`, with P1 = P2 = `00` and the PIN (4 to 16 bytes) as data.
A wrong PIN returns `0x63Cx`, where x is the tries left ([1689-1708][a-pin]). The
PIN stays verified until deselect, card reset or a new INIT_SECURE_CHANNEL.

### Participant key

`0x6D` takes P1 = depth (at most 10) and the indices as 4-byte big-endian values
([2272-2386][a-bip32]). It returns
`[chaincode(32) | 0x0020 | x(P) | len | ECDSA_P | len | ECDSA_authentikey]`.

The derived key becomes the "0xFF" signing key. It lives in RAM until deselect
or card reset ([680-691][a-transient]; [changelog][ch-transient]). So every tap
that signs must derive again, and must derive the participant path *last*.
pysatochip's `card_bip32_get_xpub` derives the child and then the parent
([CardConnector.py:1313-1352][p-xpub]), which leaves the parent as the 0xFF key.

The card returns only x. Its y parity can be had without ECDSA:

- TaprootTweakPrivateKey `0x7C` with P2 = `01` (bypass) on 0xFF returns the
  untweaked key as `[0x0041 | 04 x y | sig]` ([2508-2613][a-tweak]). This needs
  the Nostr policy, which is enabled by default ([2584-2590][a-tweak]).
- Alternatively, a throwaway NonceGen and Sign with chosen `b` and `e·a`; then
  check BIP327's verification equation against both parities. This also proves
  the card can sign for the key, at the cost of one nonce id.

### Round 1: NonceGen (`0x7E`) ([2767-2986][a-nonce])

- **OP_INIT** (P1 = `FF`, P2 = `01`): data is
  `[0x20 | aggpk(32) | 0x20 | msg(32) | len | extra(≤32)]`; a msg length of `FF`
  means no message. Winnow passes the values it uses for its own nonce
  ([MuSig2Account.swift:445](../Sources/WalletCore/Wallet/MuSig2Account.swift)):
  `aggpk` is the input's x-only output key, `msg` its BIP341 key-path sighash.
- The card computes `rand = sk XOR H_aux(rand')`, then `k1` and `k2` from
  `H_nonce(rand | pk | aggpk | msg | extra | i)`, as BIP327 specifies. It returns
  `[R1(33) | R2(33) | id(2)]`, 68 bytes. Only the first 66 bytes are the BIP327
  pubnonce for `PSBT_IN_MUSIG2_PUB_NONCE`.
- The id goes into a persistent table of 16 valid ids at this point
  ([2957-2966][a-nonce-id]; [440][a-bip327-fields]).
- **OP_FINALIZE** (P2 = `03`, no data) returns 144 bytes:
  `AES-128-CBC(k1 | k2 | pk | id | pad) | IV | CBC-MAC`. Both AES keys are
  generated on the card and never leave it ([652-659][a-bip327-keys]). The phone
  keeps this blob as an opaque token.
- OP_INIT and OP_FINALIZE must run back to back in one card session. The blob
  waits in a buffer cleared on deselect ([571-579][a-recvbuffer]).

### Round 2: Sign (`0x7F`) ([2989-3166][a-sign])

- Derive 0xFF again, on the same path, **before** OP_INIT. The derivation uses
  the same buffer, so it must not come between the two steps. Skipping it costs
  the nonce: the card consumes the id before it looks up the key, then fails
  with `0x9C13` ([3093-3112][a-sign]).
- **OP_INIT** (P1 = `FF`, P2 = `01`) sends the 144-byte blob, which is only
  staged.
- **OP_FINALIZE** (P2 = `03`) sends
  `[b(32) | e·a mod n (32) | R_odd(1) | ggacc_is_one(1)]`. With 2FA it appends
  `[80 00 | HMAC-SHA1(2FA key, SHA-256(those 66 bytes) | 0xEE × 32)]`
  ([3000-3010][a-sign]; [487-501][a-2fa-codes]; [SatochipTest.java:1111-1135][t-2fa]).
  `R_odd` is `01` when the session nonce R has odd y. `ggacc_is_one` is `01` when
  g·gacc = 1 and `00` when it is −1. Any other value returns `0x9C0F`.
- The card checks, in order: the flags, the 2FA HMAC, the blob's MAC (`0x9C44`),
  then decrypts. The id must be valid and is consumed (`0x9C47` otherwise). A
  0xFF key must exist (`0x9C13`), and the blob's pk must equal it (`0x9C45`).
  Both of these fail after the id is already burned.
  Only then does it compute `psig = k1 + b·k2 + (e·a)·d`, negating where the
  flags say. It computes this twice with independent blinding and compares the
  two results ([3074-3162][a-sign]). It returns the 32-byte partial signature.

### Nonce lifetime and reuse

- The secret nonce never exists in clear outside the card, and the card stores
  only ids.
- Each id yields at most one partial signature: it is consumed before signing
  ([3093-3105][a-sign]), and a replay returns `0x9C47`.
- At most 16 ids are outstanding. The 17th NonceGen evicts the oldest
  ([changelog][ch-0151]). A spend can therefore have at most 16 card inputs per
  round trip; Winnow should cap card spends at 16 inputs.
- After 65,535 nonces the counter wraps. The card rotates both AES keys, which
  invalidates every outstanding blob, and returns `0x9C46` ([2946-2955][a-nonce-id]).
  v0.16 fixed the crash the prototype found at counter 32,768
  ([changelog][ch-bugfix]). Seed reset and factory reset rotate the keys too
  ([1447-1493][a-reset]).
- A failed 2FA check or bad flags leaves the id intact, so the step can be
  retried. A pubkey mismatch burns the id
  ([SatochipTest.java:1182-1225][t-nonce]).

### Interruptions (NFC field lost)

| Lost after | Card state | Phone's response |
| --- | --- | --- |
| NonceGen OP_INIT, before OP_FINALIZE | id registered, blob gone | Discard that pubnonce and generate again |
| Sign OP_INIT | id intact, blob gone from the card | New tap: select, open the channel, verify the PIN, derive, resend the blob |
| Sign OP_FINALIZE sent, no reply | id possibly consumed, partial signature lost | Treat the nonce as spent; restart round 1 for that input, with fresh nonces from every signer |

pysatochip silently reopens the channel and resends after `0x9C20`–`0x9C23`
([CardConnector.py:300-349][p-transmit]), and notes that this recovery does not
cover MuSig2 ([CHANGELOG.md:85-87][p-ch]). Winnow must never resend inside an
OP_INIT/OP_FINALIZE pair. INIT_SECURE_CHANNEL overwrites the start of the buffer
holding the staged blob ([SecureChannel.java:161-173][a-sc-init]). It must
restart the pair from OP_INIT.

The phone's own secret nonce stays in memory only, as in PR #235. The card signs
first; its partial signature is verified, and only then does the phone sign.
That way, an aborted card round never leaves a phone partial signature behind.

### What v0.16 changed for clients ([changelog][ch-breaking])

- With 2FA enabled, Sign OP_FINALIZE requires the HMAC over all 66 context
  bytes, and the flags must be `00` or `01`. Earlier versions skipped 2FA here, so
  older firmware cannot meet the requirement above.
- Derived keys are transient: derive in the same session as signing, or the card
  returns `0x9C13`.
- INIT_SECURE_CHANNEL logs the PIN out.
- There is a single PIN: P1 must be `00`.
- UnblockPIN takes `[PUK_len | PUK | PIN_len | PIN]`.
- Factory reset is a single APDU (`0xFD`, P1 = `AA`, P2 = `55`) with no PIN.
- SignTransaction, ParseTransaction and signMessage are removed.
- SELECT returns the status bytes.
- The authentikey can be read with `0xAD` without a PIN.
- Seed reset clears the MuSig2 state.
- GET_RANDOM (`0x30`) is new.

No released client sends the MuSig2 2FA field yet. pysatochip's
`card_musig2_sign_hash` sends only the 66 context bytes and does not check
status words ([CardConnector.py:1818-1878][p-musig]). The applet's own test is
the only user of the field.

## Mapping onto PR #235

| BIP327 step | Runs on | Code |
| --- | --- | --- |
| KeySort, KeyAgg, BIP328 path tweaks, TapTweak | iPhone, checker | `MuSig2Account.muSig2Context` ([:385](../Sources/WalletCore/Wallet/MuSig2Account.swift)) |
| NonceGen for key A | iPhone | `MuSig.nonceGenerate` via `attachNonces` ([:445](../Sources/WalletCore/Wallet/MuSig2Account.swift)) |
| NonceGen for key B | card, `0x7E` | new |
| NonceAgg; session values b, R, e, a, g·gacc | iPhone, checker | `PSBT.muSig2Session` ([PSBTRoles.swift:205](../Sources/WalletCore/PSBT/PSBTRoles.swift)); `MuSig.Session.values`, `coefficient(of:)` ([MuSig2.swift:206-240](../Sources/WalletCore/Descriptors/MuSig2.swift)) |
| Sign inputs for key B: b, e·a, flags | iPhone, checker | new; `partialSignParameters` from [3200521][proto-musig] |
| 2FA approval | checker | new: HMAC-SHA1 over SHA-256 of the 66 bytes |
| Sign for key B | card, `0x7F` | new |
| PartialSigVerify of the card's partial signature | iPhone | `MuSig.partialVerify` ([MuSig2.swift:274](../Sources/WalletCore/Descriptors/MuSig2.swift)) |
| Sign for key A | iPhone | `PSBT.signMuSig2` ([PSBTRoles.swift:231](../Sources/WalletCore/PSBT/PSBTRoles.swift)) |
| PartialSigAgg, BIP340 verify, finalize | iPhone | `PSBT.aggregateMuSig2` ([:251](../Sources/WalletCore/PSBT/PSBTRoles.swift)), `MuSig2Account.finalizeSpend` |

What changes:

- **MuSig2.swift:** bring back `partialSignParameters(publicKey:session:)` from
  the prototype ([diff][proto-musig]). It is the public half of Sign: `b`, `e·a`,
  whether to negate the nonces, and whether to negate the secret key. The card
  flags follow directly: `R_odd = negateNonces` and
  `ggacc_is_one = !negateSecretKey`.
- **PSBTRoles.swift:** add an `attachMuSig2PartialSignature` that verifies the
  partial signature against the signer's pubnonce and key before storing it.
  Today only `signMuSig2` writes `musig2PartialSigs`
  ([:245](../Sources/WalletCore/PSBT/PSBTRoles.swift)).
- **MuSig2Account:** add a second kind of signer. `attachNonces` and `sign` take
  an `HDKey`. Add a per-input request for round 1 (`aggpk`, `msg`) and for round 2
  (the 66 context bytes), plus methods that attach the card's pubnonces and
  verified partial signatures. `reviewSpend` stays as it is and runs before both
  taps.
- **AppModel:** `muSig2Account(validating:)` accepts a participant that is an
  enrolled card. A spend in progress keeps the card's 144-byte blobs by input in
  memory. Persisting them would be safe, since the card enforces single use, but
  nothing needs it.
- **MuSig2Store (`musig2.json`):** per account, record the card's key
  expression, its authentikey x coordinate (to recognise the card) and a label.
- **PSBT screen** (`MuSig2PSBTView`): when the account has a card participant,
  "Add nonce" and "Add partial signature"
  ([MuSig2Views.swift:479-483](../Sources/WinnowApp/MuSig2Views.swift)) become
  "Tap card" steps with a PIN sheet. Between the rounds come "Show to checker"
  (a QR code) and "Scan approval".
- **Descriptor:** the card's participant is an extended public key with origin,
  shaped like the phone's own (`muSig2KeyExpression`, BIP86 account 0 unless the
  card also serves as a single-key wallet elsewhere). It takes three derivations,
  each with its parity:
  - `m`, for the master fingerprint;
  - the parent, for the parent fingerprint;
  - the account, for the chain code and key.

  The resulting `tr(musig(phone, card)/<0;1>/*)` passes `requireAccountKey` and
  `requireDistinctSigners` unchanged
  ([MuSig2Account.swift:147-180](../Sources/WalletCore/Wallet/MuSig2Account.swift)).
  The checker derives the card's key itself at setup and must find it in the
  descriptor before it approves anything.

### What the checker computes per input

From the PSBT alone, plus the descriptor it registered:

1. The input's coordinates. A hint is fine as long as it is checked by deriving
   the script again from the descriptor.
2. The BIP341 sighash. It commits to every input's amount and script, so the
   `witness_utxo` values the checker hashes are the ones the signature binds,
   and the fee it shows is real.
3. The outputs, each labelled as an account address or external.
4. The session from the PSBT's pubnonces, then `partialSignParameters` for the
   card's key.
5. `HMAC-SHA1(key, SHA-256(b | e·a | R_odd | ggacc_is_one) | 0xEE × 32)`.

It returns `[input | 80 00 | hmac]` for each input, small enough for one QR
code.

One point needs review before shipping. The approval does not name a nonce id,
so a hacked iPhone could pair one approval with any open card nonce. Each such
use still yields a partial signature only over the approved message. That
matches BIP327's model, where an untrusted aggregator chooses the aggregate nonce
and signers compute `b` from it. But it is an argument, not a proof, and should
go to upstream and to a reviewer.

## Seedkeeper setup

A Satochip cannot create a seed. It only imports one, in clear (`0x6C`) or
encrypted (`0xAC`). Some device has to create it, and Seedkeeper keeps it off
every phone. The steps, from pysatochip:

1. The Seedkeeper generates a master seed on its chip (`0xA0`,
   [CardConnector.py:2559-2582][p-sk-gen]) and a 2FA secret (`0xAE`,
   [2587-2607][p-sk-gen]).
2. The two cards are paired. The Satochip's authentikey goes into the
   Seedkeeper as a public-key secret (`seedkeeper_import_secret`,
   [2728][p-sk-import]). The Seedkeeper's authentikey goes into the Satochip with
   `0xAA`, which only works on an unseeded card ([Satochip.java:3358-3364][a-trusted]).
3. The Seedkeeper exports each secret encrypted to the Satochip (`0xA8`,
   [2957-3022][p-sk-export]), with a key from ECDH between the two authentikeys.
4. The Satochip imports each with `0xAC`. It accepts exactly two types: a master
   seed (`0x10`), which seeds the card, and a 2FA secret (`0xB0`), which turns on
   2FA ([3428-3466][a-import]).
5. The checker reads the 2FA secret from the Seedkeeper, if its export rights
   allow that. Otherwise the checker generates the secret itself and loads it
   into both cards (`set2FAKey` `0x79` sends it inside the channel,
   [3173-3210][a-2fa-set]).

The phone or computer relaying between the cards sees only ciphertext, but it
chooses which public keys get paired. A hacked host could pair each card with
its own key and plant a seed it knows. So setup runs on the checker, never on
the everyday iPhone. Afterwards, the checker compares the Satochip's participant
key with the same path derived from the Seedkeeper's secret (pysatochip derives
from a Seedkeeper secret by `sid`, [CardConnector.py:1234][p-xpub]).

Open question: pysatochip knows BIP39 mnemonic secret types (`0x30`, `0x31`),
but the Satochip imports only the raw master seed type. Whether one Seedkeeper
secret can serve both as words on paper and as the Satochip's seed has to be
checked in the Seedkeeper applet. If it cannot, the backup is the Seedkeeper
itself, and a second Seedkeeper is the spare.

Recovery:

| Lost | Response |
| --- | --- |
| Satochip | Pair a new card with the Seedkeeper and import the seed and the 2FA secret |
| Checker | A new checker reads the 2FA secret from the Seedkeeper |
| Seedkeeper | No copy of the seed is left, unless a second Seedkeeper or words exist: move the funds |
| iPhone | Winnow's own wallet recovery |

## Gaps, checked against this tree

| Need | For | Today | Plan |
| --- | --- | --- | --- |
| x-only ECDH with an ephemeral secret | Secure channel | `PublicKey.multiplied(by:)` is public ([Secp256k1Arithmetic.swift:59](../Sources/NativeSecp256k1/Secp256k1Arithmetic.swift)) and variable-time | Use it, and record the decision. The [research page](https://winnowwallet.com/research) notes that secret-times-public-point ECDH would widen the module and is to be evaluated explicitly; this is a single-use key, like a nonce |
| Uncompressed point (`04 x y`) | `0x81` payload | Missing: the point keeps x and y internally ([Point.swift:5-15](../Sources/NativeSecp256k1/Point.swift)); the public API only has `compressed` | Add `PublicKey.uncompressed` |
| lift_x | The card's x coordinates | `XOnlyKey(_:)` | None |
| HMAC-SHA1 | Channel key derivation and MAC; 2FA approval | CryptoKit `HMAC<Insecure.SHA1>`; CryptoKit is already imported | None |
| AES-128-CBC with PKCS#7 | Secure channel | CryptoKit has no CBC; CommonCrypto `CCCrypt` is already used by [PBKDF2.swift](../Sources/WalletCore/Crypto/PBKDF2.swift) | Small wrapper |
| ECDSA verify or recovery | The card's self-signatures and authentikey signatures | None: no ECDSA, and no scalar inverse mod n | **Not needed.** Parity comes from `0x7C` bypass or a test signature; the channel completes without it. It becomes optional later, to check Satochip's factory certificates (secp256k1 device certificates, see pysatochip `card_verify_authenticity`) |
| `partialSignParameters` | Card Sign; checker | Not in PR #235 | Port from 3200521 |
| Verified external partial signature in the PSBT | PSBT | Missing | Add |
| Core NFC | Transport | No `CoreNFC` import in the tree | `NFCTagReaderSession(pollingOption: .iso14443)`, `NFCISO7816Tag.sendCommand` |
| Entitlement `com.apple.developer.nfc.readersession.formats = [TAG]`; App ID capability "NFC Tag Reading" | Core NFC | [project.yml](../project.yml) entitlements list iCloud only | Add. `scripts/verify-signed-archive` and `scripts/tests/test_signed_distribution.py` pin the entitlements |
| `NFCReaderUsageDescription`; `com.apple.developer.nfc.readersession.iso7816.select-identifiers` = `5361746F4368697000`, plus Seedkeeper's (`SeedKeeper` in ASCII per [CardConnector.py:222][p-aid]; confirm the instance ID) | Core NFC | Missing | Add to `project.yml` info |
| Camera QR scanning | Checker exchange | `QRCodeView` displays only; no scanner in `Sources` | Add. A PSBT after round 1 may need a multi-frame QR; an approval fits in one |
| Offline spend review | Checker | `reviewSpend` needs `knownUTXOs` ([:221](../Sources/WalletCore/Wallet/MuSig2Account.swift)) | A PSBT-only variant (see the checker section above) |
| Seedkeeper client | Setup | None | A separate applet: read Seedkeeper-Applet `v0.2-0.1` first |

iOS limits: Core NFC runs only in the foreground, a reader session ends after
60 seconds, it needs an iPhone 7 or later, and the iOS Simulator has no NFC. The
card also carries an NDEF applet (`D2760000850101`), so tapping it outside
Winnow shows a satochip.io link ([changelog][ch-ndef]).

## Testing

### Simulator

- The applet's suite runs on JCardEngine without hardware
  ([build.gradle:72][a-gradle]; [changelog][ch-tests]). NonceGen and the id rules
  are tested on the stock simulator ([SatochipTest.java:1182-1225][t-nonce]). Sign
  is not. Its blinded arithmetic squares numbers on the card's RSA engine, which
  the applet probes with a start-up self-test ([Biginteger.java:84-117][a-bigint]).
  Where that engine fails, as on the stock simulator, the suite skips
  `musig2PartialSignatureTest` (`@FeaturePolicies({"musig2", "rsaMult"})`,
  [SatochipTest.java:1228-1259][t-psig]).
- The applet's README says a one-line JCardEngine patch is needed and points to
  `jcardengine-pr.md`, which is not in the `v0.16-0.1` tree
  ([README.md:248-251][a-readme]). JCardEngine already reads RSA key bytes by
  their length ([ByteContainer.java:86-91][je-bc]); that was the jCardSim bug the
  prototype patched. It also builds BouncyCastle `RSAKeyParameters`
  ([RSAKeyImpl.java:78][je-rsa]). My unconfirmed guess at the remaining failure
  is BouncyCastle refusing the even exponent 2. A harness must carry the patch,
  and must refuse to run until a known product checks out (the prototype's 2 × 3
  self-check).
- A Swift package test cannot load Java. It can drive a JVM bridge as a
  subprocess that speaks hex lines, as `SimulatorBridge.java` did. The app in the
  iOS Simulator reaches the same bridge over 127.0.0.1, the way it reaches the
  signet node, through a loopback APDU transport compiled only into e2e builds.
  That allows a signet UI journey with the phone, a simulated Satochip and the
  checker logic, with Core mining the result.
- For fast WalletCore tests, an in-process fake card: Swift that mimics the
  card's NonceGen, Sign, blob and id rules on NativeSecp256k1. It is
  cross-checked against the JVM run so the two cannot drift.

### What the prototype at 3200521 offers

| Reuse as is | Update | Drop |
| --- | --- | --- |
| The bridge pattern with RESET and COUNTER fault injection ([SimulatorBridge.java][proto-bridge]); pinned revisions and jar hashes; the disposable regtest `testmempoolaccept` check; `probe-card.py` (SELECT and GET STATUS only); the hardware list | The class is now `Satochip`, not `CardEdge`; the RSA fix now targets JCardEngine; `partialSignParameters` and its BIP327-vector test move onto the native arithmetic | `counter-index.patch` (fixed upstream, [Satochip.java:2960-2964][a-nonce-id]); the VaultKit fixture (vaults are gone); the P256K dependency (removed) |

### Only a physical card on a real iPhone can show

- That the card really runs protocol 0.16, applet 0.1 (GET_STATUS bytes 0-3).
- That its RSA engine passes the applet's `3² = 9` self-test, so Sign works at
  all.
- How Core NFC behaves with a card held for the whole exchange: 4 + 2n APDUs
  per round for n inputs, 10 RSA multiplications per partial signature
  ([changelog][ch-hardening]), within the 60-second session.
- What happens when the card is pulled at each step (tearing); what transient
  memory survives; PIN counters on real hardware.
- Antenna placement, and the NDEF pop-up.
- The research page's bar: receive, approve, sign, restore, refuse, disconnect,
  retry and replace, on signet, with transaction IDs.

## Plan, with evidence for each step

| # | Step | Evidence |
| --- | --- | --- |
| 0 | **Order hardware now** (lead time): two NXP JCOP4 J3R180 cards with NFC (first on the applet's tested list, [README.md:57-60][a-readme-cards]) to install v0.16-0.1 with GlobalPlatformPro, a Seedkeeper, a USB reader, and a second iPhone for the checker. Retail Satochips come with the applet installed and locked, and v0.16-0.1 is a prerelease | `probe-card.py` reports protocol 0.16, applet 0.1, MuSig2 enabled |
| 1 | **Card-side signing math in WalletCore:** port `partialSignParameters`; encode the 66 context bytes; compute the 2FA HMAC | BIP327 `sign_verify` vector 0 pins `b` and `e·a` (the prototype's test). `partialSign` rebuilt from the parameters matches the vectors. The HMAC matches a value computed independently from the applet test's format (`KEY_2FA`, `0xEE`) |
| 2 | **Satochip client in WalletCore**, transport-agnostic: secure channel, APDU builders and parsers, status words, an `APDUTransport` protocol; add `PublicKey.uncompressed` to NativeSecp256k1 | Channel vectors from pysatochip's `SecureChannel` run offline with fixed keys and IVs (no card); a fuzz target over the response parsers |
| 3 | **Simulator harness** (`Tools/Satochip` updated for v0.16-0.1): JCardEngine as the applet pins it, the RSA patch with a self-check, the bridge; an opt-in Swift test drives step 2 against it | The test enrols a key, runs both rounds with and without 2FA, and checks: the partial signature passes `MuSig.partialVerify`; a replay returns `0x9C47`; a wrong approval returns `0x9C0B` and keeps the id; the regtest node accepts the spend. A JSON report records every revision |
| 4 | **MuSig2Account card signer** (requests, verified attach, enrollment with parity and fingerprints, 16-input cap) with the in-process fake card | WalletCore tests: a 2-of-2 spend aggregates and verifies; a 17-input spend is refused; a wrong-parity or wrong-key enrollment is caught by the test signature |
| 5 | **Checker:** offline review, approval, setup flows. Recommended form: Winnow in a checker role on a second, offline iPhone, sharing WalletCore. A macOS tool with a USB reader is the fallback | Tests where a changed output, amount, fee or participant key yields a different approval, and the (fake or simulated) card refuses it |
| 6 | **App:** Core NFC transport, entitlement, `Info.plist` keys, PIN sheet, tap steps, QR in both directions; the loopback transport for e2e builds | Signet UI journey: phone, simulated Satochip, checker; Core mines the spend; `verify-signed-archive` passes with the NFC entitlement |
| 7 | **Seedkeeper setup** (read its applet first): pairing, seed and 2FA secret generation, export to the Satochip, the cross-check | A simulator journey with both applets; the Seedkeeper-derived key matches the Satochip's participant key |
| 8 | **Physical run** | The research page's list on signet: transaction IDs, screen recordings, APDU timings, and pull-the-card results at every step |

## Risks

- **Prerelease firmware.** v0.16-0.1 is marked prerelease and carries breaking
  client changes. The MuSig2 2FA field had no released client as of pysatochip
  v0.18.6. Formats may move before release. Pin the protocol version, and refuse
  anything else.
- **Card availability.** Applets on retail cards are sealed. Until Satochip ships
  v0.16, every card is a do-it-yourself install on a blank JavaCard. That suits
  development, not users.
- **Blind signing.** Without the checker, the card adds key separation but no
  approval. The approval does not bind a nonce id (see the checker section).
- **Nonces across NFC interruptions.** The rules are in the interruption table.
  The trap is an automatic resend inside an OP_INIT/OP_FINALIZE pair. There are
  16 outstanding ids at most.
- **Unauthenticated channel.** Responses carry no MAC, and Winnow would skip the
  ECDSA checks. A relay attacker within NFC range could read the PIN. A
  substituted card or tampered response is still caught, because every partial
  signature must verify against the enrolled key, and with 2FA a PIN alone
  signs nothing.
- **Wipe without PIN.** Factory reset needs no PIN, so the Seedkeeper backup is
  mandatory. 2-of-2 has no timelock fallback.
- **Setup host.** Pairing the Seedkeeper and loading the 2FA secret must happen
  on the checker; a hacked host there defeats the design.
- **Variable-time ECDH** on the phone, for a single-use key; this needs an
  explicit decision (see Gaps).
- **Simulator fidelity.** Sign needs a patched simulator. Green simulator runs
  say nothing about timing, tearing or transient memory.
- **Export compliance.** The app declares `ITSAppUsesNonExemptEncryption: NO`.
  Recheck that declaration with the secure channel added.

## Size

| Step | Approximate lines, with tests |
| --- | --- |
| 1 | 300 |
| 2 | 1,000 |
| 3 | 600, much of it from the prototype |
| 4 | 900 |
| 5 | 1,500, including QR scanning and multi-frame PSBTs |
| 6 | 1,000 |
| 7 | 1,000 |

About 6,000 lines, comparable to PR #235 (5,686 insertions). Steps 1-4 need no
hardware and no app changes. Steps 5-7 are app work. Step 8 depends on cards
running v0.16-0.1. This is several weeks of focused work before the physical
run, and Seedkeeper (step 7) is the least known part.

## First step

Step 1, now done (see Status): `MuSig.partialSignParameters` ported onto PR
#235's `MuSig2.swift`, with the encoder for the 66 context bytes and the 2FA
HMAC beside it. The next steps are the real applet in the simulator harness
(step 3), so the Swift client is checked against Satochip's own code and not
only against a model of it, and then the physical card.

[a-cla]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L135
[a-bip327-fields]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L434-L461
[a-2fa-codes]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L487-L501
[a-recvbuffer]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L571-L579
[a-bip327-keys]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L652-L662
[a-transient]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L680-L691
[a-select]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L727-L745
[a-process]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L751-L1003
[a-reset]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L1447-L1493
[a-pin]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L1677-L1708
[a-status]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L1832-L1886
[a-bip32]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L2272-L2386
[a-tweak]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L2508-L2613
[a-nonce]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L2767-L2986
[a-nonce-id]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L2946-L2966
[a-sign]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L2989-L3166
[a-sign-2fa]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L3048-L3072
[a-2fa-set]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L3173-L3210
[a-trusted]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L3345-L3395
[a-import]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Satochip.java#L3428-L3466
[a-sc]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/SecureChannel.java#L33-L61
[a-sc-init]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/SecureChannel.java#L132-L214
[a-sc-unwrap]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/SecureChannel.java#L216-L314
[a-sc-wrap]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/SecureChannel.java#L316-L339
[a-bigint]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/main/java/org/satochip/applet/Biginteger.java#L84-L117
[a-gradle]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/build.gradle#L20-L75
[a-readme]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/README.md#L248-L251
[a-readme-cards]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/README.md#L57-L60
[ch-breaking]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/CHANGELOG.md#L17-L26
[ch-select]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/CHANGELOG.md#L114
[ch-ndef]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/CHANGELOG.md#L110
[ch-transient]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/CHANGELOG.md#L136-L139
[ch-hardening]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/CHANGELOG.md#L54-L59
[ch-bugfix]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/CHANGELOG.md#L85
[ch-tests]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/CHANGELOG.md#L181
[ch-0151]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/CHANGELOG.md#L187-L206
[ch-150]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/CHANGELOG.md#L208-L245
[ch-0150-blind]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/CHANGELOG.md#L241-L243
[t-2fa]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/test/java/org/satochip/applet/SatochipTest.java#L1111-L1135
[t-nonce]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/test/java/org/satochip/applet/SatochipTest.java#L1182-L1225
[t-psig]: https://github.com/Toporin/SatochipApplet/blob/v0.16-0.1/src/test/java/org/satochip/applet/SatochipTest.java#L1228-L1259
[p-aid]: https://github.com/Toporin/pysatochip/blob/v0.18.5/pysatochip/CardConnector.py#L221-L222
[p-transmit]: https://github.com/Toporin/pysatochip/blob/v0.18.5/pysatochip/CardConnector.py#L300-L349
[p-xpub]: https://github.com/Toporin/pysatochip/blob/v0.18.5/pysatochip/CardConnector.py#L1234-L1352
[p-musig]: https://github.com/Toporin/pysatochip/blob/v0.18.5/pysatochip/CardConnector.py#L1761-L1878
[p-sk-gen]: https://github.com/Toporin/pysatochip/blob/v0.18.5/pysatochip/CardConnector.py#L2559-L2607
[p-sk-import]: https://github.com/Toporin/pysatochip/blob/v0.18.5/pysatochip/CardConnector.py#L2728
[p-sk-export]: https://github.com/Toporin/pysatochip/blob/v0.18.5/pysatochip/CardConnector.py#L2957-L3022
[p-sc]: https://github.com/Toporin/pysatochip/blob/v0.18.5/pysatochip/SecureChannel.py#L41-L107
[p-ch]: https://github.com/Toporin/pysatochip/blob/v0.18.5/CHANGELOG.md#L85-L87
[je-bc]: https://github.com/martinpaljak/JCardEngine/blob/627dab3623da39bdf231bd6ae292b71e9c3b2d58/simulator/src/main/java/com/licel/jcardsim/crypto/ByteContainer.java#L86-L91
[je-rsa]: https://github.com/martinpaljak/JCardEngine/blob/627dab3623da39bdf231bd6ae292b71e9c3b2d58/simulator/src/main/java/com/licel/jcardsim/crypto/RSAKeyImpl.java#L78
[proto-musig]: https://github.com/winnowwallet/winnow/blob/3200521453173c0e9131c3331ec0c5ac3315ee82/Sources/WalletCore/Descriptors/MuSig2.swift#L244-L265
[proto-bridge]: https://github.com/winnowwallet/winnow/blob/3200521453173c0e9131c3331ec0c5ac3315ee82/Tools/Satochip/SimulatorBridge.java
