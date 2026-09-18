[Back to main README](../../../../README.md)

# Verified block history

HeaderChain and its work arithmetic verify header links, proof of work, and
difficulty rules, persist progress, and report chain reorganizations.
Balances and confirmations need a validated chain to refer to.
Headers and cumulative work remain in memory. Normal sync appends at the tip;
an older parent is found by searching the headers backwards once per batch.
This avoids a second full-chain hash index, at the cost of slower lookups for
old or unknown parents. Memory still grows with the retained history.
Difficulty adjustments are calculated during sync, reorgs, and reloads. The
mainnet checkpoint is at 959,616, a difficulty-period boundary, so the first
adjustment at 961,632 and every later one can be checked exactly. Headers more
than two hours ahead of the device clock are refused. This light client does
not check median-time-past or full block consensus rules.

[Filter scanning](../Filters/README.md) uses this
history. [Checkpoint generation](../../../../Tools/Generate/README.md) uses the same
validation code for the app's faster initial synchronization.

[HeaderChain tests](../../../../Tests/WalletCoreTests/Network/HeaderChainTests.swift) cover
forks, difficulty, checkpoints, and real header replay.
[Difficulty tests](../../../../Tests/WalletCoreTests/Network/HeaderDifficultyTests.swift)
compare Core's fixed answers and real mainnet adjustments, and reject wrong
targets in incoming batches, replacement branches, and saved files.
[Storage tests](../../../../Tests/WalletCoreTests/Network/HeaderStorageTests.swift) cover
corruption and recovery. Checkpoint assumptions and independent-review limits
remain documented in the [security evidence](../../../../docs/security/README.md).
