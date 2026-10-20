[Back to main README](../../../../README.md)

# Shared parser fuzz invariants

Exercise.swift defines seeded generation and invariants for PSBTs, descriptors,
transactions, blocks, wire messages, framing, filters, addresses, import bundles,
census documents and signatures, DNS answers, funding sources, Taproot control
blocks, and person cards/pastes. NativeSecp256k1Exercise.swift feeds one input
to both secp256k1 backends and fails on any disagreement. The
[runbook](../../README.md) lists the sixteen targets and the app-owned stores
outside this harness.
It checks hostile inputs against the same parsers used by the wallet.

The [fuzz executable](../WinnowFuzz/README.md) and
[FuzzRegressionTests](../../../../Tests/ToolsTests/FuzzRegressionTests.swift) both consume
this development-only target. Sharing the invariant avoids a separate replay
implementation that could disagree with the original failure.

Run `swift test --filter FuzzRegressionTests` for saved inputs, or follow the
[fuzz runbook](../../README.md) for a seeded campaign.
Keep invariant changes reviewable: weakening an assertion changes what both
campaigns and saved regressions can detect.
