# Fixed public-vector research demo

`CryptoResearchDemo.run()` compares 318 bundled public x-only key encodings with
precomputed acceptance and exact even-y answers. The public API accepts no input.
It runs at utility priority, propagates cancellation to its worker, and checks
cancellation between cases. One field calculation already running may complete
before cancellation is observed. Results are immutable and `Sendable`.

The only cryptography dependency is the experimental NativeSecp256k1 product,
pinned to `2ef204167972efc428486e823fc79b1f1bf0e9e7`. This target has no dependency
on WalletCore, VaultKit or P256K. Its report must never control key admission,
signature verification, transaction construction, signing or spending. It does
not process wallet data, network input or secret material.

All expectations were copied byte-for-byte from the independent research fixture;
Swift does not regenerate expected answers. Missing, malformed, truncated or
duplicate-named reference rows throw an error. Comparison disagreements are
returned as failed cases and include both expected and observed coordinates.
The tests pin the exact JSON SHA-256 and exercise acceptance/coordinate mismatches,
resource failures and cancellation. See the bundled `Fixtures/PROVENANCE.md`.

Passing these cases establishes agreement on this finite dataset only. It does
not establish constant-time behavior, production readiness, a security audit or
full BIP340 signature verification. NativeSecp256k1's arithmetic is variable time
and suitable only for public-data research. The app continues to use P256K for its
wallet cryptography.

Run the targeted package tests with:

```sh
swift test --build-system native --filter CryptoResearchTests
```

The native build-system flag is a local workaround for the research host's
generated-resource codesigning problem. Swift 6.4 deprecates that flag; it is not
a requirement or a claim about the Xcode iOS distribution build.
