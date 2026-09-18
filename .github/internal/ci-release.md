# CI, release and website operations

Winnow is one repository and one release train. The root Swift package organizes
internal modules and development executables. The app, fuzz harness
and debugging tool share one `Package.swift` and one `Package.resolved`; the Swift dependency
is swift-secp256k1. Xcode resolution must match that root lockfile.

## Checks and ownership

| Workflow | When | Responsibility |
| --- | --- | --- |
| CI | PR, main push, nightly, manual, release caller | One build job owns lint/test gates, package and debugging tests, app/Keychain tests and signet UI journey, release warning and E2E exclusion gates, inspection smoke, provenance, fixed fuzz corpus, and website preparation |
| Fuzz sanitizers | Weekly or manual seed replay | Sustained address/thread sanitizer coverage; does not repeat normal suites |
| Release | New stable version tag or manual validation | Calls CI, then signs/uploads and publishes only for tag pushes |
| TestFlight recovery | Manual, exact version and build number | Finish notes/group assignment for an existing upload |
| App Store submission | Manual | Attach a processed build and optionally submit for review |
| Website | Reusable job after CI build, for trusted PRs, main and manual previews | Download and deploy the ready website artifact from the same run; no checkout, build or test steps |

CI has only `build` and `website` jobs; there are no separate selector,
complexity, architecture or size-report jobs. The build job checks out the PR
head explicitly. `scripts/ci-journey-cache` hashes the test/build inputs,
including HTML/CSS bundled in the app, and looks for normalized media from a
successful same-repository run with the same inputs. Website-only edits can
reuse that media, skip compilation and wallet tests, and still prepare and
check a fresh website. Reuse preserves the original recording's source and run;
it does not establish a new test result for the website revision. Missing
artifacts, API errors or changed inputs run fresh checks. Manual, nightly and
release calls always run fresh checks.

The single build job runs on GitHub-hosted Apple silicon with `macos-26`.
Each job gets its own Mac environment; it does not depend on a developer's
Mac mini or a registered self-hosted runner. Same-repository pull requests and
trusted push, manual, nightly and release runs include the signet journey.
Fork pull requests use the same hosted runner image for package and app checks,
without the node fixture, UI journey or deployment credentials.
The UI journey uses `Tests/Support/Node` for chain operations and Core-held
cosigner keys. The broad differential target and its separate CI job are retired.

The workflow provisions Python on every run and installs the Bitcoin Core and
video tools when a fresh journey is needed. Debug build products use a per-run
DerivedData directory. The temporary node starts from a fresh fixture through
`scripts/signet-fixture`, without a persistent prepared-bank or simulator cache.
The iPhone journey covers ordinary-wallet,
MuSig2 and 2-of-3 payments, with Core supplying the other signing keys.

The build job owns fixture setup and teardown under its temporary directory.
Test logs, checkpoint screenshots, the continuous video, and result bundles use a fresh `mktemp` evidence
directory per job so cancelled runs cannot poison a later Xcode result path; prior
wallet state and difficulty retargets cannot affect the next run. The single
`app-tests-<run-id>` artifact contains `debug-build.log`, `units/` with
`AppTests.xcresult`, `journey/` with `NodeUI.xcresult`, `journey.mp4`,
`video.log` and `node-screenshots/`, plus `release-build.log`.
The three Keychain attribute checks use the app's existing iOS test host.
They verify recorded attributes and round-trip storage; device-lock enforcement
still needs real hardware. The retired story/media workflow has no CI role;
app screenshots and video now come from the asserted UI journey through
`scripts/ci-ui-journey`.

## Release

Create a new, unused stable `vMAJOR.MINOR.PATCH` tag on the intended Winnow
commit. This is an app release, including its internal modules and tools. Existing
tags in Winnow and the archived library remain fixed; the former library's
`v0.1.0` is historical and is not Winnow's next version.

Run Release manually first to validate the checkout without signing, uploading,
assigning TestFlight groups or publishing. Release checks the generation date
recorded inside `FallbackPeersGenerated.swift`, so copying or squashing history
cannot make an old peer list appear fresh. The census observation must be no more than seven days old. Run
`scripts/generate-fallback-peers --from-census https://census.winnowwallet.com/census/peers.json` (which runs `winnow-debug generate fallback-peers`
from [Tools/Generate](../../Tools/Generate/README.md)), retain its log and
commit the result before tagging. Refreshing the header checkpoint is the same
tool's other subcommand, via `scripts/refresh-checkpoint`, and needs a
genesis-validated header file; it is a manual release-time step, not a check.
The signed app archive is checked for E2E controls and its provenance is
attached to the GitHub release.

The CI workflow is reused directly, so release definitions cannot drift into a
second copy of package/app/fuzz checks. One unfiltered Debug `build-for-testing`
builds the app and both test runners. App unit tests and the UI journey then
reuse those products with `test-without-building`, using the same simulator
and DerivedData directory. Native inspection smoke and provenance use the same
warning-checked release binary. Fuzz smoke reuses its compiled modules, while
`swift test` runs the library and debugging-tool suites together once per
run. The iOS Release build separately checks shipping compiler settings
and bundled resources.

If App Store Connect processing outlasts a release, use **TestFlight recovery**
with its exact marketing version and build number; do not upload that number
again. App Store submission remains a separate deliberate operation.

There is no separate public library product or release process. The local app
and tools change together and need no internal version bumps.

## Website

`docs/` is static HTML. `scripts/build-site` validates the journey inventory
against app-test selectors and generates the homepage and recording page;
the other pages are authored directly. The retired Advanced URLs redirect home.
The app bundles the five design papers and `site.css` directly from that directory. Edit them once.
Run `scripts/build-site` after changing journey inputs, then `scripts/check-site`
after `git lfs pull` to check local page/asset links and reject unresolved image pointers.

The CI build job runs the website regressions and calls
`scripts/prepare-site-artifact <output> --journey <results>` after a fresh
journey, or `--media <bundle>` when test inputs match retained evidence.
`--media-output <directory>` writes the dedicated reusable bundle: normalized
video, all 16 checkpoints, and `journey-provenance.json`. Reuse copies those
files unchanged into a freshly generated site. The generated `/recording` page
identifies the original source, run and media processing. `journey-media-<hash>`
artifacts last 30 days; the ready `website-<run-id>-<attempt>` artifact lasts
14 days. Expired media requires a fresh test run.

The reusable website job downloads only that run's exact named website artifact
and deploys it. It has no source checkout, generation or tests and does not run
code from the downloaded content.

Website deploys to the existing Cloudflare Pages project `winnow`, using
`CF_API_TOKEN` and `CF_ACCOUNT_ID`. Only `main` deploys production at
<https://winnowwallet.com>. Trusted PRs use `pr-<number>` previews; manually
selected non-main branches use `preview-<run-id>`;
the deployment URL appears in the Actions summary and environment. Fork PRs
validate without deployment credentials. There is no second GitHub Pages site.
