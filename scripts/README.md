[Back to main README](../README.md)

# Build, test, and debugging entry points

These scripts connect the repository's code to Xcode, SwiftPM, disposable test
nodes, the website, reporting, and release tooling. They provide shared commands
for contributors and CI without duplicating the wallet implementation.

[The workflows](../.github/workflows/README.md) are their primary automated
consumers. [CI/release operations](../.github/internal/ci-release.md) and
[debugging](../Tools/Debug/README.md) explain how to use them.
`signet-fixture` starts disposable test nodes. Combined CI uses GitHub-hosted
Apple silicon (`macos-26`), with a fresh fixture and per-run build products.
Local development can still use an optional prepared-bank snapshot.

[ci-journey-cache](ci-journey-cache) hashes test and build inputs and finds a
successful same-repository run's reusable journey media. Website-only changes
can skip compilation and wallet tests when that evidence exists; app-bundled
HTML/CSS remains part of the inputs. Missing artifacts or API errors run fresh
checks. Manual, nightly and release runs always run fresh.

[ci-ui-journey](ci-ui-journey) builds and runs the one iPhone integration
journey against the configured signet fixture. Before simulator boot, recording,
or XCTest, it runs `swift run winnow-fixture prepare-bank` and saves the output
to `fixture-prepare.log` in the journey results directory. This native Debug
build reuses earlier SwiftPM build products. The command uses the shared
`SignetFixture`, `BitcoinCLI`, and `SignetMiner` helpers; a fresh CI fixture
still mines 101 blocks without a bank snapshot from another run.

The script records one continuous `journey.mp4` alongside the test's checkpoint
screenshots, logs, and result
bundle. The journey covers ordinary-wallet, MuSig2, and 2-of-3 payments;
Core wallets provide the other signing keys. There is no separate differential
test launcher or CI job.

Host preparation reports `SIGNET_BANK_PREPARATION_SECONDS`; XCTest's
`SIGNET_SETUP_SECONDS` now measures only chain and bank readiness checks.
CI performs mining in the existing fixture initialization step, bounded to five
minutes, and retains its output as `bank-setup.log`. The recording script then
checks readiness without mining again. The recorded journey retains its
15-minute step limit and 600-second XCTest limit.

CI's single `build` job runs package, fuzz, lint and release checks. For a fresh
test run it builds the Debug app and both test runners once, then calls
[ci-app-tests](ci-app-tests) and `ci-ui-journey` with separate fresh results
directories and `--skip-build`. Both require the shared `SIMULATOR_ID` and
`DERIVED_DATA` environment variables in this mode. Without `--skip-build`,
each script still builds what it needs for standalone local use. The recorded
journey requires the signet fixture configuration described in
[the UI test guide](../UITests/README.md).

[prepare-site-artifact](prepare-site-artifact) prepares a fresh static website
from the current docs and either `--journey <results>` or `--media <bundle>`.
`--media-output <directory>` saves the normalized movie, 16 checkpoint images,
and original recording provenance as a dedicated reusable bundle. The website
job deploys the ready same-run artifact without checking out source or rebuilding.
`--validate-media <bundle>` checks cached media before CI decides to skip wallet
tests. Invalid media falls back to fresh tests and a new recording.

[Python regressions](tests/README.md) cover media reuse, site generation,
artifact preparation, App Store status parsing, and release policy.
Signing/submission commands have external effects;
their workflow runbooks identify when they are used.
Run commands from the repository root unless their help specifies otherwise.
