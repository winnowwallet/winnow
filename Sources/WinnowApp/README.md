[Back to main README](../../README.md)

# The wallet app

SwiftUI screens and AppModel turn wallet and network state into receiving,
sending, recovery, and saved recipients. The app owns user review,
authentication, presentation, and lifecycle; WalletCore owns the Bitcoin rules.
The [architecture guide](../../docs/architecture.md) maps these responsibilities.
The app supports iPhone, iPad, and Apple silicon Mac (Designed for iPad).
Simple mode uses one screen; Advanced mode adds Wallet, Send, and Settings tabs.
The automated UI journey currently covers iPhone only.

The Send field takes any address or a BIP352 silent payment code
(`sp1…`/`tsp1…`); the review names the code, notes that the on-chain address
is made for this transaction, and the receipt and payment details show both.
Only the everyday wallet can pay a code — shared accounts spend through script
paths BIP352 excludes — and the review gate binds the scripts the wallet derived
(SEC-018). A saved person may be a code too: reusable, never counted.

Wallet is one balance and one Transactions list: the wallet's own payments,
every multisig account's (named with the account), a move between the wallet
and one of its accounts as one row, and an account's draft awaiting
signatures on top ([DisplayedPayment](DisplayedPayment.swift), built by
`AppModel.payments` from the wallet's history and each account record's). The
headline balance is the wallet's plus the accounts', with a line saying how
much needs co-signers; both show in Simple mode too once an account exists.
Payment details save or rename a recipient; Send holds the saved-recipient
picker and the amount. The reviewed proposal is signed with this phone's key
after the owner authenticates. In Advanced mode Send has a From row: an
account's payment is reviewed from the PSBT this phone built, "Sign and
continue" signs it and files it as the account's draft, and the
signature-collection step ([MultisigSigningSections](MultisigViews.swift))
follows, Sign with Ledger, Copy PSBT, a pasted co-signer's copy, Finalize and
broadcast, before the same receipt; leaving mid-way loses nothing, since the
draft row in Transactions resumes it, and a person's address index advances
only at broadcast.
Advanced mode keeps coins and the raw descriptor under Technical details, and
its Wallet tab adds a Multisig section, and Settings a Signers screen
([SignerViews](SignerViews.swift)): this phone's key, the Ledgers paired over
Bluetooth (the key comes from the Ledger's Bitcoin app) and keys other people
sent, kept in the sealed per-network `signers.json`
([SignerStore](SignerStore.swift)), which like `people.json` survives deleting
a wallet and travels in every backup, file and iCloud, merged with the phone's
own on restore. "New multisig account" ([MultisigBuildView](MultisigBuildView.swift))
builds a k-of-n account from members picked there, pasted, or an account
already on this phone, which signs as its own policy says (every key of a
2-of-2, any 2 of a 2-of-3; this phone's key moves into it); a member of
several keys, a phone with its Ledger, makes the account nested; an optional
timelocked recovery path, fewer members or a separate key; the descriptor is
shown for the others to join with, and a
paired Ledger among the members approves the account on its screen. The
account's PSBT page is for what Send cannot do: a pasted co-signer's PSBT,
which becomes the draft, and a spend on the recovery path for coins old
enough. Or join a k-of-n account by pasting its descriptor (a paired Ledger
holding one of its keys approves it then) and receive into it. "Verify on
Ledger" shows a receive address on the Ledger's screen, "Sign with Ledger"
asks it for its signature, and "Register on Ledger" covers an account a
Ledger did not approve on joining ([LedgerViews](LedgerViews.swift),
[LedgerBluetooth](LedgerBluetooth.swift)). Every Ledger entry point is in
Advanced mode, the model refuses Ledger actions in Simple mode, and iOS asks
for Bluetooth only when pairing starts. Accounts live in the sealed per-wallet
`multisig.json` ([MultisigStore](MultisigStore.swift)), scanned with the
wallet's own filters; each record keeps its coins, its history (the wallet's
`HistoryEntry`, written by the shared `HistoryLedger`), its one draft, and the
bytes of spends it broadcast that no block has taken, which a payment's
screen can announce again or give up on, so a backup made mid-payment, file
or iCloud, restores a phone that can finish it.
Removing a shortcut preserves
past labels and fresh-address counters in the existing
people.json store. Receive shares the wallet’s payment card.

[Documented journeys](https://github.com/winnowwallet/website/blob/main/docs/journeys.json) identify the supported experiences.
[App tests](../../AppTests/README.md) check state and protected actions,
including [paying a silent payment code](../../AppTests/SilentPaymentSendFlowTests.swift);
[UI tests](../../UITests/README.md) drive the simulator against a disposable node.
Simulator tests do not establish physical-device lock behavior or battery life.

Assets.xcassets contains the app icon and its Xcode metadata; it is an asset bundle,
not another code layer. [make-icon.swift](../../scripts/make-icon.swift) creates icon
artwork; changing it requires inspecting the rendered icon and building the app.
Keep documentation outside the asset catalog so it is not treated as an asset.

[Automatic iCloud backup](../../CloudKit/README.md) updates an encrypted wallet
copy by default when available. Simple mode shows upload status; Advanced holds
manual export, recovery words and the persistent opt-out. A successful save date
confirms the upload; keep a manual file and recovery words as well.
CloudBackupController owns backup preferences, encrypted retries, lifecycle and last-success state;
ICloudBackupStore owns private CloudKit transport and separate wrapping keys.
CloudWalletBackup is the encrypted file itself: the phrase and the wallet state, sealed separately.
