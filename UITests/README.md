[Back to main README](../README.md)

# One wallet journey on signet

`WinnowAppUITests.test01CreateReceiveSendConfirm` is the single integration
journey, recorded continuously on iPhone: create a wallet in Simple mode,
receive test coins, review and send a payment, and see its receipt confirm on
a real signet node. [WinnowAppUITests.swift](WinnowAppUITests.swift) owns the
payment and the fixture readiness checks. The journey is one test result.

Two smaller classes share the bundle.
[PeerGatewaySettingsUITests.swift](PeerGatewaySettingsUITests.swift) checks the
Advanced peer-network controls and their persistence across relaunch with a
disposable wallet; CI runs it with the journey.
[LiveGatewayDeviceTests.swift](LiveGatewayDeviceTests.swift) skips unless
`scripts/check-live-gateways-ui` selects it on a device or simulator whose
network is on the tailnet running both [gateways](../docs/peer-gateways.md).

Before XCTest starts, `scripts/ci-ui-journey` runs
`swift run winnow-fixture prepare-bank` on the host. The command uses the shared
`SignetFixture`, `BitcoinCLI`, and `SignetMiner` helpers to mature the bank's
coins. XCTest only checks the chain and ready balance before launching the app.

The disposable private signet fixture funds the address read from the app
and mines blocks automatically for prompt confirmation. The app must discover
the funded balance, and the transaction Core accepts must match the reviewed
payment and fee. The app then discovers confirmation and shows the remaining
balance. This exercises the actual UI payment path; the signature under it is
the native Swift secp256k1 module, so a confirmed send here is also the
module's acceptance test on a real node.

The app’s periodic scan runs every three seconds under E2E configuration; the
journey never drags to refresh. Each launch pins a fresh test seed so repeated
runs do not share coins. Paste buttons read the existing test control file.
Detailed cases belong in `AppTests` and `WalletCoreTests`: labels, backup state,
fee rules, signing invariants, privacy, and network recovery. This journey does
not establish every feature’s UI behavior or hardware-wallet compatibility.
There is no iPad UI job currently.

The scroll helper waits for text to materialize before reading its accessible
label. Controls and screenshot balances explicitly require their whole frame
clear of navigation, tab bars, and the keyboard before use.

## Video, screenshots, and timing

The host records the whole test invocation as `journey.mp4` using H.264.
Recording starts after compilation and host bank preparation, and stops after
the test finishes. The scheme turns off automatic video capture; the host video
and explicit checkpoint screenshots remain enabled. Assertions, the log, and
the result bundle establish whether the run passed.

The source contains 6 captures, attached to the result bundle and copied to
`WINNOW_SCREENSHOT_DIR`: `01-onboarding`, `03-receive`, `56-home-beginner`,
`06-send-review`, `08-send-confirmed`, `09-home-after-send`. They are taken at
screens the journey already visits. CI normalizes the continuous video after
successful tests and retains all 6 checkpoints in wallet evidence. The public
website is maintained in winnowwallet/website and still describes the earlier
sixteen-checkpoint journey of the shared-account Winnow.

`SIGNET_BANK_PREPARATION_SECONDS` measures host bank preparation, logged in
`bank-setup.log` in CI or `fixture-prepare.log` in standalone runs.
`SIGNET_SETUP_SECONDS` measures XCTest's fast chain and bank readiness checks;
`SIGNET_ORDINARY_SECONDS` measures the app journey. Xcode reports overall test
execution separately. GitHub-hosted CI starts a fresh fixture and mines the
bank's initial 101 blocks before recording and XCTest; its preparation and
total runtime must be measured from the hosted run. CI prepares the bank in
its five-minute fixture initialization step. The recording step retains its
15-minute limit and XCTest retains its 600-second execution limit.

## CI

The main [CI workflow](../.github/workflows/ci.yml) runs this journey inside its
single `build` job alongside package, fuzz, lint/test gates and release checks.
One Debug `build-for-testing` prepares the app and test bundles;
app unit tests and the journey then use `test-without-building` with the same
simulator and build directory. There is no separate node workflow or second
Debug build. A release build follows the tests.

The build job uses GitHub-hosted Apple silicon (`macos-26`) with per-run
DerivedData and a fresh disposable signet fixture. It needs no developer Mac
or persistent local caches. Fork pull requests use the same hosted image for
app checks without the fixture or UI journey.
Manual, nightly and release calls always run fresh tests. The `app-tests-…`
artifact from a fresh run contains unit evidence
under `units/` and journey evidence under `journey/`: `NodeUI.xcresult`,
`bank-setup.log`, `fixture-prepare.log`, `node-ui.log`, `journey.mp4`, `video.log`, and
`node-screenshots/`.
On exit, the recorder script also saves the app's E2E event journal as
`story-events.jsonl` and Core's network debug log as `node.log` when available.
Missing diagnostics do not change the test result.

`scripts/ci-journey-cache` can skip build and wallet test steps for website-only
changes when a successful same-repository run has matching test/build inputs
and a retained normalized media artifact. App-bundled HTML/CSS changes still
force fresh tests; absent evidence or API errors also run fresh.

## Run locally

Use the same fixture tooling as CI, with dedicated local ports and a new
results directory. Keep local simulator runs serial: they share the simulator
environment file and fixture ports. GitHub-hosted CI runs independently.
The script prepares the bank automatically, using an incremental native Debug
build of `winnow-fixture`. For a direct Xcode test run, run
`swift run winnow-fixture prepare-bank` first with the same exported node
environment variables.

```sh
set -o pipefail
RESULTS_DIR=$(mktemp -d /tmp/winnow-ui-XXXXXX)
export WINNOW_NODE_HOST=127.0.0.1 WINNOW_RPC_PORT=38700 WINNOW_P2P_PORT=38701
export WINNOW_DATADIR="$RESULTS_DIR/fixture"
export WINNOW_SCREENSHOT_DIR="$RESULTS_DIR/screenshots"
export WINNOW_FIXTURE_TEMPLATE="$HOME/Library/Caches/winnow-signet-template"
test ! -e "$HOME/.winnow-node.env" || exit 1
scripts/signet-fixture up
mkdir -p "$WINNOW_SCREENSHOT_DIR"
env | grep '^WINNOW_' > "$HOME/.winnow-node.env"
trap 'rm -f "$HOME/.winnow-node.env"; scripts/signet-fixture down' EXIT
xcodegen
SIMULATOR_ID=$(scripts/ios-simulator iPhone) \
  scripts/ci-ui-journey "$RESULTS_DIR"
```

After the first successful run, the stopped fixture can be saved with
`scripts/signet-fixture snapshot "$HOME/Library/Caches/winnow-signet-template"`
while `WINNOW_DATADIR` still identifies it. Future local runs can copy that
prepared bank into their own fixture; hosted CI starts fresh. Keep the original
result bundle, screenshots, and source revision with runtime measurements.
