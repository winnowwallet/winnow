# Releasing the Swift Lightning research app

Use `WinnowLightning` / `ResearchRelease` for the existing
`com.btcswift.lightning` app (App Store Connect app `6815392502`). It uses the
`Winnow-Lightning-SwiftV2` storage namespace, device-only keys and no iCloud
entitlement. Keep the older application's files intact. Never import a legacy
PQLN journal into this engine.

Fresh installations now default to mainnet; existing regtest state is preserved
and the network picker is enabled. Mainnet uses real bitcoin. Record public-peer
and monitor-startup evidence separately from funded-channel/payment evidence.
Do not describe regtest interoperability runs as funded mainnet validation.

## Evidence before distribution

The required `CI` workflow must pass for the exact clean source commit. It
includes the ordinary Winnow checks and signet journey, independent pinned CLN
and LDK peers, recipient-never-returns recovery, and the recorded Swift app
journey. The latter captures actual SIGKILLs, independent provider receipts,
funding, exact Apple Share/Copy bytes, offline settlement, restored history and
cooperative close returning funds to the Winnow wallet. It also pays a BOLT11
invoice from Simple mode, cancels review before approval, verifies the independent
receipt, and restores its payment history once after restart. The CLI gates use
unchanged released Core Lightning `v26.06.8` at `6f741afc395c66d200429ea477d29df4d974748d`.
For macOS UI only, that stock daemon loads a separately built HSM with the exact
one-file [upstream PR9564 fd-lifetime patch](https://github.com/ElementsProject/lightning/pull/9564),
pinned at `d03657d3ee118a96d346c6a1faaefce7dead6e1c`, through its supported
`--subdaemon=hsmd:PATH` option. The patch is unmerged and unreleased; its UI result
must not be described as unmodified-release interoperability. The original
manifest and BOLT11 receipt bind the released base, patch and actual HSM source
and binary hashes. All other stock daemon bytes and version checks stay intact.

Run the same recorded journey on iPad and with accessibility text before release.
Use `SIMULATOR_ID`, `DERIVED_DATA` and `scripts/ci-lightning-ui`; each run needs a
fresh results directory. `--skip-build` reuses the already built test bundles.
Set the simulator's text size with `xcrun simctl ui <id> content_size
accessibility-extra-extra-extra-large`, record its value, and restore it afterward.
Keep the screenshots, video, xcresult, manifest and independent receipts.

Physical-device checks may be performed after installation through the existing
internal TestFlight group. A connected development device is not required before
uploading this internal beta. Record `device_checks_deferred_to_testflight:
true`, `physical_device: false`, and leave all four physical checks `pending`;
do not relabel simulator results as physical verification. iPad and large-text
simulator evidence remain required.

On the TestFlight device, verify successful and canceled device-owner authentication
for funding, payment and close; no mutation or publication after cancellation;
exact Share/Copy bytes; and journal/key protection while the device is locked.
`LightningAppTests` checks the stored Keychain attributes and the journal's
complete file-protection class. A simulator that cannot record the protection
class explicitly skips that assertion and cannot establish physical verification.
Retain the device model/OS, source commit, observations and test results. Do not
mark these checks passed from simulated authentication.

## Encryption determination

ResearchRelease defaults `ITSAppUsesNonExemptEncryption` to YES until reviewed.
This is a conservative build default, not a legal classification. Review the
actual linked code: Lightning Noise/onion transport and storage encryption use
CryptoKit and P256K/libsecp256k1, including implementations outside the OS. A
rewrite in Swift does not itself establish an exemption. The ordinary target
also links LightningCore and needs its declaration reviewed before distributing
this change under that bundle.

[Apple's encryption guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
requires the determination to include linked libraries. Retain either a reasoned
exemption determination or the approved App Store Connect declaration belonging
to this app. Review applicable reporting and destination requirements as part
of that determination. This script does not change country availability or
create declarations from assumptions about particular countries. An upload may
precede the determination: `--upload-only` accepts `encryption.mode: pending`
with a retained, hashed inventory, omits the encryption declaration keys from
the generated release project to trigger Apple’s questionnaire, verifies upload
and processing, and stops before tester assignment. The tracked app source and
its default remain unchanged. Setting YES without an approved export code is
rejected by Apple with error 90592. It never claims an
exemption or that a processed build is available to testers. Distribution still
requires the reviewed determination or approved declaration.

## Exact-source release command

Create an evidence JSON outside the checkout. Every artifact path is relative
to that file, contained in its directory, and SHA-256 verified. For example
(the placeholders and pending values deliberately do not pass):

```json
{
  "source": "<40-character tested commit>",
  "bundle": "com.btcswift.lightning",
  "physical_device": false,
  "device_checks_deferred_to_testflight": true,
  "checks": {
    "owner_authentication": "pending",
    "cancelled_authentication": "pending",
    "file_protection": "pending",
    "exact_share": "pending",
    "ipad": "pending",
    "large_text": "pending"
  },
  "artifacts": [{"path": "review.md", "sha256": "<artifact SHA-256>"}],
  "encryption": {
    "mode": "declaration",
    "declaration_id": "<approved ASC declaration ID>",
    "reviewed_by": "<responsible reviewer>",
    "rationale": "<determination for this source and distribution>",
    "artifact": "review.md"
  }
}
```

For a reviewed exemption, use `mode: exempt` and omit `declaration_id`. The
release script sets and verifies the archive's encryption value accordingly.
For non-exempt encryption it verifies Apple's APPROVED state and app ownership,
includes its approved export code in the signed app, then links and reads back
the declaration on the exact processed build.

Set `ASC_KEY_ID`, `ASC_ISSUER_ID`, and optionally `ASC_KEY_PATH` using existing
release credentials. Do not commit or include private keys in evidence. Choose a
new version/build after inspecting the existing app. Use an output directory
outside the checkout:

```sh
scripts/release-lightning --commit <exact-green-SHA> \
  --version <version> --build <build> \
  --evidence /path/to/review/evidence.json --output /path/to/new-release
```

With neither upload flag, this signs, archives, exports and inspects the distribution
package. Add `--upload` to perform the already authorized internal rollout.
Use `--upload-only` to upload while encryption review is pending. In that mode,
use `encryption: {"mode": "pending", "artifact": "inventory.md"}` and include
the inventory in the hashed artifact list.
It verifies bundle/team/version/build, ARM64, no iCloud or Debug hooks, dependency
policy and supply-chain metadata; uploads the inspected package; waits for VALID
processing; updates What to Test; and verifies membership and tester availability
in the existing `PQLN Regtest Internal` group. It never creates a replacement app or
public beta group. `release.json` records upload, processing and verified internal
tester availability separately. Distribution is complete only when
`available_to_internal_testers` is true after the final readbacks.

Release-tooling changes need not rebuild an unchanged tested application. Pass
`--source-checkout /path/to/clean/green/app-checkout` to run committed release
tooling against the exact app commit supplied by `--commit`. Both checkouts must
be clean. The receipt records both commits and the package provenance identifies
the release-tooling commit. This does not reuse a CI result from a different app
source commit.
