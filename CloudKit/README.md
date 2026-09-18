# iCloud wallet recovery

Automatic backup is optional. Enable it in **Back up wallet → iCloud backup**,
confirm that it includes the signing key, and authenticate. **Restore from
iCloud** finds backups for the selected Bitcoin network in the same Apple
Account. Restoring authenticates before decrypting and installing the key.

The backup contains this phone's recovery phrase, wallet descriptor, tracked
funds, payment history, address counters, and shared accounts. Other owners'
keys, local recipient names and receive labels are not included. Watch-only
and xprv-only imports cannot enable this mnemonic-based backup.

## Encryption and updates

`CloudWalletBackup` encrypts the phrase and wallet state separately with AES-256-GCM.
The random wrapping key is stored under a separate, synchronizable iCloud
Keychain service, accessible while the device is unlocked. iCloud stores only
ciphertext plus a random backup ID, network and save date. No phrase or plain
wallet bundle is written to a staging file. The normal signing Keychain remains
device-only with user-presence access control. Opting into recovery adds another
route to the secret: access to the iCloud backup and its wrapping key is enough
to recover it. It therefore adds trust in Apple Account and iCloud Keychain
recovery, and does not retain the same device-only threat model.

Automatic updates reuse the encrypted phrase and export fresh public wallet
state after foreground sync/refresh. They never reread the local signing key.
Pending payments defer updates under the existing export policy; the previous
backup and save date remain visible. Failure, cancellation, a wallet switch or
an iCloud account mismatch cannot advance the displayed successful-save date.
Each opt-in creates its own record, so a second phone cannot overwrite the first
phone's backup. This is recovery, not live multi-device wallet synchronization.

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
changes, cancellation, opt-in and stopping updates. These run in existing CI.

Before App Store submission, use disposable signet funds on two physical devices
with the same test Apple Account and iCloud Keychain enabled. Enable backup, wait
for a saved date, restore on the second device, and check addresses, balances,
history and a signed payment. Also check an offline device, disabled iCloud
Keychain, a different Apple Account and cancellation during authentication.
Do not erase the only real wallet to test recovery. Hosted simulator tests cannot
prove actual iCloud transport, Keychain synchronization or Apple provisioning.
