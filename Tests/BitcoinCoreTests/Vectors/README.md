[Back to main README](../../../README.md)

# Reference data for Bitcoin primitives

These copies of Bitcoin specifications and known-answer data anchor derivation,
signatures, descriptors, and encoding tests to expected values outside Winnow.
The nested [native-secp256k1 fixtures](native-secp256k1/README.md) hold
independently computed field, square-root and x-only answers for the Swift
curve module. [bip327](bip327/README.md) holds the MuSig2 BIP's own JSON
vectors.

[Primitive tests](../README.md) load named resources through
[Vectors.swift](../../Support/Vectors.swift). SwiftPM copies this directory
into the test resource bundle; it is not shipped with the app.

Keep the specification text and reference data intact. When refreshing a dataset,
record its upstream source and revision in the change, then run
`swift test --filter BitcoinCoreTests`. Do not regenerate expected values with
the implementation being tested. These are fixed examples, not live network data.
