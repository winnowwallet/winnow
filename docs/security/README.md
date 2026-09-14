[Back to main README](../../README.md)

# Security claims and their evidence

The findings register, invariant matrix, gate reports, audit manifest, and device
captures explain which wallet properties have been examined and what remains open.
They keep release decisions tied to observations rather than undocumented confidence.

[The audit manifest](audit-manifest.md) identifies evidence,
while [the findings register](findings.md) records results and
remaining work. [The testing guide](../testing.html) explains suite limits.
Raw [soak observations](evidence/README.md) remain separate from
the interpretation written in the reports.

[The independent review of 2026-09-14](independent-review-2026-09-14.md) is
the first pass by a reviewer that wrote none of the code — an agent engaged by
the owner, not yet the uninvolved human auditor the gate report names as open.
Its findings are tracked as GitHub issues #98–#130 and fixed in bounded pull
requests. [The gate report](gate-report.md) records the owner's mainnet
decision of 2026-09-14 above the August record it revises.

These are dated records. Preserve their tested revisions and provenance when
adding newer observations; do not silently turn an old result into current status.
Tests, logs, and physical-device observations support particular claims, not a
blanket assertion that the wallet has completed independent review.
