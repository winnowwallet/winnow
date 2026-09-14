# Review of loperanger7’s Winnow patches

Reviewed 2026-09-14 for [PR #87](https://github.com/winnowwallet/winnow/pull/87). The inventory covers all ten PRs authored by loperanger7 in `winnowwallet/winnow`; none were found in `winnowwallet/census`. Several PR branches included unrelated shared history. Integration preserves the individual authored commits instead of importing their entire branch diffs.

| Patch | Disposition | Implementation and evidence |
| --- | --- | --- |
| [#75](https://github.com/winnowwallet/winnow/pull/75) | Already in #87; absent from the September 14 baseline | BIP39 NFKD for both seed inputs. Japanese and ligature vectors, strict separator rejection, and an added compatibility-space validation/seed agreement test. |
| [#76](https://github.com/winnowwallet/winnow/pull/76) | Ported | Explicit file protection on wallet creation/save/import, header full saves, and peer persistence. Tests mark the containing directory with a different class and check creation, replacement, and append. The suite also runs in the app test target; platforms that do not record protection classes report a named skip. |
| [#77](https://github.com/winnowwallet/winnow/pull/77) | Ported | One master-key load per signing operation, verified signatures for every input, and a 100,000-vbyte standardness limit. Selection checks estimated size; sends, fee bumps, and finalized vault spends check actual size. This is default relay policy, not a consensus rule. |
| [#78](https://github.com/winnowwallet/winnow/pull/78) | Existing behavior retained; missing regressions ported | Non-witness transaction bytes survive commit, confirmation, replacement, and reopen. Legacy history without raw bytes remains readable. |
| [#79](https://github.com/winnowwallet/winnow/pull/79) | Ported and completed | Unsolicited backlog bounded by count and wire-payload bytes. Stalled event subscribers receive a conservative slot budget using the largest accepted payload; teardown releases the backlog. Real loopback tests cover floods, oversized messages, honest bursts, and a stalled subscriber. This is a payload-retention bound, not a total-RSS guarantee. |
| [#80](https://github.com/winnowwallet/winnow/pull/80) | Already in #87; absent from baseline | BIP32 depth exhaustion throws. Descriptor origins are bounded; wallet account keys leave room for chain/index derivation before storage is written. Impossible PSBT derivation entries are ignored without aborting signing for a valid entry. |
| [#81](https://github.com/winnowwallet/winnow/pull/81) | Ported | A completed transport handoff remains recorded after disconnect and reload. Old records default to no handoff. This does not prove peer acceptance, retention, propagation, or confirmation. |
| [#82](https://github.com/winnowwallet/winnow/pull/82) | Ported and completed | Library regtest parameters and `bcrt` address handling, including no difficulty retargeting. The existing descriptor `network: HDKey.Network` API remains compatible; `bitcoinNetwork:` distinguishes signet/regtest. The shipping network picker remains mainnet/signet. |
| [#83](https://github.com/winnowwallet/winnow/pull/83) | Ported and completed | Check each proposed batch against checkpoint commitments before fetching filters; reject wrong checkpoint counts before callbacks. Prune while retaining boundaries, recent headers, and the original anchor. Deep rollback reconstructs headers from a surviving pin without replaying earlier payment callbacks. Chunk requests, bounded runs, and height arithmetic have regression tests. |
| [#86](https://github.com/winnowwallet/winnow/pull/86) | Not applicable | The author [withdrew it](https://github.com/winnowwallet/winnow/pull/86#issuecomment-5615329447): its `KnownTransaction.outputs` field does not exist upstream. Current history stores bounded bundle entries and optional raw transaction bytes; no downstream field was added merely to carry this patch. |

## Integration decisions

Current organization main was merged into #87 before porting the remaining fixes. The receive-address label branch (#96) is also included so the combined changes are tested together. The merge retains Tor routing, census controls, people flows, iPad navigation and sheet scrolling, and real background/foreground helpers. Backup screens keep #87’s file-ready summary and never display exported JSON or recovery words. UI assertions inspect the actual staged file and verify its removal after replacement, dismissal, and backgrounding.

A rejected checkpoint comparison has no payment callbacks or saved progress from that batch. A later filter, network, or callback error can happen after an earlier chunk delivered matches; the batch frontier is saved only after all chunks finish. Self-consistent filters are not authenticated by proof-of-work headers: agreement across peers and retained pins is the available check, and a sole surviving peer is a degraded mode.

The descriptor API compatibility repair and regtest retargeting control were added during review. A regtest key uses testnet extended-key versions while its address uses `bcrt`; these are different concepts.

## Verification

The combined receive-label/patch branch passed 645 reported package tests across 69 suites, with opt-in and platform-specific skips reported separately. A fresh isolated Bitcoin Core fixture passed all 26 differential tests across 10 suites. All 24 script tests passed with checksum-verified cloc 2.10, as did lint, first-party warnings, website links, LFS integrity, and release policy.

The combined iPhone run passed 168 XCTest app cases plus 8 Swift Testing app cases, and HostProcessProbe + onboarding, receive/funding/label persistence, backup export, and unconfirmed incoming-payment journeys. The simulator explicitly skipped 5 protection-attribute cases because it does not record those attributes. The iPad backup check passed after correcting share-popover dismissal; onboarding/funding passed in the preceding run. All five protection-attribute cases also passed on a physical iPad Pro (11-inch, 2nd generation), with zero skips, using a separate app identifier that preserves the TestFlight wallet.

The first hosted arm64 package run exposed two header-protocol fixtures that stopped replying after 2-second waits, turning a protocol assertion into a timeout under load. Every expected request is now required explicitly, and the tests use the normal 30-second transport window. Production timeout and retry policies are unchanged. The exact error, recovered chain, and bounded-retry assertions remain. All 36 header-chain cases and the complete local package suite passed with this correction; A subsequent hosted run reached a filter-pruning assertion without a connected fixture peer. The four large-chain filter fixtures now require a completed handshake explicitly and allow 30 seconds for setup while concurrent tests mine synthetic chains. Their checkpoint-mismatch, unchanged-frontier, and honest-resume assertions remain unchanged. Updated hosted runs remain pending.

The full ordered iPhone/iPad CI journeys, package checks on both architectures, app build/tests, warning checks, and website checks must finish before merging. CI logs and screenshot bundles are preserved by the [Node integration workflow](https://github.com/winnowwallet/winnow/actions/workflows/node-tests.yml). Screenshots in `docs/screenshots` are actual test captures stored with Git LFS.

## Primary references

- [BIP39](https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki): NFKD seed inputs.
- [BIP32](https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki): serialized one-byte depth.
- [BIP157](https://github.com/bitcoin/bips/blob/master/bip-0157.mediawiki): checkpoint intervals, filter-header checks, and peer comparison limitations.
- [Bitcoin Core policy](https://github.com/bitcoin/bitcoin/blob/master/src/policy/policy.h): `MAX_STANDARD_TX_WEIGHT`.
- [Bitcoin Core chain parameters](https://github.com/bitcoin/bitcoin/blob/master/src/kernel/chainparams.cpp): regtest parameters.
