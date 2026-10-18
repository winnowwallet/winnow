[Back to main README](../../../README.md)

# Descriptors and shared signing

Descriptors turn public key expressions into the addresses and spending policies
used by wallet imports and shared savings. MuSig key aggregation and MuSig2
sessions support the advanced jointly signed vault flow.

A `tr()` leaf or a `wsh()` body is a `Descriptor.Leaf`: one of the four multisig
forms Bitcoin Core keeps at the descriptor level (`multi_a`, `sortedmulti_a`,
`multi`, `sortedmulti`) or a [miniscript](Miniscript.swift), Core's structured
policy language ported from its `src/script/miniscript.h`: the grammar
([MiniscriptParser](MiniscriptParser.swift)), the type system
([MiniscriptProperties](MiniscriptProperties.swift)), the opcode and stack
analysis ([MiniscriptLimits](MiniscriptLimits.swift)), the compiler and the
canonical text ([MiniscriptScript](MiniscriptScript.swift)). A miniscript leaf
must pass Core's sanity gate, non-malleable, every path signed, no timelock mix,
no repeated key, within the resource limits and satisfiable, or the descriptor
does not parse. Nothing signs or satisfies a miniscript leaf yet, and a vault
still admits only its two shapes.

The [wallet and vault code](../Wallet/README.md) and
[offline inspector](../../../Tools/Debug/README.md) consume this WalletCore code.
It describes policies and signing operations; it does not own app state or peers.

[Descriptor tests](../../../Tests/BitcoinCoreTests/DescriptorTests.swift),
[parser bounds](../../../Tests/BitcoinCoreTests/DescriptorBoundsTests.swift), and
[MuSig2 tests](../../../Tests/BitcoinCoreTests/MuSig2Tests.swift) cover derivation,
malformed input, known answers, and session safety.
[Miniscript tests](../../../Tests/BitcoinCoreTests/MiniscriptTests.swift) hold the
engine to Core's own vectors in both script contexts, and
[Core descriptor vectors](../../../Tests/BitcoinCoreTests/CoreDescriptorTests.swift),
[BIP382](../../../Tests/BitcoinCoreTests/BIP382Tests.swift) and
[BIP383 tests](../../../Tests/BitcoinCoreTests/BIP383Tests.swift) hold `wsh()` and
the leaves to Core's and the BIPs' scriptPubKeys. The [UI journey](../../../UITests/README.md)
uses Core wallets as the other signers for MuSig2 and 2-of-3 payments.
