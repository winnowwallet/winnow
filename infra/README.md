# Dedicated node integration

The monorepo's `node-tests.yml` runs the Core differential suite followed by
app simulator UI tests on one dedicated disposable custom signet. It is
available through confirmed manual dispatch and the Release workflow. Normal
PR checks are hosted and require no node.

The Winnow runner has labels `self-hosted, macOS, btc-swift, node-e2e` (the
existing `btc-swift` label is retained for runner compatibility). It needs
Swift, full Xcode with an iPhone simulator, and `bitcoin-cli`/`bitcoin-util`.
The workflow never provisions or rewrites a node during a test run.

Repository variables `WINNOW_DATADIR`, `WINNOW_RPC_PORT` and `WINNOW_P2P_PORT`
select the runner's fixture. Unset values use `~/.bitcoin-mysignet`, RPC 38400
and P2P 38401, with localhost and cookie authentication. Provision once with
`scripts/signet-fixture up` under the corresponding environment. Never point
these at a personal wallet or share the fixture with another mining runner.

Both suites consume `Tests/NodeSupport`; the node workflow serializes them,
cleans up simulator miners after failures, and uploads logs, results and fresh
screenshots. Generated screenshots go to the artifact directory, leaving
committed website screenshots alone.

[Runner provisioning](runner/README.md) documents registering a replacement.
The optional `fixture/` Docker setup is for a separate host with explicit RPC
authentication; it is not the localhost/cookie layout used by the workflow.
