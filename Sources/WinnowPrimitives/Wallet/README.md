[Back to main README](../../../README.md)

# Coin selection and fees

Coin selection, the fee policy, the consensus monetary range, and the values a
send is built from: `WalletUTXO`, `AddressChain`, `WalletError` and
`BuiltTransaction`. The wallet actor that owns balances, history and recovery
stays in WalletCore; the [topic guide](../../WalletCore/Wallet/README.md) covers
both, and their tests.
