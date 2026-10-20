[Back to main README](../../../README.md)

# Transaction signing documents

PSBT parsing and the creator, signer, combiner and finalizer roles carry the
wallet's own key-path transactions from construction to a broadcastable
transaction, and read documents from other software. Imports accept v0 and
v2; v0 is normalized to the same v2 representation, and the app exports v0
for Core. The BIP373 MuSig2 fields (participants, public nonces, partial
signatures) are read and written for key-path spends, and the roles build a
BIP327 session from them and aggregate the partials into PSBT_IN_TAP_KEY_SIG.
Script-path fields are carried as unknown pairs and never interpreted; only
PSBT_IN_TAP_KEY_SIG is signed and finalized.

[Transaction construction](../Transactions/README.md) and the
[wallet](../Wallet/README.md) consume these types.

[PSBT tests](../../../Tests/WalletCoreTests/PSBTTests.swift) cover parsing, combination,
and finalization; [MuSig2 PSBT tests](../../../Tests/WalletCoreTests/PSBTMuSig2Tests.swift)
cover the BIP373 fields and a two-signer exchange. [Fuzz regressions](../../../Tests/ToolsTests/Cases/psbt/README.md)
keep a previously problematic encoding in the ordinary test run.
Accepting a PSBT does not itself authorize its payment outputs; the app reviews those.
