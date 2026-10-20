[Back to main README](../../../../README.md)

# Native secp256k1 fixtures

Known answers for the field arithmetic, square roots and x-only key
validation in [NativeSecp256k1](../../../../Sources/NativeSecp256k1/README.md).
Every expected value was computed outside the Swift code under test: field
answers with Python arbitrary-precision integers, x-only answers by two
independent oracles that had to agree. The files were generated on
2026-10-19 in the research package
[posix4e/native-secp256k1-swift-test](https://github.com/posix4e/native-secp256k1-swift-test)
and copied here unchanged; [NativeSecp256k1FieldTests](../../NativeSecp256k1FieldTests.swift)
loads them through [Vectors.swift](../../../Support/Vectors.swift).

| File | Cases | Expected values from |
|---|---|---|
| `field-arithmetic.json` | 2,624 pairs: all 1,600 combinations of 40 edge values plus 1,024 SHA-256-derived pairs; sum, product and negation modulo p | Python `%`, `*` and `pow` on integers |
| `field-roots.json` | 168 values: 40 edge plus 128 derived; the even square root, or none for a non-residue | Python `pow(value, (p + 1) // 4, p)` with a squaring check |
| `xonly-validation.json` | 318 x-only inputs (306 distinct): all 19 public-key columns of the official BIP340 CSV, 43 boundaries, 256 derived; the even y, or none when x ≥ p or x³ + 7 has no root | The pinned BIP340 `reference.py` `lift_x` and a C probe over libsecp256k1 `secp256k1_xonly_pubkey_parse`, required to agree |

The CSV's signature-validity column is deliberately not used as a key-validity
answer: an invalid signature can still carry a valid key. The derived inputs
come from a fixed SHA-256 domain (`winnow-public-field-v1`); they are public
test data, not randomness.

Pinned sources: bitcoin/bips `927b6de9915c9262615a6399de51b200f81e5aa4`
(`bip-0340/reference.py` SHA-256
`4b1d4ad9e60820df4a6d239733d52b014bc03e4c47afd757a2fe4d3b586d892c`,
`bip-0340/test-vectors.csv` SHA-256
`34c9d1d9c3a88d524bc80778540dc43f8306ec249a7485293063c376db851c2d`) and
bitcoin-core/secp256k1 `1a53f4961f337b4d166c25fce72ef0dc88806618` (v0.7.1),
which is separate from the `swift-secp256k1` package the test targets link.

SHA-256 of the fixture files as copied:

```
cfe1d21d4dabf6ce628e29b7ef1c9dd00454cc4d9edae9126aaaeff4a67d31f2  field-arithmetic.json
79e2684a8fd4d35cd8df6930cb20295101626746f2b967200c258c1b452cfb86  field-roots.json
e2c1e6f7a544afc8b00bae9bbdc689dd0d818f872fe71da179b9605e4b0ef79c  xonly-validation.json
```

Regeneration is optional and reproducible from fresh pinned checkouts with
the scripts in [Tools/Generate/native-secp256k1](../../../../Tools/Generate/native-secp256k1/README.md);
a deterministic rerun must produce byte-identical files. As with the other
[reference data](../README.md), do not regenerate expected values with the
implementation being tested.
