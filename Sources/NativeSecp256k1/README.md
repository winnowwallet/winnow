[Back to main README](../../README.md)

# Native secp256k1

A pure-Swift implementation of the secp256k1 operations the single-key BIP86
wallet needs: scalar arithmetic modulo the group order, field arithmetic
modulo the curve prime, point addition and scalar multiplication, x-only and
compressed key encodings, BIP32-style key tweaks, BIP340 signing and
verification, and the BIP340 tagged hash. It depends only on Foundation and
CryptoKit (for SHA-256).

WalletCore's key derivation, Taproot tweaks, signer and PSBT finalizer are the
consumers. MuSig2, script-path multisig, ECDSA and ECDH are out of scope: the
module implements exactly the operations the ordinary receive and send path
calls, with the same inputs, outputs and failure cases as the libsecp256k1
wrapper it replaces.

## Limits

The arithmetic is **variable-time** and secrets are **not zeroized**. Timing
and memory contents may depend on private keys and nonces. This is a
deliberate first-version trade-off recorded in the main README; a later pass
would replace the conditional subtractions, the per-bit branch in scalar
multiplication and the secret-indexed table lookup with constant-time
selects, and clear the scalar copies made while signing and tweaking.

Every operation rejects malformed input by throwing or returning `nil`; none
traps. Taproot output-key tweaks run on control blocks taken from incoming
transactions, so that property is load-bearing.

## Tests

Field, scalar and point tests check known answers computed outside this
module: the [native-secp256k1 fixtures](../../Tests/BitcoinCoreTests/Vectors/native-secp256k1/README.md)
(Python integer arithmetic and a libsecp256k1 x-only oracle), the official
BIP340 vectors, and the BIP32, BIP86 and BIP341 vectors already used by
WalletCore. Differential tests compare every public operation with the pinned
`swift-secp256k1` package, which test targets keep for that purpose and for the
signet miner; BIP340 signatures must match byte for byte under a fixed
auxiliary input. The fuzz harness's `native-secp256k1` target feeds one input
to both backends and fails on any disagreement. The fixture generators live in
[Tools/Generate/native-secp256k1](../../Tools/Generate/native-secp256k1).

## Speed

`WINNOW_TIMING=1 swift test -c release --filter NativeSecp256k1TimingTests`
prints microseconds per operation for both backends; it asserts nothing. On
an Apple silicon Mac, release build, with the fixed-base generator table:

| Operation | Native | libsecp256k1 |
|---|---|---|
| k·G | 37 µs | 11 µs |
| BIP32 public child | 52 µs | 19 µs |
| Taproot tweak | 50 µs | 22 µs |
| BIP340 sign, including its self-check | 271 µs | 26 µs |
| BIP340 verify | 207 µs | 18 µs |

Address derivation, the operation the wallet repeats (gap-limit lookahead on
every sync), stays within three times the C library. Signing and verifying
happen once per spent input and are dominated by the generic point
multiplication in verification; a windowed method there and a binary field
inversion are the next levers if they ever matter.
