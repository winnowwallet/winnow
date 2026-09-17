[Back to main README](../../README.md)

# Repository checks and delivery

GitHub Actions runs the package, app, node, fuzz, website, and size-report checks
and the explicit release/submission operations. Keeping these definitions with
the code makes the checks and release inputs reviewable at the same revision.

[CI and release operations](../internal/ci-release.md) is the runbook.
The [testing guide](../../docs/testing.html) explains what each suite establishes
and how to inspect its artifacts. Release workflows reuse the ordinary checks.

Self-hosted jobs select a prepared runner by labels; machine provisioning and
runner registration are private infrastructure responsibilities, and every
machine registered with the node lane's labels joins its queue. Mining suites
stay serial within a machine, so throughput scales with the number of them.

The UI suite runs as one job per device, each executing all four stories
against one fixture, on a runner that also carries the `apple-silicon` label.
Apple silicon has a Metal device, so those captures draw the tab bars, alert
backgrounds and share sheets the Intel VMs never could ([#84](https://github.com/winnowwallet/winnow/issues/84)).
The Intel VMs keep the differential and package checks. Runner, Xcode and
Bitcoin versions are recorded in the job log.

Three rules keep the node lane's queue for real work. Pull requests reach it
only when they target `main` — a stacked pull request re-runs the tree its
base is already running, and it is picked up when retargeted after its base
merges. Pull requests run the iPhone journeys; iPad joins them for main
pushes, the nightly and confirmed manual runs.
[node-tests.yml](node-tests.yml) owns only the disposable
test node through [signet-fixture](../../scripts/signet-fixture).
Inspect the exact run and job conclusions; skipped jobs are not fresh evidence.
