# Swift Lightning

Winnow's Lightning is a native Swift engine built on Winnow's own
transactions, wallet, fee policy, verified chain scanner and broadcast path.
There is no Rust, LDK or other Lightning runtime in the app; P256K
(libsecp256k1) and CryptoKit supply the cryptography
([encryption inventory](../release/encryption-inventory.md)).

## Layout

- `Sources/LightningCore`: the engine.
  - Transport and channels: BOLT 8 transport, BOLT 1/2 channels, and BOLT 3
    transactions (static-remotekey and anchors, with CPFP).
  - Safety: the durable journal, chain monitoring and on-chain resolution.
  - Payments: Sphinx onions, BOLT 11 invoices, routing, BOLT 12 offers and
    invoices, async payments, LSPS1 liquidity, and BIP 353 names with local
    DNSSEC validation.
  - Recovery: background protection and the portable recovery file.
  - [README](../../Sources/LightningCore/README.md).
- WalletCore hooks it needs:
  - BIP143 sighashes;
  - the ordered filter-scan observer and header hook;
  - funding and recovery-spend reservations;
  - package relay (`broadcastPackage`, with a parent served once more per child
    for Core's one-parent-one-child relay);
  - public `Bech32.convertBits`.
- `Sources/WinnowLightningApp`: the Lightning controller, views and model
  logic (`AppModel+Lightning.swift`), compiled into the Winnow app with
  `Sources/WinnowApp`.

## In the app

- **Where it appears.** Lightning is on every network, in both modes:
  - Advanced has a Lightning tab.
  - Simple's Receive offers Lightning or Bitcoin.
  - Send offers "Pay Lightning invoice".
  - Onboarding can restore an encrypted Lightning recovery file.
- **Storage.** Each network has its own node, journal and keys under the
  wallet's storage and Keychain service.
- **Backups.** iCloud backup covers the Bitcoin wallet and never holds channel
  state. Channels move between devices only through the encrypted recovery
  file (Settings → Lightning recovery file). The file opens with the wallet's
  own recovery phrase, or with nothing typed when that wallet is already on
  the device (restored from iCloud, for instance). Files saved by 0.8.0 keep
  their separate 24-word phrase.
- **Guards.**
  - A wallet can be deleted unless one of its channels is not yet closed or is
    being recovered.
  - An existing wallet is never replaced.
  - A node that cannot open (for example a journal whose this-device-only key
    did not survive a device restore) leaves the Bitcoin wallet scanning alone.
    Its chain driver rolls the shared scan back to its own cursor once it
    opens, and a scan it did not watch never counts as a channel check.
- **Background checks** also watch the selected network's channels and relay
  their pre-signed recovery transactions.

## Tests

| What | Where |
|---|---|
| Engine units and BOLT/BIP vectors | `Tests/LightningCoreTests`, in every `swift test` |
| Channel, HTLC, penalty and anchor transactions against Bitcoin Core regtest | `scripts/ci-lightning`, tdx package lane |
| App model, hooks, guards and recovery | `AppTests/Lightning`, in `WinnowAppTests` (tdx units lane) |
| Independent peers: Core Lightning (force, cooperative with offers, anchors, stale-backup recovery) and LDK (offers, async both ways, provider crashes, recipient timeout) | `scripts/ci-lightning-peer`, `ci-lightning-offers`, `ci-lightning-async`, `ci-lightning-timeout` |
| Recorded journey: funding, sharing, offline payment, process crashes, returned funds | `scripts/ci-lightning-ui` with `scripts/lightning-ui-fixture`, target `WinnowAppLightningUITests` |

The reference peers are built from pinned sources by
`scripts/ci-lightning-references` (posix4e/lightning-reference). The
independent-peer steps and the recorded journey run in
`.github/workflows/ci-lightning.yml`, which `validation` requires; a tree that
already passed there is not run again. Core Lightning on macOS can hand a
subdaemon an unreadable socket (upstream #9564). The peer scripts retry only
that failure (a channel daemon exiting at once, or losing its HSM, with no
protocol error), with up to five fresh fixtures. The recorded journey, whose
Core Lightning carries the HSM fix, reruns once from a fresh fixture when a
channel daemon loses its peer socket while the app stays connected. Every
other failure is final.

CRAP (docs/crap.md) covers Lightning like every other source directory.

## Release

Lightning ships in Winnow's ordinary release: a `vX.Y.Z` tag runs
`.github/workflows/release.yml` ([Lightning release notes](lightning-release.md)).
The app's cryptography includes implementations outside Apple's OS, so export
compliance is the account holder's reviewed answer:
`WINNOW_NONEXEMPT_ENCRYPTION`, and `docs/release/encryption-questionnaire.json`.

Physical-device checks (Face ID approvals, the Share sheet, locked-device
protection) are listed in the What to Test notes as pending, not claimed.
