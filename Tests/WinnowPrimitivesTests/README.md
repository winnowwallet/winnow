[Back to main README](../../README.md)

# WinnowPrimitives on its own

These tests depend on [WinnowPrimitives](../../Sources/WinnowPrimitives/README.md)
alone, with P256K only to verify signatures. They derive BIP86's published
addresses and build, sign and verify a key-path send the way a caller without
WalletCore would. The vector suites stay in
[Bitcoin primitive tests](../BitcoinCoreTests/README.md).

Run `swift test --filter WinnowPrimitivesTests` from the repository root.
