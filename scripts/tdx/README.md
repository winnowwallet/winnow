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
