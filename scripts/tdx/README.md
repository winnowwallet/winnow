Host installation is intentionally separate from GitHub workflows. Review the
controller before installing it on tdx2. Never fetch a PR's controller and execute
it automatically on the host. Deployment unit files and the network policy are
stored alongside this README; replace only the dedicated Winnow CI units.

The base image hashes in `/data/OSX-KVM/winnow-ci-pool/base/SHA256SUMS` are checked
at service startup. QEMU sees the base read-only, and all changes go into disposable
job overlays. The controller's domain-prefix guard protects pre-existing VMs.

Inspect `journalctl -u winnow-controller` for provisioning, cleanup and worker
timing. `systemctl stop winnow-controller` stops dispatch; cancel active GitHub
runs first. On restart, the controller removes orphaned pool domains. It never
retries a test failure automatically. Keep the network unit enabled on reboot.

The repository policy also permits `posix4e/fire-wallet-Josh-August26`, only its
`fork-tests.yml` workflow and only the existing `package` slot. Fire requests
`fire-tdx-package` plus `fire-run-<run_id>-<run_attempt>`; Winnow labels stay
unchanged. Both repositories share one FIFO dispatcher, process lock, role/port
table, and capacity limits. Do not start a second controller for Fire. Domain
names retain the `winnow-ci-job-` prefix so existing cleanup and host permissions
remain applicable. Every API operation, JIT configuration, cancellation and
runner deletion is scoped to the job's allowlisted repository.

Fire's workflow defaults to hosted. Its manual `runner: tdx` choice permits a
single pilot without setting its `TDX_CI_ENABLED` variable; `runner: hosted`
forces hosted execution. Enabling that repository variable later opts eligible
automatic runs into the pool. Changing it does not move already queued jobs.
Fire simulator jobs require an ARM64 simulator dependency and are excluded from
this X64 pool; signing and Linux jobs also remain on their existing destinations.

Deploy this controller only after approval, using reviewed source on main and
after active pool jobs drain. Installation/restart and the first Fire JIT
registration are separate from source review. The existing controller identity
must have access to Fire's Actions runner API; do not mint or copy credentials
as part of this change. No seed, network policy, service unit or resource-table
change is required. Test the controller without host effects with:

```sh
python3 -m unittest discover -s scripts/tests -p test_tdx_controller.py -v
```
