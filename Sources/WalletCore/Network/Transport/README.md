[Back to main README](../../../../README.md)

# Peer connections

PeerConnection owns the asynchronous connection to a Bitcoin peer, including
handshake and message exchange. Scanning and payment relay need this shared
transport instead of separate connections implemented by each feature.

[Peer pooling](../Peers/README.md),
[filter scanning](../Filters/README.md), and
[mempool windows](../Mempool/README.md) consume it.
Wire types live in [Protocol](../Protocol/README.md).

[FilterSync handshake tests](../../../../Tests/WalletCoreTests/Network/FilterSyncTests.swift),
[peer-pool tests](../../../../Tests/WalletCoreTests/Network/PeerPoolTests.swift), and
[wire tests](../../../../Tests/WalletCoreTests/Network/WireTests.swift) exercise it through
controlled peers. Real-network soak evidence adds observations beyond loopback tests.

Library callers such as the census may pass `socksProxy: PeerEndpoint(...)`
to `PeerConnection` to use an external, unauthenticated SOCKS5 gateway. TCP
connects to that gateway and sends the destination hostname unresolved in a
SOCKS CONNECT request before starting the Bitcoin handshake. Proxy failures
never fall back to a direct connection. Negotiation is bounded by the connection
timeout and releases the connection when cancelled.

The default is `nil` (direct TCP). The GUI wallet continues to use that default;
this API does not start Tor/I2P routers or add wallet settings. Loopback coverage
in [SOCKS tests](../../../../Tests/WalletCoreTests/Network/SocksProxyTests.swift)
checks routing, refusal, malformed replies, timeout, cancellation, and direct TCP.
