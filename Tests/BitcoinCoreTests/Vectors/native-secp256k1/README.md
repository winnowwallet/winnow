[Back to main README](../../../../README.md)

# Native secp256k1 fixtures

Known answers for the field arithmetic, square roots, x-only key validation,
key parsing, tweaks, BIP340 signatures and verification verdicts in
[NativeSecp256k1](../../../../Sources/NativeSecp256k1/README.md). Every
expected value was computed outside the Swift code under test: field answers
with Python arbitrary-precision integers, every curve answer by two
independent oracles that had to agree, the BIP340 reference implementation
and a C probe over libsecp256k1. The files hold hand-picked edge cases and a
few seeded samples each; broad random coverage is the fuzz harness's job,
whose `native-secp256k1` target checks the module's own algebra on every CI
run. The first three files began in the research package
[posix4e/native-secp256k1-swift-test](https://github.com/posix4e/native-secp256k1-swift-test);
all nine were regenerated on 2026-10-20 with the pinned oracles below, when
the `swift-secp256k1` package left the repository and its live differential
tests became these recorded ones.
[NativeSecp256k1FieldTests](../../NativeSecp256k1FieldTests.swift),
[NativeSecp256k1CurveTests](../../NativeSecp256k1CurveTests.swift),
[NativeSecp256k1KeyTests](../../NativeSecp256k1KeyTests.swift) and
[NativeSecp256k1SchnorrTests](../../NativeSecp256k1SchnorrTests.swift) load
them through [Vectors.swift](../../../Support/Vectors.swift).

| File | Cases | Expected values from |
|---|---|---|
| `field-arithmetic.json` | 290 pairs: each of 40 edge values against six partners (0, 1, 977, 2⁶⁴ − 1, p − 2³², p − 1) and squared, plus 16 SHA-256-derived pairs; sum, product and negation modulo p | Python `%`, `*` and `pow` on integers |
| `field-roots.json` | 56 values: 40 edge plus 16 derived; the even square root, or none for a non-residue | Python `pow(value, (p + 1) // 4, p)` with a squaring check |
| `xonly-validation.json` | 78 x-only inputs: all 19 public-key columns of the official BIP340 CSV, 43 boundaries, 16 derived; the even y, or none when x ≥ p or x³ + 7 has no root | The pinned BIP340 `reference.py` `lift_x` and a C probe over libsecp256k1 `secp256k1_xonly_pubkey_parse`, required to agree |
| `private-keys.json` | 17 secrets: zero, one, n − 1, n, n + 1, all ones, three wrong lengths and 8 derived; the compressed public key, x-only key and parity, or none | `reference.py` `point_mul`, and `secp256k1_ec_seckey_verify`, `ec_pubkey_create` and `xonly_pubkey_from_pubkey`, required to agree; a length other than 32 is invalid by the shape of both APIs |
| `public-keys.json` | 55 encodings: 8 derived x values under the prefixes 00, 02, 03, 04 and ff, six boundary values under 02 and 03, and three wrong lengths; the canonical compressed form, or none | `reference.py` `lift_x` and `secp256k1_ec_pubkey_parse`, required to agree |
| `tweaks.json` | 52 (secret, tweak) pairs: 8 derived secrets each with a derived tweak, zero, one, n − 1, n and n − secret, plus 4 tweaks that negate the even key; the private, x-only private, public and x-only public results, or none | `reference.py` point arithmetic, and `secp256k1_ec_seckey_tweak_add`, `keypair_xonly_tweak_add`, `ec_pubkey_tweak_add` and `xonly_pubkey_tweak_add`, required to agree |
| `xonly-tweaks.json` | 89 x-only inputs (the 78 validation inputs, 8 derived keys, p, p + 1 and all ones), each with a derived tweak, zero, one, n − 1 and n; the tweaked x and parity, or none | `reference.py` `lift_x` and point arithmetic, and `secp256k1_xonly_pubkey_tweak_add`, required to agree |
| `schnorr-signatures.json` | 12 derived secrets signing messages of 0, 1, 17, 32 and 100 bytes, half under zero auxiliary input and half under derived input | `reference.py` `schnorr_sign` and `secp256k1_schnorrsig_sign_custom`, required to agree |
| `schnorr-verification.json` | 102 verdicts: 6 recorded signatures, one per message length, each as made and under sixteen mutations (flipped signature bits, message and key; r = p; s = n; swapped halves; 63 and 65 bytes; another key; a 31-byte key; an extended message) | `reference.py` `schnorr_verify` and `secp256k1_schnorrsig_verify`, required to agree; a signature or key length the C API cannot take is invalid |

Each file is a JSON array with one case per line.

The CSV's signature-validity column is deliberately not used as a key-validity
answer: an invalid signature can still carry a valid key. The derived inputs
come from a fixed SHA-256 domain (`winnow-public-field-v1`); they are public
test data, not randomness, and no secret in these files may ever hold value.

Pinned sources: bitcoin/bips `927b6de9915c9262615a6399de51b200f81e5aa4`
(`bip-0340/reference.py` SHA-256
`4b1d4ad9e60820df4a6d239733d52b014bc03e4c47afd757a2fe4d3b586d892c`,
`bip-0340/test-vectors.csv` SHA-256
`34c9d1d9c3a88d524bc80778540dc43f8306ec249a7485293063c376db851c2d`) and
bitcoin-core/secp256k1 `1a53f4961f337b4d166c25fce72ef0dc88806618` (v0.7.1).
Nothing in the repository links libsecp256k1; these files are the only form
in which its answers reach the tests.

SHA-256 of the fixture files as generated:

```
dcbf9d8ee6d3979562b4fb95dba6b69aa031e515a1ac6782fbe641049f698678  field-arithmetic.json
2a4444a597a80391fd2d4e90ad33e3e0a3a16be67d09ed222183b75bd8c3acbc  field-roots.json
0702eb421a8c532b0578e698e88cbb814469a89db82a320831ae45e4918bc8bb  private-keys.json
c251e1f9b04ac0b160e70b2f3f8087e4c1623b8d3f8b7ce7cd08d69a6860850d  public-keys.json
a9b9e3a65a7b8910ad6791a97f351eb4d850018400d7529faddb14f831fd8185  schnorr-signatures.json
9c267ad0a3d87a9ed969ba96ddcc53ce90f7e0c007a962182f49dd29171d06db  schnorr-verification.json
896c34c86a775d89e631a0dc9e8e74c5201d4757585b5b006878168776f846a2  tweaks.json
15d3f987356417337e6cc82efe9d2a423d8ad68b0b7b9c60fcb6694d784ec7a8  xonly-tweaks.json
5f7f3a0f79e9b0f43f825da4c161a060de635d2b8cb15cb716b1fa5eff20fae5  xonly-validation.json
```

Regeneration is optional and reproducible from fresh pinned checkouts with
the scripts in [Tools/Generate/native-secp256k1](../../../../Tools/Generate/native-secp256k1/README.md);
a deterministic rerun must produce byte-identical files. As with the other
[reference data](../README.md), do not regenerate expected values with the
implementation being tested.
