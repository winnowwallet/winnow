# Swift Lightning core

Winnow's Lightning engine, built on WalletCore's `Transaction`, `Script`,
serialization and hashes. Curve operations use the P256K 0.23.2 dependency
(C libsecp256k1); ChaCha20-Poly1305 and HKDF use Apple's CryptoKit. There is no
Rust, LDK, second wallet, scanner, or transaction representation in this target.

How the Winnow app uses it, how it is tested and how it is released are in
[Swift Lightning](../../docs/engineering/swift-lightning.md). Engine tests do
not by themselves establish a release.

## Implemented

- WalletCore BIP143 signature digests for all six standard sighash modes.
- BOLT 3 key/revocation derivation, commitment-secret generation and compact
  shachain validation. Failed insertions leave the in-memory chain unchanged.
- Static-remotekey and negotiated `option_anchors` funding, commitment and HTLC
  transactions, including dust trimming, fees, output sorting and obscured
  commitment numbers. Existing non-anchor channels retain their original format.
- Verified commitment and HTLC signature assembly, HTLC success/timeout,
  delayed withdrawals and revocation spends, all returning WalletCore transactions.
- BOLT 8 Noise XK authentication and encrypted frames, fragmentation, directional
  key rotation and permanent connection closure on authentication failure.
- BOLT 1/2 wire encoding, feature negotiation, private channel opening,
  commitment/HTLC signatures, revocations, direct payments, reestablishment and
  cooperative closing over an actor-owned TCP connection.
- An encrypted, exclusively locked durable journal containing channel keys,
  current monitors, updates, payment IDs/receipts and exact protocol outbox.
  Disk failures stop publication and further actions. Startup pauses until the
  verified chain adapter explicitly catches up. Proven stale state disables
  commitment publication. A typed channel backup restores into a separate,
  recovery-only journal that cannot pay or publish an old commitment.
- BOLT 4 Sphinx construction/peeling, final TLV payloads and payment-secret
  validation; BOLT12 offers/static invoices, blinded paths and the pinned LDK
  hold/release async flow, including durable request retries.
- Ordinary BOLT12 offers, signed invoice requests and one-payment invoices use
  the same TLV, Merkle, blinding, onion and durable HTLC primitives. Fetching an
  invoice does not pay it; exact request/issuer/network/amount/expiry binding and
  a separate route/fee review precede payment. Direct issuer requests and blinded
  introduction paths remain distinct from the async static-invoice flow.
- BIP353 names resolve to standard offers through locally validated DNSSEC,
  including delegation chains, signed aliases and wildcard denial proofs. The
  resolver's AD bit is ignored. Root trust anchors are pinned IANA DS records;
  signature and TTL expiry also bound the authorized name-payment review.
- Winnow-owned funding reservations and ordered verified-filter observers,
  selectively reused from the prior research work without its native bridge.
- Taproot recovery destinations, negotiated anysegwit cooperative close, and
  dust limits from Winnow's existing coin-selection policy.
- Shared foreground peer sessions, verified-chain recovery, HTLC timeout and
  preimage resolution, reorg reconciliation, and recovery publication after restart.
- Anchor CPFP and fee-funded HTLC second stages preserve the peer's
  `SIGHASH_SINGLE|ANYONECANPAY` signature. Exact signed transactions and wallet
  reservations persist before publication; replacement retains the authorized
  package fee cap and reserved inputs across restart.

`Commitment` retains its validated parameters: recovery/signing cannot silently
substitute its capacity, fee rate or channel keys. The low-level transaction
builder follows BOLT 3's funder-fee exhaustion rule. The channel engine applies
reserve, expiry, confirmation and channel-state policy before signing; the
low-level builder alone does not establish that a payment is safe.

Each handshake/transport has one owner (normally a connection actor). These
non-Sendable objects must not be shared concurrently. Complete handshake acts
are supplied by the caller; transport messages accept arbitrary fragmentation.
Preserve ciphertext and write order across short socket writes. Discard the
connection on failure; never persist or restore transport nonces. Clearing Data
references on closure is not a guarantee of memory zeroization.

## Evidence

```sh
swift test
swift test --filter LightningCoreTests
WINNOW_BITCOIN_DIR=/path/to/bitcoin/bin scripts/ci-lightning
WINNOW_CLN_DIR=/path/to/lightning WINNOW_BITCOIN_DIR=/path/to/bitcoin/bin \
  scripts/ci-lightning-peer --format anchors --close force
WINNOW_CLN_DIR=/path/to/lightning WINNOW_BITCOIN_DIR=/path/to/bitcoin/bin \
  scripts/ci-lightning-peer --format anchors --close recovery
WINNOW_CLN_DIR=/path/to/lightning WINNOW_BITCOIN_DIR=/path/to/bitcoin/bin \
  scripts/ci-lightning-peer --close cooperative --offers
```

The ordinary package suite includes the Lightning tests. Independent published
fixtures cover all 16 BOLT 3 Appendix C non-anchor commitment cases and their
second-stage transactions, key derivation, five secret-generation cases, nine
secret-storage cases, 15 BOLT 8 handshake cases, key rotation and nine BIP143
examples. Additional tests exercise substitution, malformed signatures, wrong
preimages, invalid sequencing, fragmentation and authentication failures.
See [vector provenance](../../Tests/LightningCoreTests/Vectors/README.md).

