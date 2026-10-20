[Back to main README](../../../README.md)

# Native secp256k1 fixture generators

These scripts regenerate the
[native-secp256k1 fixtures](../../../Tests/BitcoinCoreTests/Vectors/native-secp256k1/README.md)
from independent oracles. Ordinary `swift test` reads the checked-in JSON and
needs none of this; the regeneration path needs Git, Python 3 and Clang and
fetches two public repositories at exact commits. Neither C nor Python is a
build dependency of the app.

From the repository root:

```sh
sh Tools/Generate/native-secp256k1/reproduce_oracles.sh /absolute/path/to/new-scratch-directory
```

The scratch directory must not already exist. The script clones bitcoin/bips
at `927b6de9915c9262615a6399de51b200f81e5aa4` and bitcoin-core/secp256k1 at
`1a53f4961f337b4d166c25fce72ef0dc88806618`, compiles
[xonly_oracle.c](xonly_oracle.c) against that libsecp256k1, and runs
[generate_vectors.py](generate_vectors.py), which rewrites the three JSON
files in place. A deterministic rerun is byte-identical; review any
difference before committing it.

The Python generator checks that both checkouts are at the pinned commits
with no tracked changes, computes field answers with integer arithmetic
modulo p, and takes x-only answers only where the BIP340 reference `lift_x`
and the C probe agree on validity and on the exact even y coordinate. It
never calls the Swift implementation. The C probe parses each x with
`secp256k1_xonly_pubkey_parse`, parses the even compressed point separately,
and fails if the two disagree.

The scripts were written for the research package
[posix4e/native-secp256k1-swift-test](https://github.com/posix4e/native-secp256k1-swift-test)
and copied here with only the output location changed.
