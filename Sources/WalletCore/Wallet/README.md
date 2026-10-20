[Back to main README](../../../README.md)

# Wallet state and spending policy

Balances, coin selection, fees, recovery imports and people live here. They
supply the state and decisions behind receiving, sending and recovery; the
GUI should not carry a second wallet implementation.

[AppModel](../../WinnowApp/AppModel.swift) coordinates these rules with
WalletCore networking, [key storage](../Keys/README.md), and
[signing](../Transactions/README.md). An import bundle written by a Winnow
that held shared accounts is refused rather than restored without them.

[WalletCore tests](../../../Tests/WalletCoreTests/README.md) cover balances, selection,
imports, people, and reorg recovery. [App tests](../../../AppTests/README.md)
check persistence and protected actions; the [UI journey](../../../UITests/README.md)
checks the complete user flow.
