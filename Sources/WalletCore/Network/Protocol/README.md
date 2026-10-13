[Back to main README](../../../../README.md)

# Bitcoin wire formats and network parameters

Messages, framing, blocks, transactions, peer addresses, and network constants
provide the byte formats shared by wallet networking, signing, and debugging.
Transactions, the integer encodings, SHA256d and the network identifier are in
[WinnowPrimitives](../../../WinnowPrimitives/Protocol/README.md); keeping the P2P
messages in WalletCore avoids a separate P2P package boundary.

[Transport](../Transport/README.md),
[scanning](../Filters/README.md), and
[transaction construction](../../../WinnowPrimitives/Transactions/README.md) use them.
[Wire tests](../../../../Tests/WalletCoreTests/Network/WireTests.swift),
[transaction tests](../../../../Tests/WalletCoreTests/Network/TransactionTests.swift), and
[network-parameter tests](../../../../Tests/WalletCoreTests/Network/NetworkParamsTests.swift)
cover encoding, parsing, and network selection.

Peer discovery lives in [Peers](../Peers/README.md); no peer-address list is compiled into the app.