`ci-lightning` starts its own loopback-only regtest Core node with a fresh data
directory and public deterministic test keys. Core supplies test coins; the Swift
fixture constructs and signs all channel transactions. Core checks and mines
commitments, HTLC success/timeout, delayed withdrawals and three revocation
spends. It must reject early CLTV/CSV withdrawals and an altered commitment.
The anchor matrix also checks the one-block remote-output delay, rejects an
unfunded HTLC stage, and mines wallet-funded HTLC success/timeout stages with
the original peer signatures and matching input/output preserved.
Missing Core binaries fail the check. Both hosted and TDX CI run it alongside
ordinary Winnow checks; production warning checks include LightningCore.

The `ci-lightning` checks are transaction-consensus checks, not Lightning-peer interoperability.
The fixture has both parties' test keys and does not simulate the security of
independent counterparties. No payment, funding, peer or recovery state machine
is inferred from an accepted transaction or matching vector.

`ci-lightning-peer` separately starts unmodified Core Lightning v26.06.8 and
uses the production Swift module over BOLT 8 TCP. It checks stock-generated
onions, channel opening, direct payments in both directions, duplicate payment
requests, actual Swift process termination, persistent receipts, reestablishment
and close. Bitcoin Core verifies/mines the independent parties' final signed
transaction. `--close force` and `--close cooperative` use fresh fixtures.
`--format anchors --close force` verifies the stock peer's negotiated channel
type and Core acceptance of CPFP and replacement within the same fee cap. It
also runs the production WalletCore peer pool and broadcaster against an
isolated Core node with a 5 sat/vB relay floor: the commitment alone is rejected,
the parent and fee-paying child are accepted together over P2P, and a higher-fee
replacement child replaces the first. That node receives no RPC transaction
submission. Both signed transactions are saved before announcement, and their
input relationship survives periodic relay after a broadcaster restart.
`--close recovery` exports a backup before payments advance the commitment,
restores it in a fresh recovery-only journal after the stock peer closes, and
requires Core to accept and mine the recovered output claim. That check initiates
the peer close through the stock node's RPC; it does not establish that a
recovery reestablishment message alone triggers the peer to close.
Receipts record source identity (including whether it is dirty), peer commit,
amounts, hashes and balances.

`--offers` additionally exchanges ordinary offers, invoice requests, signed
invoices and settled blinded HTLCs with stock CLN in both directions. Direct and
blinded request paths each get a separate payment and independent stock-node
receipt. Unit tests cover request substitution, unsupported path features,
idempotent authorization and restored invoice requests, while published BIP353
proofs cover local DNSSEC validation and rejection of damaged or incomplete
proofs. See the [ordinary offer and name guide](../../docs/engineering/lightning-offers.md).

On macOS, the fixture permits one fresh attempt only when stock CLN's
`channeld` exits with status zero during opening, after accepting the commitment
but before sending `funding_signed`. This matches the startup failures discussed
in upstream [#5808](https://github.com/ElementsProject/lightning/issues/5808) and
[#9323](https://github.com/ElementsProject/lightning/issues/9323). No funding has
been broadcast at that point. Every attempt retains its logs, and the final
receipt lists any retry. Protocol rejections, other timeouts, payment/close
failures and a second startup crash fail the check; peer source and assertions
are unchanged.

`ci-lightning-async` separately checks the pinned LDK async protocol against
Swift in both directions, including reusable BOLT12 offers, static invoices,
blinded payment/onion paths, committed held HTLCs and recipient-triggered
release. Sender and recipient are separate processes killed and restarted in
non-overlapping order. `--restart-providers` also kills both LDK providers while
the clients are offline. Receipts check actual channel amounts, forwarding fees,
payment hashes/preimages and process ordering. Rust runs only in the independent
host reference; these tests do not establish app behavior or release readiness.

The Rust reference harness and its Cargo lockfiles are maintained separately in
[lightning-reference](https://github.com/posix4e/lightning-reference).
`scripts/ci-lightning-references` downloads its pinned commit into the disposable
reference build directory. The app has no dependency on that repository.

`ci-lightning-timeout` verifies automatic commitment, HTLC timeout and delayed
recovery after the recipient and both providers disappear. Core validates the
transactions and returned balance. `ci-lightning-ui` builds the Winnow app,
records actual process crashes and Apple Share/Copy, and checks the independent
provider receipts plus the app's restored payment history and wallet balance.
Its Debug authentication fixture is not physical-device authentication evidence.

## Scope and release checks

Lightning supports the wallet's mainnet, signet and regtest selections. Keep the
channel journal and a recent channel backup; seed recovery alone does not restore
current channel state. Background protection can scan and relay pre-signed
transactions, including an already authorized anchor child. New fee-funded HTLC
transactions and claims for a peer's augmented HTLC child require an unlocked
wallet; background execution and available fee coins are not guaranteed.
Device authentication, file protection and iPad/large text have separate
physical-device checks in the [release procedure](../../docs/engineering/lightning-release.md).

The newer `zero_fee_commitments` format, splicing and post-quantum protocol
extensions are not implemented or advertised. Single-part BOLT11 invoice payments use private hints and
bounded signed public routing policies; see the [sending guide](../../docs/engineering/lightning-sending.md).

## Instant receive (LSPS2)

`LightningJIT` holds the bLIP-52 client terms: the fee menu (each entry kept
verbatim for `lsps2.buy`), the opening-fee formula with overflow checks, and
the purchase's intercept scid. `LightningJITReceiving` turns a purchase into
an invoice, grants zero-conf only to the provider's open that matches a live
purchase, and accepts that payment minus the declared `extra_fee`. The grant is
separate from `fundingIsConfirmed`, which still means a verified confirmation.
`scripts/ci-lightning-jit` pays such an invoice through stock LDK's LSPS2
service.
