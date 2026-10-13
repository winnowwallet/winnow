[Back to main README](../../README.md)

# WinnowPrimitives

The stateless half of the Bitcoin library: keys, descriptors, scripts, coin
selection and fees, transaction construction, Taproot signing, PSBTs and the
transaction wire format. Nothing here holds wallet state or opens a connection,
so a caller can derive addresses and build and sign a send with this product
alone. WalletCore depends on it and re-exports it, so `import WalletCore` still
brings everything.

[Hashing and encodings](Crypto/README.md), [keys](Keys/README.md),
[scripts](Script/README.md), [descriptors](Descriptors/README.md),
[payments](Transactions/README.md), [PSBTs](PSBT/README.md),
[transaction wire format](Protocol/README.md) and
[selection and fees](Wallet/README.md).

The [standalone tests](../../Tests/WinnowPrimitivesTests/StandaloneSendTests.swift)
depend on this product alone. The vector suites in BitcoinCoreTests and
WalletCoreTests still cover each primitive, through WalletCore's re-export.
