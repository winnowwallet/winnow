[Back to main README](../../README.md)

# Repository checks and delivery

GitHub Actions runs the package, app, fuzz, and website checks
and the explicit release/submission operations. Keeping these definitions with
the code makes the checks and release inputs reviewable at the same revision.

[CI and release operations](../internal/ci-release.md) is the runbook.
The [testing policy](../../docs/testing.md) explains each suite's scope and
evidence requirements. Release workflows reuse the ordinary checks.

The combined CI build uses GitHub-hosted Apple silicon (`macos-26`). Each job
gets its own runner, per-run build directory, and disposable signet fixture.
No developer Mac or private runner registration is required.

The [CI workflow](ci.yml) has one `build` job and a reusable `website` job.
The build job owns lint and test gates, package and debugging tests, fixed fuzz
smoke, dependency and provenance checks, and the app's Debug and Release checks.
It builds the Debug app and both test runners once,
then runs app unit tests and the recorded UI journey with `test-without-building`.
It also checks the Release build, resolved dependencies, warnings and exclusion
of test controls from the shipping app. The UI suite runs one iPhone journey through ordinary-wallet, MuSig2, and
2-of-3 receive, send, and confirmation against one signet fixture. Core wallets
supply the other signing keys. There is no separate
architecture lane, differential target, selector job, complexity job, or LOC job.
Runner, Xcode and Bitcoin versions are recorded in fresh test logs.

Same-repository pull requests, main pushes, manual runs and release calls include
the signet journey. Fork pull requests use the same hosted Apple silicon image
without the fixture, UI journey, or deployment credentials. Fresh runs install
their tools and prepare a new bank; they do not reuse a local machine's Xcode
build products, simulator, or prepared fixture. For
website-only edits, [ci-journey-cache](../../scripts/ci-journey-cache) matches
test and build inputs to a successful same-repository run's normalized media
artifact. After validating its manifest and file checksums, the build job skips compilation and wallet tests while preparing
and checking a fresh website. Changes to HTML/CSS bundled in the app still
require fresh app CI. Missing or invalid artifacts, download failures, or API errors run the full checks;
manual, nightly and release runs always run fresh. iPad is deferred until the
iPhone baseline is manageable. The build job owns only the disposable test node through
[signet-fixture](../../scripts/signet-fixture).
[ci-ui-journey](../../scripts/ci-ui-journey) records one continuous video and
retains checkpoint screenshots, test logs, and the Xcode result bundle together.
The `app-tests-<run-id>-<attempt>` artifact contains `debug-build.log`, `units/`,
`journey/` and `release-build.log`; the journey directory includes `journey.mp4`.
Inspect the exact run and test-step conclusions; reused media is not fresh test evidence.

[prepare-site-artifact](../../scripts/prepare-site-artifact) assembles the
current website with a new journey or cached video and all 16 checkpoints,
preserving the recording's source provenance. It also writes a dedicated
reusable media bundle. [site.yml](site.yml) downloads the ready website artifact
from the same run and deploys it without checkout, rebuilding, or testing.
Trusted PRs use `pr-<number>` previews; `main` is production. The retained
[LOC reporter](../../scripts/report-loc.py) is a manual tool.
