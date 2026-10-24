[Back to main README](../../../README.md)

# Native secp256k1 fixture generators

These scripts regenerate the
[native-secp256k1 fixtures](../../../Tests/BitcoinCoreTests/Vectors/native-secp256k1/README.md)
from independent oracles. Ordinary `swift test` reads the checked-in JSON and
needs none of this; the regeneration path needs Git, Python 3 and Clang and
fetches two public repositories at exact commits. Neither C nor Python is a
build dependency of the app, and the Swift package links no libsecp256k1:
these fixtures are the only form in which its answers reach the tests.

From the repository root:

```sh
sh Tools/Generate/native-secp256k1/reproduce_oracles.sh /absolute/path/to/new-scratch-directory
```

The scratch directory must not already exist. The script clones bitcoin/bips
at `927b6de9915c9262615a6399de51b200f81e5aa4` and bitcoin-core/secp256k1 at
`1a53f4961f337b4d166c25fce72ef0dc88806618`, compiles
[xonly_oracle.c](xonly_oracle.c) and
[differential_oracle.c](differential_oracle.c) against that libsecp256k1
(with its extrakeys and schnorrsig modules), and runs
[generate_vectors.py](generate_vectors.py), which rewrites the nine JSON
files in place, one case per line. A deterministic rerun is byte-identical;
review any difference before committing it. The generator records edge cases
and a small seeded sample (`SAMPLES`); random coverage belongs to the fuzz
harness, so raise the sample only for a case the edges and fuzzing miss.

The Python generator checks that both checkouts are at the pinned commits
with no tracked changes, computes field answers with integer arithmetic
modulo p, and takes every curve answer only where the BIP340 reference
implementation and the C probes agree exactly: x-only validity and the even
y coordinate, public keys and parities, the four tweak operations, BIP340
signatures over messages of several lengths, and verification verdicts for
valid, mutated and malformed signatures. It never calls the Swift
implementation. `xonly_oracle.c` parses each x with
`secp256k1_xonly_pubkey_parse`, parses the even compressed point separately,
and fails if the two disagree. `differential_oracle.c` answers one request
per line (`seckey`, `pubkey`, `seckey_tweak`, `xonly_seckey_tweak`,
`pubkey_tweak`, `xonly_tweak_secret`, `xonly_tweak`, `sign`, `verify`)
through the library's public API and exits non-zero on a malformed request,
so a broken generator can never pass as an oracle disagreement.

The first three fixtures and `xonly_oracle.c` began in the research package
[posix4e/native-secp256k1-swift-test](https://github.com/posix4e/native-secp256k1-swift-test);
the other six were added on 2026-10-20 when the recorded answers replaced the
live `swift-secp256k1` differential tests, and all nine were then cut to edge
cases plus a small sample.
