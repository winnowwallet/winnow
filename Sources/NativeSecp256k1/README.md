[Back to main README](../../README.md)

# Native secp256k1

A pure-Swift implementation of the secp256k1 operations the wallet's BIP86
keys and Taproot multisig accounts need: scalar arithmetic modulo the group order, field arithmetic
modulo the curve prime, point addition and scalar multiplication, x-only and
compressed key encodings, BIP32-style key tweaks, BIP340 signing and
verification, and the BIP340 tagged hash. It depends only on Foundation and
CryptoKit (for SHA-256).

WalletCore's key derivation, Taproot tweaks, signer and PSBT finalizer are the
consumers. A script-path multisig signature is an ordinary BIP340 signature
with an untweaked key over the script-path sighash, so multisig accounts need
nothing more from this module. MuSig2, ECDSA and ECDH are out of scope: the
module implements exactly the operations those paths call, with the same
inputs, outputs and failure cases as the libsecp256k1 wrapper it replaces.

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

Field, scalar, point, key and signature tests check known answers computed
outside this module: the [native-secp256k1 fixtures](../../Tests/BitcoinCoreTests/Vectors/native-secp256k1/README.md)
(Python integer arithmetic, and key, tweak, signature and verification
answers recorded from libsecp256k1 and the BIP340 reference implementation,
which had to agree), the official BIP340 vectors, and the BIP32, BIP86 and
BIP341 vectors already used by WalletCore. BIP340 signatures must match the
recorded ones byte for byte under a fixed auxiliary input. The repository
links no second curve implementation, so the recorded fixtures hold edge
cases and random inputs go to the fuzz harness: its `native-secp256k1` target
checks the module's own algebra on every input (the private and public forms
of each operation agree, fresh signatures verify and altered ones do not). The fixture generators live in
[Tools/Generate/native-secp256k1](../../Tools/Generate/native-secp256k1).

## Speed

`WINNOW_TIMING=1 swift test -c release --filter NativeSecp256k1TimingTests`
prints microseconds per operation for the native module; it asserts nothing.
On an Apple silicon Mac, release build, with the fixed-base generator table
(the libsecp256k1 column was measured once, on 2026-10-19, through the
since-removed `swift-secp256k1` wrapper):

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
