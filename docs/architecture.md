# Wallet architecture

Winnow's app owns the user interaction and device integration. WalletCore
provides its Bitcoin rules, on top of NativeSecp256k1, Winnow's own Swift
secp256k1 module. Shared control is limited to two raw account kinds in
Advanced mode: k-of-n script-path multisig accounts, optionally with a Ledger
as one signer over Bluetooth, and n-of-n key-path MuSig2 accounts. The app and development
tools use the root [Package.swift](../Package.swift), which declares no
dependencies, so there is no lockfile.

## Source ownership

| Component | Owns | Depends on |
| --- | --- | --- |
| [WinnowApp](../Sources/WinnowApp/README.md) | SwiftUI screens, payment review, authentication, lifecycle, persistence, background scheduling and iCloud backup | WalletCore and Apple frameworks |
| WalletCore | Keys, descriptors, scripts, PSBTs, transactions, wallet state, MuSig2 accounts (BIP327 signing, BIP373 PSBT fields), people and contact cards, and Bitcoin P2P networking | NativeSecp256k1 |
| [NativeSecp256k1](../Sources/NativeSecp256k1/README.md) | Field, scalar and point arithmetic (public for MuSig2), BIP32 and Taproot tweaks, BIP340 signing and verification; variable-time, not zeroized | Foundation and CryptoKit |
| [TestSupport](../Tests/Support/README.md) | In-memory keys, controlled peers and disposable Bitcoin Core fixtures | WalletCore; development only |
| [winnow-debug](../Tools/Debug/README.md) | Offline inspection, diagnostics, generators and network soaks | WalletCore |
| [WinnowFuzz](../Tools/Fuzz/README.md) | Bounded hostile-input parsing and invariants | WalletCore and NativeSecp256k1 through WinnowFuzzCore |
| [winnow-fixture](../Tools/Fixture/README.md) | Test-bank preparation | TestSupport |
| [winnow-checker](../Tools/Checker/README.md) | The Satochip checker on a trusted Mac: shows each MuSig2 spend from the PSBT alone and approves what the card may sign | WalletCore |

There is no VaultKit. A MuSig2 account is a `MuSig2AccountRecord` in the
sealed per-wallet `musig2.json`, its scripts watched in the same filter scan as
the wallet's and its coins kept with spent tombstones for reorgs. Import
bundles carry these records under `vaults`, the key the shared-account Winnow
used, so its backups of MuSig2 accounts restore. A bundle carrying a threshold
or script-path account is refused rather than restored without those funds.

WalletCore is a SwiftPM library product. It shares the app's source revision
and version tags; there is no separate library release train. The package has
no third-party dependencies: the native module is checked against answers
recorded from libsecp256k1, and the signet miner has the node's own wallet sign
block challenges. `scripts/check-dependencies` keeps Xcode from resolving any
other package.

## Receiving and synchronization

[AppModel](../Sources/WinnowApp/AppModel.swift) coordinates wallet state and the
network actors. Peers supply headers, compact block filters and requested
blocks. The wallet matches filters locally, fetches candidate blocks and
updates its tracked coins and transaction history. Short mempool subscriptions
provide unconfirmed-payment detection while the relevant screens are open.

This is a compact-filter wallet. Its checks do not establish the same view as
independently validating every block from genesis. Peer choice, checkpoints,
filter agreement and catch-up limits are described in the bundled
[read-side guide](read-side.html). Direct peers observe connection metadata and
requests. Optional SOCKS gateways change transport; they do not remove the
wallet's chain-verification assumptions.

## Payment review and signing

The app presents the recipient, amount and fee, authenticates protected
actions, and invalidates stale reviews when payment inputs change. WalletCore
constructs transactions and validates PSBT commitments.

Receiving uses BIP86 Taproot, and every spend is a key-path spend signed by
this phone's key. The [native secp256k1 module](../Sources/NativeSecp256k1/README.md)
derives keys, applies the Taproot tweak and makes the BIP340 signature; it is
variable-time and does not zeroize secrets. Contact-card labels do not
establish authority; the descriptor and verified signatures do. The
[write-side](write-side.html) guide explains the protocol and its limits.

## Persistence, keys and backup

The app persists wallet and presentation state and supplies the Keychain-backed
implementation of WalletCore's key-store interface. Local signing secrets use
device-only, user-presence-protected Keychain entries. In-memory key storage
belongs to TestSupport.

The app also owns [CloudWalletBackup](../Sources/WinnowApp/CloudWalletBackup.swift),
[CloudBackupController](../Sources/WinnowApp/CloudBackupController.swift) and
[ICloudBackupStore](../Sources/WinnowApp/ICloudBackupStore.swift). They encode and
encrypt backup contents, schedule retries and perform private CloudKit writes.
The backup wrapping key uses a separate, synchronizable iCloud Keychain service.
That cloud copy adds Apple Account and iCloud Keychain dependencies to secret
protection; it does not change the local signing key's access controls.

A successful save date confirms the upload of encrypted contents. Manual files
and recovery words remain part of the [backup guidance](import.html).
[CloudKit setup](../CloudKit/README.md) covers schema, encryption and validation.

## Source map

WalletCore directories organize one module:

- Primitives: [crypto and encodings](../Sources/WalletCore/Crypto/README.md),
  [keys](../Sources/WalletCore/Keys/README.md),
  [descriptors](../Sources/WalletCore/Descriptors/README.md) and
  [scripts](../Sources/WalletCore/Script/README.md).
- Spending: [wallet state](../Sources/WalletCore/Wallet/README.md),
  [PSBTs](../Sources/WalletCore/PSBT/README.md) and
  [transactions](../Sources/WalletCore/Transactions/README.md).
- Synchronization: [headers](../Sources/WalletCore/Network/Headers/README.md),
  [filters](../Sources/WalletCore/Network/Filters/README.md) and
  [peer selection](../Sources/WalletCore/Network/Peers/README.md).
- Communication: [transport](../Sources/WalletCore/Network/Transport/README.md),
  [wire protocol](../Sources/WalletCore/Network/Protocol/README.md),
  [broadcast](../Sources/WalletCore/Network/Broadcast/README.md) and
  [mempool](../Sources/WalletCore/Network/Mempool/README.md).
- Curve arithmetic: [native secp256k1](../Sources/NativeSecp256k1/README.md),
  with its [reference fixtures](../Tests/BitcoinCoreTests/Vectors/native-secp256k1/README.md)
  and [fixture generators](../Tools/Generate/native-secp256k1/README.md).

The [testing guide](testing.md) maps the test targets to these responsibilities.
[Scripts](../scripts/README.md) and [workflows](../.github/workflows/README.md)
index the build and release entry points. Security reports and dated audit
evidence live under [security](security/README.md); their findings and results
apply to the revisions they identify.

The public website has its own
[repository](https://github.com/winnowwallet/website). The app bundles four
HTML guides and their stylesheet from this repository's `docs/` directory.
Changes to those bundled files are app changes and participate in CI's build
fingerprint.
