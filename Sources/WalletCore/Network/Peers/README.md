[Back to main README](../../../../README.md)

# Peer discovery and selection

The wallet needs reachable peers and a way to compare their answers.
Seed resolution, diversity rules, pooling, and peer persistence live together
here so discovery and admission follow one policy.

[FilterSync](../Filters/README.md) and
[AppModel](../../../WinnowApp/AppModel.swift) consume the pool.
The pool tries manual peers, previously connected peers, and a fresh signed
census downloaded through Advanced → Refresh peer list, then DNS seeds.
There is no bundled list. Fresh installs use DNS discovery unless a manual
peer is configured. Invalid or expired census caches do not prevent DNS
bootstrap. DNS uses DoH first, with system DNS when DoH yields no usable
addresses. The source ceiling remains: DNS alone can occupy two of the
three default slots; a manual peer or census provides another source.

[Peer policy tests](../../../../Tests/WalletCoreTests/Network/PeerPolicyTests.swift) cover
source classes, address ranges, persistence, and DNS replies.
[Pool tests](../../../../Tests/WalletCoreTests/Network/PeerPoolTests.swift) exercise
connection behavior. Diversity rules reduce concentration; they do not prove
that apparently different public peers have independent operators.
