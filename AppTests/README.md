[Back to main README](../README.md)

# App decisions and protected actions

These tests exercise the app's state transitions, persistence, privacy, and
authorization boundaries without driving every case through screen taps.
They protect the decisions behind payment review, recovery, and shared savings.

The tests run in the [iOS app host](../Sources/WinnowApp/README.md) and share
fixtures from [TestSupport](../Tests/Support/README.md).
The local `makeModel` helper gives each test a separate settings suite and removes
it at teardown. Pass the same suite to two models when testing persistence.
The [UI journey](../UITests/README.md) provides complementary screen-level
checks for ordinary and shared-account payments.

Run `scripts/ci-app-tests /tmp/winnow-app-tests` from the repository root with
Xcode and a simulator installed. [CI](../.github/workflows/ci.yml) retains the
result bundle and logs. Keychain attributes and authentication policy are tested;
actual locked-device behavior still needs [device evidence](../docs/security/README.md).

[Receive address labels](ReceiveAddressLabelTests.swift) check wallet/network
isolation, atomic persistence, address rotation and relaunch, bounded metadata,
and exact output matching without creating a sender contact.

`CloudBackupTests` checks opt-in, failed uploads, cancellation and wallet/account
changes with in-memory cloud and key stores. It does not establish actual iCloud
or iCloud Keychain synchronization; see [cloud recovery validation](../CloudKit/README.md#validation).
