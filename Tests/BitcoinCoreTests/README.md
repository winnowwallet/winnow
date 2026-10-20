[Back to main README](../../README.md)

# Bitcoin primitive tests

Known-answer and adversarial tests protect the cryptographic, key-derivation,
descriptor, and script rules behind receiving, recovery, and signing.
They exercise WalletCore primitives directly so a wrong primitive is easier to locate
than through a complete app journey.

The [vectors](Vectors/README.md) provide independent
expected values; [TestSupport](../Support/README.md) supplies shared loaders.
The `NativeSecp256k1*` suites check the [native curve module](../../Sources/NativeSecp256k1/README.md)
layer by layer (integers, field, scalars and points, keys, BIP340) against
those vectors and, byte for byte, against the pinned libsecp256k1 package;
the timing suite is opt-in and asserts nothing.
The test target keeps its primitive-focused name; production has one WalletCore target.

Run `swift test --filter BitcoinCoreTests` from the repository root.
[CI](../../.github/workflows/ci.yml) runs the package suite on hosted Apple silicon.
Passing vectors demonstrate agreement on their cases, not exhaustive correctness
or completion of an independent security review.
