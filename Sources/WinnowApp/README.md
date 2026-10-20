[Back to main README](../../README.md)

# The wallet app

SwiftUI screens and AppModel turn wallet and network state into receiving,
sending, recovery, and saved recipients. The app owns user review,
authentication, presentation, and lifecycle; WalletCore owns the Bitcoin rules.
The app supports iPhone, iPad, and Apple silicon Mac (Designed for iPad).
Simple mode uses one screen; Advanced mode adds Wallet, Send, and Settings tabs.
The automated UI journey currently covers iPhone only.

Wallet is the one account and transaction list. Payment details save or rename a
recipient; Send holds the saved-recipient picker and the amount. The reviewed
proposal is signed with this phone's key after the owner authenticates; there is
no shared account, approval screen or PSBT exchange with other signers. Advanced
mode keeps coins and the raw descriptor under Technical details.
Removing a shortcut preserves
past labels and fresh-address counters in the existing
people.json store. Receive shares the wallet’s payment card.

[Documented journeys](https://github.com/winnowwallet/website/blob/main/docs/journeys.json) identify the supported experiences.
[App tests](../../AppTests/README.md) check state and protected actions;
[UI tests](../../UITests/README.md) drive the simulator against a disposable node.
Simulator tests do not establish physical-device lock behavior or battery life.

Assets.xcassets contains the app icon and its Xcode metadata; it is an asset bundle,
not another code layer. [make-icon.swift](../../scripts/make-icon.swift) creates icon
artwork; changing it requires inspecting the rendered icon and building the app.
Keep documentation outside the asset catalog so it is not treated as an asset.

[Automatic iCloud recovery](../../CloudKit/README.md) automatically updates an
encrypted wallet backup by default and finds it on a replacement device. Beginner
mode shows status; Advanced holds manual recovery and the persistent opt-out.
CloudBackupController owns backup preferences, encrypted retries, lifecycle and last-success state;
ICloudBackupStore owns private CloudKit transport and separate wrapping keys.
