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
those vectors, byte for byte against answers recorded from libsecp256k1;
the timing suite is opt-in and asserts nothing. `NativeSecp256k1ReferenceTests`
also hold field and scalar arithmetic to the fuzz core's independent
[reference implementation](../../Tools/Fuzz/Sources/WinnowFuzzCore/ReferenceSecp256k1.swift)
on operands built from structured limbs (all ones, the top bit, the limbs of p
and n), which reach carries and reductions that random values do not.
the timing suite is opt-in and asserts nothing.
`NativeSecp256k1ArithmeticTests` checks the public scalar and point arithmetic
MuSig2 uses; `MuSig2Tests` runs the BIP327 vectors and the session-safety
refusals on it, and `BIP390Tests` the published `musig()` descriptor vectors.
The test target keeps its primitive-focused name; production has one WalletCore target.

Run `swift test --filter BitcoinCoreTests` from the repository root.
[CI](../../.github/workflows/ci.yml) runs the package suite on hosted Apple silicon.
Passing vectors demonstrate agreement on their cases, not exhaustive correctness
or completion of an independent security review.
