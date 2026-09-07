# Current selectors for historical test evidence

The September 2026 consolidation moved tests without dropping their names.
Dated findings and invariant evidence keep the commands and type names used
for those runs. To repeat a historical suite on the current tree, use
`swift test --filter` with its current suite below; a combined suite runs
additional related tests. The Xcode AppTests class names are unchanged.

| Historical SwiftPM suite | Current suite |
| --- | --- |
| `VaultFlowTests`, `VaultThresholdTests`, `PSBTMultisigTests` | `VaultSpendTests` |
| `VaultCosignerIdentityTests`, `VaultDraftIdentityTests`, `VaultSignerIndependenceTests` | `VaultAdmissionTests` |
| `SpentCoinTombstoneTests`, `ReorgRollbackTests` | `WalletReorgTests` |
| `CoinSelectionPropertyTests`, `FeePolicyTests` | `CoinSelectionTests` |
| `AntiFeeSnipingTests` | `TransactionBuilderTests` |
| `ImportBundleBoundsTests` | `ImportBundleTests` |
| `SighashBIP341ScriptPathTests` | `SighashBIP341Tests` |
| `LoopbackTests`, `FilterSyncPersistenceTests`, `FilterProgressRollbackTests`, `FilterMatchingTests` | `FilterSyncTests` |
| `CheckpointMajorityTests`, `PeerDisagreementTests`, `CrossSourceCheckTests`, `CheckpointHangupTests` | `FilterSyncAdversaryTests` |
| `PeerCooldownTests`, `StaleTipEvictionTests`, `SocksProxyTests` | `PeerPoolTests` |
| `PeerDiversityTests`, `SeedResolverTests`, `FallbackPeerListTests` | `PeerPolicyTests` |
| `MainnetCheckpointTests`, `CheckpointStartTests`, `HeaderStartPolicyTests`, `HeaderReplayTests`, `ReorgVisibilityTests` | `HeaderChainTests` |
| `HeaderStorageAppendTests`, `HeaderStorageCorruptionTests`, `HeaderStorageBoundsTests` | `HeaderStorageTests` |
| `TxBroadcasterBackoffTests`, `FeeFilterAnnouncementTests` | `TxBroadcasterTests` |
| `TxBroadcasterReorgTests` | `TxBroadcasterStoreTests` |
| `WireFormatTests`, `MessageTests`, `FramingTests` | `WireTests` |

The store-persistence cases formerly in `TxBroadcasterTests` are now in
`TxBroadcasterStoreTests`; relay cases remain in `TxBroadcasterTests`.
`MuSig2SessionSafetyTests` retains its type, now in `MuSig2Tests.swift`.
`WinnowGenerateTests` and the story/fuzz suites retain their names in the
shared `ToolsTests` target. The two Esplora/disclosure suites now belong to
`BlockchainBackendTests`, with their original names.

Historical `WinnowSoak` runs used the standalone executable. The same driver
now runs as `swift run winnow-story soak`; `winnow-generate` commands now use
`swift run winnow-story generate`. Neither command migration rewrites the
recorded dates, measurements, or scope of historical evidence.
