[Back to main README](../../README.md)

# Repository checks and delivery

GitHub Actions runs the package, app, node, fuzz, website, and size-report checks
and the explicit release/submission operations. Keeping these definitions with
the code makes the checks and release inputs reviewable at the same revision.

[CI and release operations](../internal/ci-release.md) is the runbook.
The [testing guide](../../docs/testing.html) explains what each suite establishes
and how to inspect its artifacts. Release workflows reuse the ordinary checks.

Self-hosted jobs select a prepared runner by labels; machine provisioning and
runner registration are private infrastructure responsibilities, and every VM
registered with the node lane's labels joins its queue. Mining suites stay
serial within a VM, so throughput scales with the number of VMs.
The full iPad UI suite uses the standard `macos-latest` Apple silicon runner and
installs the Homebrew Bitcoin CLI tools for its disposable fixture. Intel VMs
retain the iPhone, differential and package checks. The iPad lane moved after
the Intel simulator's compositor aborted in `CA::OGL::Context::push_surface`
during background transitions; the privacy assertions and ordered suite remain
unchanged. Runner, Xcode and Bitcoin versions are recorded in the job log.

Three rules keep the node lane's queue for real work. Pull requests reach it
only when they target `main` — a stacked pull request re-runs the tree its
base is already running, and it is picked up when retargeted after its base
merges. Pull requests run the iPhone journey only; the iPad journey, the
longest job, runs for main pushes, the nightly and confirmed manual runs. And
the app's Tor framework is restored from the Actions cache, keyed on every
input to its build, instead of being compiled from Rust source in every job;
a restored framework still has its license evidence and recorded lockfile
hash re-checked.
[node-tests.yml](node-tests.yml) owns only the disposable
test node through [signet-fixture](../../scripts/signet-fixture).
Inspect the exact run and job conclusions; skipped jobs are not fresh evidence.
