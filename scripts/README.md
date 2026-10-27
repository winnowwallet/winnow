[Back to main README](../README.md)

# Scripts

- [install-xcodegen](install-xcodegen) downloads and verifies XcodeGen 2.46.0, which generates the
  app's Xcode project (`LeanApp/ios/project.yml`).
- [build-ios](build-ios) builds the Lean app from a clean checkout: Lake, ElmLean's `ios_lean_sources.sh`,
  XcodeGen and xcodebuild (`build-ios <Debug|Release> [iossim|ios]`; `PREPARE_ONLY=1` stops before xcodebuild).
- [check-no-swift](check-no-swift) fails on any Swift source, Swift compile step or Swift library in the app.
- [verify-release-no-test-mode](verify-release-no-test-mode) launches the Release and Debug simulator builds
  with test mode's environment: Debug must start the test run, Release must ignore it.
- [ios-simulator](ios-simulator) prints one available iPhone (default) or iPad on the newest iOS runtime.
- [signet-fixture](signet-fixture) provisions a disposable custom-signet bitcoind (`up`, `down`, `status`,
  `snapshot DIR`, `destroy`). For a regtest node with a funded wallet, use `LeanApp`'s `backend-test --fixture <dir>`.
- [import-census](import-census) fetches the census's `census/peers.json` at a census commit (default: its
  `main`) into `build/census/`, the peer list the app ships. Run it before XcodeGen.

Run commands from the repository root unless their help specifies otherwise.
