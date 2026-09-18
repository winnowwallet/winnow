# iCloud wallet recovery

Automatic backup is on by default in both beginner and Advanced modes. Creation
and restoration prepare encrypted retry state during their existing authentication;
there is no Enable button or consent dialog. Existing wallets initialize at the next
foreground opportunity, with device authentication at most once per foreground
session. No Apple Account means no authentication prompt just to discover that
cloud storage is unavailable. Beginner mode shows **Backing up**, **Backed up** or
**Not backed up** and stays usable without iCloud. Advanced contains the persistent
automatic-backup switch, manual export and recovery words. A mode switch never
changes the backup preference. No phrase checklist blocks beginner onboarding.

Onboarding automatically finds backups for the selected Bitcoin network in the
same Apple Account. Restoring still requires selecting a backup and authenticating
before decrypting and installing the key.

The backup contains this phone's recovery phrase, wallet descriptor, tracked
funds, payment history, address counters, shared accounts, saved people and
payment cards, sender names, receive-address labels, display name and interface
mode. Other owners' signing keys are not on this phone and are not included.
Watch-only and xprv-only imports cannot enable this mnemonic-based backup.
Manual file export is unchanged and does not include this extra app context.
Peer/explorer endpoints remain device-local, so a replacement phone does not
inherit an inaccessible private-network address.

## Encryption and updates

`CloudWalletBackup` encrypts the phrase and wallet state separately with AES-256-GCM.
The random wrapping key is stored under a separate, synchronizable iCloud
Keychain service, accessible while the device is unlocked. iCloud stores only
ciphertext plus a random backup ID, network and save date. No phrase or plain
wallet bundle is written to a staging file. The normal signing Keychain remains
device-only with user-presence access control. Automatic cloud recovery adds another
route to the secret: access to the iCloud backup and its wrapping key is enough
to recover it. It therefore adds trust in Apple Account and iCloud Keychain
recovery, and does not retain the same device-only threat model.

The wallet-specific opt-out is stored separately from upload configuration. An
outage never becomes an opt-out. Upload failures retry during foreground refresh
with exponential backoff from 60 seconds up to five minutes. Initial encrypted
preparation can precede account availability; the first available account is pinned
before upload, and subsequent account changes cannot overwrite that copy.

Automatic updates reuse the encrypted phrase and export fresh public wallet
state after foreground sync/refresh. They never reread the local signing key.
Pending payments defer updates under the existing export policy; the previous
backup and save date remain visible. Failure, cancellation, a wallet switch or
an iCloud account mismatch cannot advance the displayed successful-save date.
Each device’s initial backup creates its own record, so a second phone cannot overwrite the first
phone's backup. Restoring prepares automatic updates, unless explicitly disabled, for a new independent
record. Its encrypted retry state survives a restart or outage, and the app
shows no successful-save date until CloudKit acknowledges that device's upload.
Existing local contacts win name/destination conflicts, recipient counters never
move backward for the same key, and sender labels follow merged identifiers.
This is recovery, not live multi-device wallet synchronization.

Version 2 seals the app context inside the same authenticated ciphertext as
wallet state. Version 1 copies remain readable, and the restore screen explains
that they do not contain names or labels. An automatic update upgrades a legacy
copy without reading the signing phrase again. The total encrypted envelope is
bounded to 32 MiB; app context is bounded to 10 MiB and each store still enforces
its own tighter structural limits. Invalid context is rejected before the wallet
or Keychain is changed.

Stopping automatic updates keeps the existing cloud copy. Deleting the local
wallet also leaves the cloud copy. Keep recovery words and a manual file as a
separate recovery route. A successful CloudKit save confirms the ciphertext was
uploaded; it cannot prove the wrapping key has synchronized to another device.
The restore screen reports a missing key without replacing it or opening an
incomplete wallet.

## Apple setup required before release

The app entitlement names `iCloud.com.btcswift.app`. Register that container and
associate it with the `com.btcswift.app` App ID in the Apple Developer account.
Refresh signing profiles through automatic signing. Provisioning and production
schema deployment are external account operations; a successful unsigned build
does not establish either one.

[schema.ckdb](schema.ckdb) is authored source, not generated Swift. Import it into
the container's development environment, then deploy to production through
[CloudKit Console](https://icloud.developer.apple.com/). The `___recordID` query
index, the network query index and the save-date sort index are required for listing backups. Do not grant access to the public database.

With an authorized management token stored securely in the local Keychain,
the development schema can be imported using Apple's tool:

```sh
xcrun cktool import-schema --team-id 2858MX5336 \
  --container-id iCloud.com.btcswift.app --environment development \
  --file CloudKit/schema.ckdb
```

Never put management tokens, signing keys or user backup contents in source,
command arguments or CI logs. See Apple's documentation for
[schema deployment](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
and [iCloud configuration](https://developer.apple.com/documentation/xcode/configuring-icloud-services).

## Validation

Package tests exercise encrypted round trips, spending-key restoration, address
counters, automatic updates, tampering, wrong keys and bounded decoding. App
unit tests use in-memory cloud and key stores for failures, wallet/account
changes, cancellation, automatic defaults and persistent opt-out. These run in existing CI.

Before App Store submission, use disposable signet funds on two physical devices
with the same test Apple Account and iCloud Keychain enabled. Create a wallet without enabling backup, wait
for a saved date, restore on the second device, and check addresses, balances,
history and a signed payment. Also check an offline device, disabled iCloud
Keychain, a different Apple Account and cancellation during authentication.
Do not erase the only real wallet to test recovery. Hosted simulator tests cannot
prove actual iCloud transport, Keychain synchronization or Apple provisioning.
