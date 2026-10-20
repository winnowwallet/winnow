[Back to main README](../../../README.md)

# Descriptors

Descriptors turn a public key expression into the addresses a wallet or a
person is paid at: `tr(KEY)` and `rawtr(KEY)` with BIP380 origins and
checksums and BIP389 multipath suffixes. KEY may also be a BIP390
`musig(KEY, KEY, ...)` with its own derivation suffix, resolved through BIP327
key aggregation and the BIP328 synthetic xpub. Script trees and multisig
leaves are not grammar here; such text fails at the parse.

The [wallet](../Wallet/README.md), [people](../Wallet/People.swift) and the
[offline inspector](../../../Tools/Debug/README.md) consume this WalletCore code.
It describes derivation; it does not own app state or peers.

[Descriptor tests](../../../Tests/BitcoinCoreTests/DescriptorTests.swift) and
[parser bounds](../../../Tests/BitcoinCoreTests/DescriptorBoundsTests.swift) cover
derivation, malformed input, refused multi-key forms and origin bounds;
[BIP390 tests](../../../Tests/BitcoinCoreTests/BIP390Tests.swift) run the
published `musig()` vectors.
