[Back to main README](../../../README.md)

# Descriptors

Descriptors turn a public key expression into the addresses a wallet or a
person is paid at: `tr(KEY)`, `rawtr(KEY)` and `tr(KEY,TREE)` with BIP380
origins and checksums and BIP389 multipath suffixes. Trees hold `pk`,
`multi_a` and `sortedmulti_a` leaves (BIP386, BIP387) and the two timelocked
miniscript leaves a recovery path uses, `and_v(v:pk(KEY),older(N))` and
`and_v(v:multi_a(k,KEY,…),older(N))`, and are bounded at
BIP341's 128 levels, so a hostile descriptor cannot exhaust the parser's stack.
A key-path KEY may also be a BIP390 `musig(KEY, KEY, ...)` with its own
derivation suffix, resolved through BIP327 key aggregation and the BIP328
synthetic xpub; `musig()` beside a tree or inside another `musig()` fails at
the parse.

The [wallet](../Wallet/README.md), [people](../Wallet/People.swift) and the
[offline inspector](../../../Tools/Debug/README.md) consume this WalletCore code.
It describes derivation; it does not own app state or peers.

[Descriptor tests](../../../Tests/BitcoinCoreTests/DescriptorTests.swift) and
[parser bounds](../../../Tests/BitcoinCoreTests/DescriptorBoundsTests.swift) cover
derivation, malformed input, refused forms, the tree depth bound and origin
bounds; [BIP387 tests](../../../Tests/BitcoinCoreTests/BIP387Tests.swift) run the
BIP's own `multi_a` vectors and
[BIP390 tests](../../../Tests/BitcoinCoreTests/BIP390Tests.swift) the
published `musig()` vectors.
