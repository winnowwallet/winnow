# Lightning feature scope

Winnow's Lightning implements portable channel recovery, an easier first
receive, ordinary BOLT12 and BIP353, and anchors with fee bumping, on Winnow's
Swift wallet. WalletCore remains the source of transaction models, signing, coin selection,
chain scanning and authenticated storage. Reference Bitcoin/Lightning nodes
stay in the external host test harness.

| Feature | App behavior | Verification |
| --- | --- | --- |
| Portable channel recovery | Export an encrypted file keyed by the wallet's own recovery phrase (files from 0.8.0 keep their separate 24-word phrase). Restore independent Lightning keys into a new, permanently recovery-only namespace before importing Bitcoin keys. Bind interrupted imports to the matching Bitcoin descriptor and finish sealed shared-account metadata before any scan or spend. Connect to original peers and scan for returned funds. | Authenticated file round trip with fresh device keys; wrong phrase/network and damaged file rejection; restart and unavailable-peer checks; a stale backup claims the stock peer's newer on-chain commitment without publishing the saved old commitment. |
| Easier first receive | Enter the intended payment amount before setup. Distinguish the provider's minimum capacity from that payment. Review the actual setup fee and explicitly approve before exposing a payable setup invoice. Paused unpaid orders retain their identity and expiry across restart. Invoice creation still requires confirmed capacity. | App intent/cancellation/restart tests, public unpaid provider quote and disposable stock-node BOLT11 receive. Olympus and Megalith retain protocol/API setup; LNServer remains clearly labeled website setup. |
| Instant first receive (LSPS2) | One invoice: show the provider's fee from its LSPS2 menu, buy only after approval, accept the provider's private channel before it confirms only for that purchase, and claim the payment minus the declared `extra_fee` up to the agreed fee. Aliases route the next invoice before confirmation. | `JITTests`, `ZeroConfChannelTests`, LSPS0/LSPS2 sessions over a real Noise connection, app receiving tests, and `scripts/ci-lightning-jit` against stock LDK's LSPS2 service (provider broadcasts or client trusts it, scid privacy, zero-reserve anchors). |
| Ordinary BOLT12 and BIP353 | Request a signed ordinary invoice from a standard offer, review amount and fees, authenticate and pay. Create reusable offers separately from async offers. Resolve names by validating DNSSEC locally, then bind the resulting invoice request to that name and offer. | Signed/direct/blinded request, invoice, HTLC, restart and replay tests; published DNSSEC proof vectors, damaged/delegation/wildcard checks and live authenticated name resolution; stock-node payment interoperability. |
| Anchors and fee bumping | Explicitly negotiate and persist anchor format; preserve existing static-remotekey channels. Review a bounded commitment CPFP child or HTLC fee augmentation, reserve wallet inputs durably, then sign and publish. Interrupted approved spends resume using the same signed bytes. | Stock channel opening/payments/restart, Bitcoin consensus HTLC success/timeout/CSV/revocation matrix, CPFP replacement with an enforced total fee cap and cross-journal crash tests. Congestion relay is checked through the actual P2P broadcaster. |

The CRAP gate inventories first-party Swift function and initializer bodies,
counts switch cases, and uses executable-line coverage from package tests, the
app tests and the signet journey. Missing coverage stays unmeasured and is gated using its
zero-coverage bound. [The metric definition and reproduction steps](../crap.md)
state the scope and accessor/standalone-closure limitation. CI retains source
hashes, test profiles and reports; it does not suppress difficult functions.

The CLI interoperability gates keep released Core Lightning `v26.06.8`
(commit `6f741afc395c66d200429ea477d29df4d974748d`) unchanged. The macOS
simulator's BOLT11 peer uses that release with a separately built HSM containing
only the exact reviewed [upstream PR9564 fd-lifetime fix](https://github.com/ElementsProject/lightning/pull/9564)
at `d03657d3ee118a96d346c6a1faaefce7dead6e1c`. This patch is unmerged and
unreleased. Its original patch, released base, source and binary hashes are
retained in a distinct UI manifest and receipt. The stock daemon loads it through
its supported subdaemon option; version checks, financial assertions and original
deadlines remain active. This HSM is test infrastructure and is never linked into
Winnow or shipped in the app. A UI run with this override does not establish
unmodified-release interoperability; the separate stock CLI gates do.

## Release checks that require separate evidence

iCloud backup covers the Bitcoin wallet and never holds channel state; the
encrypted recovery file carries the channels and works without an Apple
Account. Proving the recovery file and the iCloud wallet backup together on
another real device remains a release check, not a claim made by the simulator.

Device-owner authentication, locked-device storage behavior, camera scanning,
file/share-sheet behavior on real hardware and a funded mainnet payment remain
separate from disposable regtest interoperability. No real payment or provider
setup fee is sent by these tests.

Background checks can publish already authorized transactions and are scheduled
by iOS. Some penalties for a remote augmented anchor HTLC need fresh foreground
signing after the chain reveals its actual transaction ID. This change does not
provide a watchtower or an assurance that an offline phone is protected.

An interrupted Bitcoin import is sealed before keys are installed. Startup completes its shared-account metadata before scanning. If a crash left the old same-descriptor wallet ahead of that import, Winnow keeps syncing and spending blocked and exposes an authenticated retry from the matching backup. It does not replay old channel commitments.

A replacement device never resumes channel payments from an old backup. A peer
may delay recovery until it closes; independent recovery evidence distinguishes
peer RPC-driven closure from automatic closure in response to data-loss
protection messages.

Watchtowers, LNURL-pay/Lightning addresses, multipart payments, splicing and
keysend are outside this scope. The ordinary offer protocol and
DNSSEC details are documented in [Lightning offers](lightning-offers.md).
