[Back to main README](../../../../README.md)

# Shared parser fuzz invariants

Exercise.swift defines seeded generation and invariants for PSBTs, descriptors,
transactions, blocks, wire messages, framing, filters, addresses, import bundles,
census documents, DNS answers, funding sources, Taproot control
blocks, and person cards/pastes. NativeSecp256k1Exercise.swift feeds one input
to the native secp256k1 module and fails when the private and public forms of
an operation disagree, a signature verifies where it must not, or any key,
tweak, parse, signature or verdict differs from ReferenceSecp256k1.swift. That
second implementation shares none of the module's algorithms (32-bit limbs,
Montgomery multiplication, binary extended Euclid, affine points, BIP340 from
the specification), so a mistake the module makes consistently still shows.
Half the inputs are shaped toward values just below the group order or the
field prime and toward long runs of ones and zeros. The
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
