# Swift Lightning

Winnow Lightning is a native Swift Lightning wallet built on Winnow's own
transactions, funding wallet, fee policy, verified chain and filter scan and
broadcast path. There is no Rust, LDK or other Lightning runtime in the app;
P256K (libsecp256k1) and CryptoKit supply the cryptography.

It ships as its own TestFlight app, **Winnow Lightning** (`com.btcswift.lightning`).
The ordinary Winnow app (`com.btcswift.app`) does not link it.

## Layout

- `Sources/LightningCore` — the engine: BOLT 8 transport, BOLT 1/2 channels,
  BOLT 3 transactions (static-remotekey and anchors, with CPFP), the durable
  journal, chain monitoring and on-chain resolution, Sphinx onions, BOLT 11
  invoices, routing, BOLT 12 offers and invoices, async payments, LSPS1
  liquidity, BIP 353 names with local DNSSEC validation, background protection
  and the portable recovery file. [README](../../Sources/LightningCore/README.md).
- WalletCore hooks it needs: BIP143 sighashes, the ordered filter-scan observer
  and header hook, funding and recovery-spend reservations, package relay
  (`broadcastPackage`, with a parent served once more per child for Core's
  one-parent-one-child relay), and public `Bech32.convertBits`.
- `Sources/WinnowLightningApp` — the Lightning controller, views and model
  logic (`AppModel+Lightning.swift`). The app target `WinnowLightning` compiles
  `Sources/WinnowApp` plus this directory with `-D LIGHTNING`; shared files hold
  only small `#if LIGHTNING` hooks. It keeps the earlier research builds'
  storage and Keychain names, has no iCloud, and has its own test targets
  (`WinnowLightningTests`, `WinnowLightningUITests`) and scheme.

## Tests

| What | Where |
|---|---|
| Engine units and BOLT/BIP vectors | `Tests/LightningCoreTests`, in every `swift test` |
| Channel, HTLC, penalty and anchor transactions against Bitcoin Core regtest | `scripts/ci-lightning`, tdx package lane |
| App model and hooks | `AppTests/Lightning` (`WinnowLightningTests`) |
| Independent peers: Core Lightning (force, cooperative with offers, anchors, stale-backup recovery) and LDK (offers, async both ways, provider crashes, recipient timeout) | `scripts/ci-lightning-peer`, `ci-lightning-offers`, `ci-lightning-async`, `ci-lightning-timeout` |
| Recorded app journey: funding, sharing, offline payment, process crashes, returned funds | `scripts/ci-lightning-ui` with `scripts/lightning-ui-fixture` |

The reference peers are built from pinned sources by
`scripts/ci-lightning-references` (posix4e/lightning-reference). All of the
above run in `.github/workflows/ci-lightning.yml`, which `validation` requires;
a tree that already passed there is not run again.

CRAP (docs/crap.md) is partitioned: the tdx report gates every method except
`Sources/WinnowLightningApp`, which only the Lightning app compiles; the
Lightning job gates that directory from its app tests and recorded journey.

## Release

Push a `lightning-vX.Y.Z` tag. `.github/workflows/lightning-release.yml` runs CI,
archives `WinnowLightning`, verifies the signed identity, the absence of iCloud
and the encryption declaration, uploads to the existing TestFlight app, adds
the What to Test notes (`docs/lightning-what-to-test.txt`) and the internal
group. It never creates the app or opens public testing.

The app uses cryptography outside Apple's own (BOLT 8 Noise, Sphinx), so export
compliance is the account holder's declaration. Until the repository variable
`LIGHTNING_NONEXEMPT_ENCRYPTION` is set, builds carry no encryption key and App
Store Connect asks its questions for the build; after review set it to `YES`
(with `LIGHTNING_ENCRYPTION_COMPLIANCE_CODE`) or `NO`
(`scripts/lightning-encryption-declaration`).

Physical-device checks (Face ID approvals, Share sheet, locked-device
protection) are listed in the What to Test notes as pending, not claimed.
