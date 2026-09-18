[Back to main README](../../README.md)

# App screenshots and historical illustrations

The [recording page](https://winnowwallet.com/recording) presents one continuous
journey video with its source provenance.
The recorded ordinary, MuSig2, and script-path 2-of-3 payment journey retained
16 checkpoint screenshots as secondary run artifacts. The homepage keeps the
overview and signing illustrations; detailed recording and test evidence live
on separate pages. CI replaces these 16 images in each deployed artifact with
new or validated cached journey captures. The deployment’s `/recording` page
identifies their source run; the dated notes below describe repository assets,
not necessarily the images on the live site.

| Capture | Moment |
| --- | --- |
| `01-onboarding` | Before creating the wallet. |
| `03-receive` | The receive address after skipping the optional label. |
| `56-home-beginner` | The funded one-screen wallet. |
| `06-send-review` | The destination, amount, fee, and total before sending. |
| `08-send-confirmed` | The receipt after confirmation. |
| `09-home-after-send` | Wallet history after the payment. |
| `35-extra-device-policy` | Funded phone-plus-Core account and its 2-of-2 requirement. |
| `36-extra-device-review` | Account, destination, amount, fee, and total before approval. |
| `37-extra-device-waiting` | The signing exchange waiting for the Core reply. |
| `39-extra-device-sent` | The MuSig2 payment sent, with its transaction ID. |
| `40-extra-device-confirmed` | The MuSig2 account’s remaining confirmed balance. |
| `26-savings-share` | Public account details shared with Alice and Bob. |
| `27-savings-funded` | The funded script-path account and its 2-of-3 requirement. |
| `14-approval-waiting` | The phone’s approval, waiting for one Core cosigner. |
| `15-approval-sent` | The 2-of-3 payment sent, before confirmation. |
| `28-savings-confirmed` | The 2-of-3 account’s remaining confirmed balance. |

The checked-in reference stills share the [repository recording’s provenance](../videos/README.md):
`test01CreateReceiveSendConfirm`, source
[`809c383`](https://github.com/winnowwallet/winnow/commit/809c38313c1262b0526e24870bea2d144a37771b),
iPhone 17 Pro simulator running iOS 26.5, 2026-09-17. The test passed with zero
failures in 213.202 seconds; the app journey measured 212.342 seconds and bank
preparation measured 0.325 seconds. The same run checked the funded destinations,
cosigner coins, accepted payments and change outputs against Bitcoin Core,
then discovered confirmation through the app.

The retained local evidence is
`recovery/shared-account-2026-09-17/video-run/`: `NodeUI.xcresult`, `node-ui.log`,
`journey.mp4`, and the 16 original PNGs in `screenshots/`. The captures come from
[WinnowAppUITests.swift](../../UITests/WinnowAppUITests.swift) and its
[MultisigJourney.swift](../../UITests/MultisigJourney.swift) continuation.
Keep replacements with the matching log, result bundle, revision, device, and
date. iPad evidence must be recorded separately.

Existing guides retain other screenshots as dated illustrations. This run does
not refresh those images, their flows, or the old `timings.json`.
A screenshot is a recorded moment, not proof that the current test passed.
PNGs use Git LFS; [check-site](../../scripts/check-site) checks referenced assets
and unresolved pointers before publishing. Follow the
[screenshot guidance](../../.github/internal/app-store-screenshots.md) when
selecting images.

## Historical capture provenance

The records below describe earlier suites. The 16 exact filenames listed above
in this repository use the September 17 recording; other images retain their earlier provenance.
Historical `store-*.png` candidates
were retired with the 0.7.0 one-screen interface and showed the four-tab layout.

Earlier Send captures (`05`, `07`, and `08`) came from
[app revision d02ffa3](https://github.com/winnowwallet/winnow/commit/d02ffa314d198f4759069e8398d84bb8a50f19d2).
All 16 app journeys passed in [this UI run](https://github.com/winnowwallet/winnow/actions/runs/34171647009),
including editing a payment, keeping custom fees out of beginner mode, opening
payment diagnostics, and following Bitcoin Core confirmation.
The [run artifact](https://github.com/winnowwallet/winnow/actions/runs/34171647009/artifacts/10036468223)
contains the original captures, log, and result bundle.

Earlier Receive and account captures (`03`, `10`, and `11`) came from
[app revision 4559ecd](https://github.com/winnowwallet/winnow/commit/4559ecd150b2f3399f0b4613cce9db689bcb2d51).
Those captures were taken locally on 2026-09-08 with an iPhone 17 Pro
simulator running iOS 26.5 against a disposable signet node.
All 16 app journeys passed in that run, along with the app unit tests.
The local evidence is `recipients-final-ui.xcresult` and
`winnow-recipients-final-ui.log`.
That recipient journey covered saving, renaming, restarting, removing and re-adding,
then paying through Send. That extra-device journey used Bitcoin Core as the other
signer and covered setup, review, interruption and restart, both approvals, the
sent receipt, and restoring the pre-payment backup to find the remaining balance.

The earlier saved-recipient review (`25`) and
extra-device captures (`35` through `39`) came from
[app source c5dd3c1](https://github.com/winnowwallet/winnow/commit/c5dd3c1ce7b5f14eb12326f1ce5afae77bb37f81).
Those captures were taken locally on 2026-09-08 with an iPhone 17 Pro
simulator running iOS 26.5 against a disposable signet node.
All 16 app journeys passed, along with 148 XCTest cases and 8 Swift Testing tests.
The local evidence is `one-send-final-ui.xcresult` and
`winnow-one-send-final-ui.log`; originals are in `one-send-final-screenshots`.
Those ordinary, shared, and phone-plus-Core journeys used the same Send form and
review. Shared payments continued directly to approvals. That Core journey also
checked leaving and restarting the signing exchange, the completed payment, and
restoring the earlier backup to find the remaining balance.

The sender-label captures (`40-save-sender`, `41-send-to-person`, and
`43-infer-sender`) are unchanged originals captured locally on 2026-09-13 with an
iPhone 17 Pro simulator against the disposable custom signet fixture, from the
`feature/people-labels` working tree. The `senders` and `sender-lookup` journeys
both passed in the same run (`winnow-kimi-t1718.xcresult`), covering the revealed
funding address attaching with its warning, the label persisting across a
restart, paying the sender back, and the warned loopback-explorer inference for
a taproot key-path payment.

The peer-reset capture (`42-peer-reset`) is an unchanged original captured
locally on 2026-09-13 with an iPhone 17 Pro simulator against the disposable
custom signet fixture, from the `feature/peer-reset` working tree. The `network`
journey's reset scenario passed in the same run (`winnow-kimi-t19.xcresult`):
the remembered good peers are forgotten and the manual fixture peer dials back.

The 0.7.0 captures (`01-onboarding`, `06-send-review`, `24-saved-recipient`,
`27-shared-payment-review` and `56-home-beginner`, which replaced
`23-settings-beginner` when beginner mode lost Settings) were captured locally
on 2026-09-15 with an iPhone 17 Pro simulator
running iOS 26.5, from the `ui/one-screen` working tree. The signet fixture was recreated from the CI template
(`scripts/signet-fixture up` with `WINNOW_FIXTURE_TEMPLATE`) before the
first-wallet captures. The iPhone and iPad first-wallet stories share the
fixed-entropy wallet, so `56-home-beginner`, taken after both, shows two of
each payment. All
four stories passed on that tree: the first-wallet, paying-people and
shared-savings stories in full, and the devices-and-network journeys that
touch Settings or backup (05, 09, 19, 20, 21); the first-wallet and
paying-people stories also passed on an iPad Pro 11-inch simulator. The
local evidence is `final2-fw.xcresult` and `final2-fw-b.xcresult`
(first-wallet), `one-pp3.xcresult` (paying-people) and `one-ss4.xcresult`
(shared-savings) with their logs.

The Tor captures (`48-tor-stopped` through `52-tor-onion-peer`) were removed
with the embedded Tor client in 0.7.1, and the peer-refresh journey then captured
`46-peer-refresh`, recaptured by `test20PeerCatalogRefreshAndFailureRecovery`
on the `remove/tor` working tree: an unchanged
original taken locally on 2026-09-15 with an iPhone 17 Pro simulator running
iOS 26.5, against the signet fixture recreated from the CI template. The
first-wallet story and the devices-and-network journeys 05, 09, 19 and 20
passed in that run (`tor2-fw.xcresult`, `tor2-dn.xcresult` and their logs).
The removed images remain in history and on the `archive/tor-0.7.0` branch.
