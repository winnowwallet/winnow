# Public-vector provenance and notices

`xonly-validation.json` is copied without changes from
[NativeSecp256k1 at 2ef204167972efc428486e823fc79b1f1bf0e9e7](https://github.com/posix4e/native-secp256k1-swift-test/blob/2ef204167972efc428486e823fc79b1f1bf0e9e7/Tests/NativeSecp256k1Tests/Fixtures/xonly-validation.json).
Its SHA-256 is
`e2c1e6f7a544afc8b00bae9bbdc689dd0d818f872fe71da179b9605e4b0ef79c`.

It contains 318 cases (306 distinct x encodings): all 19 BIP340 public-key columns,
43 boundary cases and 256 synthetic public inputs. There are 167 expected valid
and 151 expected invalid cases. The BIP340 CSV signature-verification booleans
are not used as key-validity expectations. Each valid case includes the exact
canonical even-y coordinate, rather than merely an acceptance flag.

The first-pass research generated the expected answers outside Swift and obtained
agreement from both of these pinned oracles:

- [BIP340 Python reference at bitcoin/bips 927b6de9915c9262615a6399de51b200f81e5aa4](https://github.com/bitcoin/bips/blob/927b6de9915c9262615a6399de51b200f81e5aa4/bip-0340/reference.py).
- [libsecp256k1 v0.7.1 at 1a53f4961f337b4d166c25fce72ef0dc88806618](https://github.com/bitcoin-core/secp256k1/tree/1a53f4961f337b4d166c25fce72ef0dc88806618).

The BIP340 public-key inputs come from
[the pinned CSV](https://github.com/bitcoin/bips/blob/927b6de9915c9262615a6399de51b200f81e5aa4/bip-0340/test-vectors.csv).
Reproduction scripts and original evidence are available in the
[pinned experiment's Tools directory](https://github.com/posix4e/native-secp256k1-swift-test/tree/2ef204167972efc428486e823fc79b1f1bf0e9e7/Tools).
The app runs the Swift comparison against these saved answers; it does not run
either oracle or download reference data at runtime.

The NativeSecp256k1 original code is Apache-2.0; its license is included as
`NativeSecp256k1-LICENSE.txt`. The x-only fixture includes public-key fields from
BIP340 by Pieter Wuille, Jonas Nick and Tim Ruffing. At the pinned BIP revision,
code and test vectors are offered under BSD-2-Clause OR MIT OR CC0-1.0; this
extraction uses CC0-1.0. See the
[license declaration](https://github.com/bitcoin/bips/blob/927b6de9915c9262615a6399de51b200f81e5aa4/bip-0340.mediawiki#copyright)
and [CC0 1.0 terms](https://creativecommons.org/publicdomain/zero/1.0/legalcode).
Expected coordinates are derived numeric outputs. The external oracle source
code is not copied into this target.

The mismatch-reporting unit test separately uses the public secp256k1 generator
coordinates from [SEC 2 version 2, section 2.4.1](https://www.secg.org/sec2-v2.pdf).
That test deliberately substitutes wrong answers to verify the demo's failure
reporting. It is not a test of secret-key operations.
