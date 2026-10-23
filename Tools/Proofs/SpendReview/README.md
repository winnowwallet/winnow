[Back to main README](../../../README.md)

# Spend review specification

An executable specification of `MultisigAccount.reviewSpend` in Lean 4,
proofs about it, and a generator for the fixture the Swift is checked
against. Lean is needed only to change the specification or regenerate the
fixture; the Swift package never builds or links any of it.

| File | What it holds |
|---|---|
| `SpendReview/Model.lean` | `review` and the checks it makes, in the Swift's order |
| `SpendReview/Theorems.lean` | what an accepted review guarantees, proved |
| `SpendReview/Generate.lean` | seeded scenarios and the JSON writer |
| `Main.lean` | `spend-review-vectors`, which writes the fixture |

The toolchain is pinned in `lean-toolchain` (Lean 4.35.0, core only: no
Mathlib, no Batteries). With [elan](https://github.com/leanprover/elan)
installed, from this directory:

```sh
lake build
.lake/build/bin/spend-review-vectors 1500 1 ../../../Tests/WalletCoreTests/Vectors/spend-review-specification.json
```

`lake build` checks every proof and builds the generator. The command
rewrites the committed fixture byte for byte; it prints how many vectors
end in each outcome. `SpendReviewSpecificationTests` builds the real
account, coins and PSBT for each vector and requires `reviewSpend` to show
the same outputs, totals, fee and path, or to refuse for the same reason at
the same input or output.

## What is proved

About the model, for every input (`Theorems.lean`): an accepted review shows
every PSBT output in order with its amount and script; its fee is the known
input amounts less every output, between zero and a tenth of the inputs;
an output is marked as the account's own exactly when a caller-supplied
coordinate with choice 0 or 1 derives its script; every input spends a
distinct known coin with that coin's amount and script, the account's
internal key and exactly its leaves, under a hash type that commits to
every output; the recovery path is taken exactly when the account has one
and every input meets its lock, so a mix is the signers' path; and a
recovery-path review spends only unlocked coins. Nothing else a PSBT says
about an output, such as BIP371 metadata calling it change, changes what
review returns. Conversely (`review_complete`), a spend that meets every
stated rule is accepted, so review refuses only for a reason it names; a
co-signer's BIP326 spend that mixes sequences is one of them.

The proofs use the standard axioms only (`propext`, `Quot.sound`, and
`Classical.choice` through `omega` and `simp`); `#print axioms` on any
theorem shows it.

## What is assumed

- Names stand for bytes. A script, key or leaf is named by its coordinate
  or a foreign tag, so distinct coordinates are taken to derive distinct
  bytes and foreign values to collide with nothing. Derivation itself, the
  tap tree and BIP341 hashing are outside the model.
- The model is the specification; that the Swift computes the same function
  is tested on the fixture, not proved.
- A PSBT keys leaf entries by control block, so the model never holds the
  same leaf twice.
