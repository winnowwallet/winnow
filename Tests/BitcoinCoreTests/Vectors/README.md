[Back to main README](../../../README.md)

# Reference data for Bitcoin primitives

These copies of Bitcoin specifications and known-answer data anchor derivation,
signatures, descriptors, and encoding tests to expected values outside Winnow.
The nested [BIP327 vectors](bip327/README.md) cover MuSig2.

`core-miniscript-v31.0.json`, `core-taproot-descriptors-v31.0.json` and
`core-wsh-descriptors-v31.0.json` are Bitcoin Core's own test rows, extracted
without change from `src/test/miniscript_tests.cpp` and
`src/test/descriptor_tests.cpp` at tag `v31.0`: every `Test(...)` row with its
`TESTMODE_*` flags and the script hex it states per context, and every `tr()`
and `wsh()` `Check(...)` and `CheckUnparsable(...)` row with its scriptPubKeys
or Core's refusal. `bip-0382.mediawiki` and `bip-0383.mediawiki` are from
bitcoin/bips at `927b6de9915c9262615a6399de51b200f81e5aa4`. The Liana
descriptors in [DescriptorTests](../DescriptorTests.swift) are copied, checksums
included, from the tests in its `liana/src/descriptors/mod.rs` (wizardsardine/liana
master, 2026-10-18).

[Primitive tests](../README.md) load named resources through
[Vectors.swift](../../Support/Vectors.swift). SwiftPM copies this directory
into the test resource bundle; it is not shipped with the app.

Keep the specification text and reference data intact. When refreshing a dataset,
record its upstream source and revision in the change, then run
`swift test --filter BitcoinCoreTests`. Do not regenerate expected values with
the implementation being tested. These are fixed examples, not live network data.
