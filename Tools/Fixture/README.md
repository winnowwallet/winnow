[Back to main README](../../README.md)

# Native signet bank preparation

`winnow-fixture` prepares the disposable signet bank before the recorded iPhone
journey. It is a host executable, outside the shipping app. It uses
[SignetFixture](../../Tests/Support/Node/SignetFixture.swift), the same helper
that the UI test uses to check readiness.

From the repository root, after starting the isolated node:

```sh
swift run winnow-fixture --help
swift run winnow-fixture prepare-bank
```

`--help` performs no node work. `prepare-bank` checks that the node reports
signet, creates or opens `ui-bank`, and mines 101 blocks if the bank lacks
sufficient mature funds. Use the configured disposable fixture, not public signet.
It reports `SIGNET_BANK_PREPARATION_SECONDS`; errors exit nonzero. Repeating it
on a prepared bank checks readiness without mining another 101 blocks.

The command reads `WINNOW_NODE_HOST` (default `127.0.0.1`), `WINNOW_RPC_PORT`
(default `38400`), `WINNOW_DATADIR` (default `~/.bitcoin-mysignet`), and optional
`WINNOW_BITCOIN_CLI`. It uses the node’s cookie for authentication. Use the same
configuration as [signet-fixture](../../scripts/signet-fixture); the
[UI runbook](../../UITests/README.md#run-locally) shows isolated local paths and ports.
This command does not start the node or simulator, run tests, or record video.

[CI](../../.github/workflows/ci.yml) invokes it in fixture initialization;
[ci-ui-journey](../../scripts/ci-ui-journey) checks the bank again before recording.
The journey validates the resulting funded payments. Hosted CI always starts
from a fresh chain; prepared-bank snapshots are only a local convenience.
