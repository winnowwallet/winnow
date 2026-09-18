[Back to main README](../../../../README.md)

# Private chain scanning

FilterSync asks peers for compact filters and retrieves matching blocks.
It lets the wallet find its confirmed payments without sending its addresses
to a remote indexer. Persisted progress and reorg rollback keep recovery usable.
A batch's filter headers must agree with the adopted cfcheckpt answer before
any matches are delivered. A checkpoint rejection therefore has no payment
callbacks or saved progress from that batch. A later filter, network, or
callback error can follow earlier delivered matches; the scan frontier is
saved only after all chunks finish.

Saved progress keeps sparse checkpoint boundaries plus recent filter headers,
rather than every block’s filter header. Boundary storage still grows with the
chain. Each batch persists the pinned headers a later check can ask for: every checkpoint boundary, which
the cfcheckpt comparison reads on every sync, and the recent run a reorg could
rewind into, which ends at the anchor the next batch checks a peer's answer
against. Keeping that anchor is the condition, not the goal — with no anchor to
keep, nothing is pruned at all.

A batch of up to 1000 blocks stays the span peers are cross-checked over and
the span progress is saved after, but its filters are requested a chunk at a
time and matched as each chunk lands, so a scan holds one chunk rather than a
whole batch. A caller that cannot run to the tip in one go passes `maxBlocks`
to bound a single run; the next one resumes from the saved frontier.

[The app](../../../WinnowApp/AppModel.swift) coordinates scanning with
[wallet state](../../Wallet/README.md),
[headers](../Headers/README.md), and
[peer selection](../Peers/README.md).

[FilterSync tests](../../../../Tests/WalletCoreTests/Network/FilterSyncTests.swift) and
[adversarial peers](../../../../Tests/WalletCoreTests/Network/FilterSyncAdversaryTests.swift)
exercise verification, damaged progress, disagreement, and rollback.
The [UI journey](../../../../UITests/README.md) discovers and confirms ordinary
and shared-account payments through the real signet node's filters.
