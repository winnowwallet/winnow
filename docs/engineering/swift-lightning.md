# Swift Lightning implementation and release gates

This expands draft PR #3 from Winnow baseline
`a1cc6fbaf6f0d3d68c675e1a78e8d5b8311767f7`. Keep one Swift engine and Winnow's
transaction model, funding wallet, fee policy, verified chain/filter scan and
broadcast path. P256K and CryptoKit supply existing cryptography. Rust reference
peers run on the test host only; the application must contain no Rust, LDK,
PQLN or Kyoto runtime.

## Acceptance contract

The shareable object is the **recipient's reusable receive offer**, shared with
Apple's Share sheet or exact Copy/Paste. A sender-created bearer claim is not
part of this milestone. Test the upstream Lightning async protocol, including
its limitations, rather than substituting the older custom claim protocol.

Use these independent references without changing their protocol code:

- Core Lightning v26.06.8, commit
  `6f741afc395c66d200429ea477d29df4d974748d`.
- LDK commit `0a2b003e7e1602df8933b15b7563ba8b6e198391`, with a host harness for
  network connections, persistence, process control and static invoice serving.
- BOLT vectors at `1aadb719b4007c4cea0ba6e36b08c4fb53788dee` and Bitcoin Core
  regtest consensus checks.

The Rust host harness, Cargo lockfiles and reference builder live in
[lightning-reference](https://github.com/posix4e/lightning-reference).
`scripts/ci-lightning-references` fetches the exact repository commit recorded
in that script and rejects a mismatched or modified checkout before executing
its builder. `reference-manifest.json` records the external harness revision
alongside the upstream peer revisions. Swift fixtures and Winnow-specific
scenario drivers stay here; all existing interoperability gates still run.

Interoperability evidence is not blanket standards certification. Do not
advertise unsupported features or skip tests when a peer lacks a required
capability.

## Required engine work

- BOLT 1/2 negotiation for private static-remotekey non-anchor channels.
- Commitment/revocation transitions, HTLC settlement, reestablishment,
  cooperative close and force-close recovery.
- BOLT 12 offers and static invoices, blinded paths, onion messages and the
  pinned LDK hold/release async flow. Start with a configured single-path
  regtest topology.
- A single protected versioned journal for channels, monitors, stable payment
  IDs and protocol outbox. Persistence precedes wire publication. An uncertain
  storage write stops financial actions. Verified chain catch-up precedes resume.
- Winnow funding reservations must survive restart and cannot be reused by
  ordinary sends, replaced after publication, or canceled after submission.
- Typed engine events drive preparing, awaiting recipient, settled, failed and
  recovering UI. Only verified settlement produces success.

## Required app and test work

- Integrate funding/payment review, receive offers, sharing, history and
  recovery into the existing research app, preserving spending authentication.
- Use a new Swift storage namespace. Preserve legacy PQLN data without opening
  it with the new engine or overwriting it.
- Stock CLN ordinary lifecycle; Swift-to-LDK and LDK-to-Swift async payments.
- Crash boundaries, failed persistence, duplicate payment requests/messages,
  reordering, release-before-hold, expired offers/paths, provider restart,
  recipient never returning, timeout, force close and reorg.
- App-host tests for canceled authentication, duplicate taps, fee/amount review,
  malformed offers, exact share bytes, lifecycle and restored history.
- Recorded iPhone lifecycle: funding, channel, payments, actual process
  termination/restart, reconciliation and close with returned funds.
- Recorded async journey: recipient shares then terminates; sender pays then
  terminates after durable hold; recipient relaunches and settles while sender
  remains stopped; sender relaunches and records settlement exactly once.
- Separate recipient/sender namespaces and process logs prove non-overlap.
  Independent peers verify hashes, amounts, fees and balances.
- Retain the ordinary recorded on-chain signet journey. Open the Apple Share
  sheet and test Copy/Paste; do not send third-party messenger messages.

## CI and release

Extend the existing CI workflow with a Swift Lightning lane beside ordinary
checks. Start fresh reference fixtures, build app/test bundles once, reuse
them for journeys, and retain videos, screenshots, xcresults, redacted logs and
a source/peer manifest. Require iPhone journeys on PRs; check iPad and large text
before TestFlight. Physical-device authentication, sharing and lock protection
may be checked after installation through internal TestFlight, with the pending
checks recorded explicitly rather than reported as passed.

Keep the PR draft until these gates pass. Release the exact green commit to the
existing `com.btcswift.lightning` TestFlight app through the existing signing,
export/compliance and release gates. Verify processing and tester availability.
This remains a research beta with opportunistic background checks, without
guaranteed unattended channel protection. The app now supports mainnet, public signet and regtest (see below).

## Public networks

Fresh research-app installs default to mainnet and use Winnow's normal public
peer discovery. Settings can switch mainnet, signet and regtest. An upgrade with
an existing regtest wallet or journal keeps that selection until the user
switches. Wallet files, channel identities, journal keys and provider profiles
remain separate per network; the existing regtest key account is retained.

Lightning uses the selected network's chain hash, addresses, sealed profile and
offer checks. Funding commitment rates use Winnow's fee policy. Compatible
provider configuration is still required for channels, and async receive offers
require an async-capable provider and configured route. This change does not
implement provider discovery or general graph routing.

Before the first channel, the ordinary wallet scanner runs without journaling
every historical block. The Lightning monitor saves a verified starting point
144 blocks behind the tip, bounded by the available checkpoint. Once a channel
exists that starting point is fixed. Newly learned funding replays from it;
normal reorgs use the monitor's retained ancestry. Header caches are caught up
before comparing persisted monitor positions. A fork below the starting point
stops for recovery rather than discarding channel history.

The journal is schema 4. Schema-2 and schema-3 journals retain their scan
history and identity when upgraded; older binaries refuse schema 4 so they
cannot ignore a close initiated by the background monitor.
Network switching drains the old scanner and stops its Lightning session before
loading another wallet. Pending reviews and late events are rejected after the
session generation changes. Mainnet connectivity tests must be distinguished
from funded-channel and payment evidence; controlled CLN/LDK interop remains on
regtest.

## Evidence tracking

`ci-lightning-peer` now checks stock CLN channel opening, payments in both
directions, stable payment IDs, actual Swift process termination/restart,
reestablishment, cooperative close and an independently signed force close.
Bitcoin Core validates commitment, HTLC, delayed, immediate and penalty spends,
including penalties after a peer's second-stage transaction wins the first race.

`ChainRecoveryTests` covers verified scanner sharing, journal cursor replay,
funding reorgs, maturity recalculation, stale-backup protection and failed writes.
`ci-lightning-offers` checks BOLT12 offers, requests and static-invoice signatures
in both directions against the pinned LDK public APIs. Published BOLT12 encoding
and signature vectors are also required.

`ci-lightning-async` now runs both Swift-to-LDK and LDK-to-Swift over real TCP,
with separate sender, recipient and two provider processes. The recipient is
killed after its reusable offer is acknowledged by the static-invoice server;
the sender is killed after the held HTLC is committed; the recipient settles
while the sender remains stopped; the sender then restores and reconciles.
Both directions also pass with both providers killed and restored during the
offline interval. Receipts compare hashes/preimages, committed HTLC values and
forwarding fees, and record process order plus source/reference identities.
LDK can insert dummy hops: distinguish the actual incoming channel amount from
the post-dummy-hop amount in its claim event, while checking the exact total debit.

The shared journal payload is schema 4 (schemas 2 and 3 are upgraded); pre-release schema 1 is refused rather
than silently discarding channel state. The app integration must use its own new
Swift namespace and preserve the prior PQLN application's files. Optional onion
messages are discarded according to BOLT4 without interrupting channel messages;
a persistence failure still stops every publication path. Receive preimages are
persisted with the fulfill intent for on-chain recovery after a crash.

The foreground `LightningPeerSession` now drives both the app and independent
host fixtures. Request and held-notification onions retry their original bytes
at a bounded interval until an authenticated response, settlement or expiry.
Tests cover lost delivery across restart, duplicate invoices/notifications,
registration acknowledgement ordering, expired paths, and every ordering of
the commitment acknowledgements and release path before notification.

`ci-lightning-timeout` kills the recipient permanently and then both providers.
After a sender restart, complete Core-validated blocks drive the Swift monitor
through automatic commitment publication, HTLC timeout and delayed recovery.
Core validates all four recovery transactions and the exact returned balance;
the payment becomes failed only after sufficient confirmations. A local run
returned 997,440 of 1,000,000 sats, with 2,560 sats of independently calculated
transaction fees. Chain tests also revert confirmed payment outcomes to
recovering after a reorg while retaining learned preimages.

The `WinnowLightning` research scheme now integrates the same engine with the
wallet's funding reservations, fee policy, verified scanner and broadcaster.
The recorded app journey checks exact Apple Share/Copy bytes, canceled funding
review, actual host SIGKILLs, offline settlement, one restored payment entry,
and cooperative close returning the independently calculated wallet balance.
Its manifest identifies the clean source, executable, device/runtime, text
size, video hash and independent receipt. Run it on iPhone, iPad and at maximum
accessibility text size; the existing CI requires the iPhone journey alongside
the ordinary signet recording.

Research storage and device-only keys use a separate namespace. Deletion and
replacement of its wallet are refused to preserve channel recovery keys;
ordinary wallet behavior is unchanged. The welcome screen explains that this
research wallet has no iCloud backup and that its channel journal must stay on
the device. Payment review keeps amount, fee and expiry above an expandable
exact receive offer.

Exact-source green CI and reviewed export compliance remain required before
internal tester distribution. Physical-device authentication/file protection may
remain explicitly pending for testing through TestFlight. Upload-only mode
omits the encryption declaration keys to trigger Apple’s questionnaire while
review is pending and stops before assigning testers. The signed archive,
export, upload, processing and existing internal-group readback are implemented
in `scripts/release-lightning`; see `lightning-release.md`. A successful host or
simulator run does not establish TestFlight availability.


## Bounded background chain checks

The iOS app registers BGAppRefresh and BGProcessing tasks at launch and requests
checks with a 15-minute earliest start. iOS chooses the actual schedule. Refresh
work has a 25-second local budget; processing has a 120-second budget. Expiry
cancels work, closes sockets and drains the scan before completing the task.
Foreground activation cancels and drains background work before rebuilding its
network stack. Checks cover the selected network; the timestamp is network scoped.

Wallet and channel watches use the same PeerPool, HeaderChain, FilterSync and
TxBroadcaster. Verified partial progress persists. A complete check is recorded
only after catching up and serving any recovery transactions to a peer; serving
is not mining confirmation. The UI calls a check overdue after an hour, which is
a freshness reminder, not a calculated safe offline duration.

The full Lightning journal remains encrypted with a WhenUnlockedThisDeviceOnly
key and complete file protection. The separate background journal contains public
chain observations and pre-signed recovery transactions, including HTLC second
stages and revoked-commitment penalties. It contains no wallet seed, node secret,
channel signing keys or revocation secrets. Its separate encryption key uses
AfterFirstUnlockThisDeviceOnly and its file uses complete-until-first-unlock
protection. Both remain excluded from backup. Recovery destinations and fees are
fixed by the foreground recovery policy; background cannot pay, fund, sign new
transactions or connect to a Lightning protocol peer.

Every foreground transition updates recovery before the full journal and before
publishing protocol messages. If the second write fails, the recovery revision is
ahead and foreground refuses to resume rather than replacing it with older data.
A store lease prevents simultaneous foreground writes and background recovery.
A background close intent persists before broadcast; foreground adopts it before
resuming protocol work and replays its own verified scan cursor. Reorgs recompute
CSV/CLTV maturity from retained chain observations. A stale or corrupt store fails
closed. Header ancestry outside the retained window requires foreground recovery.

Tests cover the shared scanner, incomplete catch-up, expiry, close handoff,
failed writes, private-key exclusion, CSV reorgs, direct/second-stage penalty
recovery and bounded transaction relay. Simulator tests do not establish actual
locked-device Data Protection enforcement or iOS scheduling reliability. Check
those on physical devices using the internal TestFlight build. Powered-off,
force-quit and indefinitely offline phones cannot perform these checks; no external
watchtower has been added. Dynamic fee bumping remains a foreground limitation.
