# Winnow

A private, opinionated, modern Bitcoin wallet for iOS — 100% Swift, one dependency.

**[Public beta on TestFlight](https://testflight.apple.com/join/83djpNE7)** — signet by default.

- **Pure P2P by default.** The read side is BIP157/158 compact block filters served by full-node peers — no server ever learns your addresses. Bounded **mempool windows** (short full-relay subscriptions while the Receive or Send screen is open) give 0-conf payment detection and propagation tracking without any server. Design papers, framed around the phone: [design-paper index](.github/internal/design-papers.md).
- **Taproot only.** P2TR receiving (BIP86); no legacy address types, no ECDSA signing paths.
- **Two modern multisig flavors.** MuSig2 (BIP327) n-of-n vaults and script-path k-of-n (`multi_a`, BIP387/388), coordinated over PSBTv2 (BIP370/371/373).
- **Silent payments** (BIP352) are prototyped on a development branch, not here. Receiving needs a per-block tweak-data server that does not exist as public infrastructure, which is the unsolved part.
- **One runtime dependency:** [`swift-secp256k1`](https://github.com/21-DOT-DEV/swift-secp256k1) (Bitcoin Core's libsecp256k1), pinned.
- **Warned explorer links** — choose mempool.space or a custom Esplora website; Winnow opens it only after a tap and privacy warning, never as a wallet backend.

## Layout

The Bitcoin implementation lives in its own repository,
[btc-swift](https://github.com/winnowwallet/btc-swift) — keys to broadcast
in ~10,600 lines with one dependency, plus the differential battery against
Bitcoin Core, the soak driver, and a scriptable CLI. This repository is the
wallet that wears it: the app pins an exact btc-swift revision and bumps it
deliberately.

Architecture invariant: **all logic lives in the library, where it is
tested; the app target is a thin shell.** No wallet, protocol, or crypto
logic may move into `WinnowApp` — if the UI needs something, expose it from
btc-swift.

- `Sources/WinnowApp` — the iOS app (SwiftUI, iOS 17+)
- `AppTests/` — app-hosted suites (Keychain, privacy, journal redaction, …)
- `UITests/` — the simulator e2e against the signet fixture node
- `docs/` — public design papers, the security register, and the site
- `scripts/` — App Store Connect tooling and the TestFlight pipeline

## Build & test

```sh
swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # unit, protocol, vector, and story-run tests
/opt/homebrew/bin/xcodegen && open WinnowApp.xcodeproj                # iOS app
```

Default network for development is signet. Point the app at your own
filter-serving node (Settings → Manual peers); the node needs
`blockfilterindex=1` and `peerblockfilters=1`.

## License

Winnow is available under the [MIT License](LICENSE).
