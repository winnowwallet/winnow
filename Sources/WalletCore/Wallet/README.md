[Back to main README](../../../README.md)

# Wallet state and spending policy

Balances, coin selection, fees, recovery imports, people, and vault policies live
here. They supply the state and decisions behind receiving, sending, recovery,
and shared savings; the GUI should not carry a second wallet implementation.

[WalletSync](WalletSync.swift) coordinates each filter pass with wallet state
and pending broadcasts. Its rollback and match hooks include additional stores
in the same pass; verified progress survives a failed or cancelled pass.
[AppModel](../../WinnowApp/AppModel.swift) owns scheduling and the stack's
lifetime, with [key storage](../Keys/README.md) and [signing](../Transactions/README.md).
VaultRecord is shared by app persistence and the optional accounts in a wallet
backup, so there is one representation to restore. Signing keys and live
MuSig2 nonce sessions are not part of an account record.

[WalletCore tests](../../../Tests/WalletCoreTests/README.md) cover balances, selection,
imports, shared spending, and reorg recovery. [App tests](../../../AppTests/README.md)
check persistence and protected actions; [UI journeys](../../../UITests/README.md)
check the complete user flow.
