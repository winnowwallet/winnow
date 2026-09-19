# Parallel validation on tdx

GitHub Actions coordinates four single-job macOS guests. Package (8 CPU/24 GiB)
checks run independently of the build (12/32). Units (8/24) and the complete
recorded journey (16/32) boot their simulators during compilation; the journey
also prepares its fresh signet fixture. Both download the same checksummed Debug
products and generated `.xctestrun`. ARM64 Release inspection continues on the
build worker after that artifact is published. All four lanes must succeed.

Fresh PR, nightly and manual runs share one workflow-wide FIFO queue (`concurrency.queue: max`, supported
by GitHub since May 2026). Parent PR concurrency cancels superseded revisions.
Main/tag evidence lookup bypasses that queue so a verified release need not wait
for a test pool it will not use. Cache misses still queue at the controller,
which permits only one run across its four worker slots. A unique run/attempt
label prevents an ephemeral runner from accepting another run’s job.
The controller paginates pending runs independently of completed history and
selects the oldest work first. Non-PR coordinator runs have independent groups
so GitHub's single-pending default cannot discard an older main/tag request.
Fork PRs use the original hosted workflow. Test workers receive only a one-job
runner configuration and the job's read-only repository token. Signing keys
remain exclusively in the hosted release job. Validation workflows receive no
repository secrets: the outer coordinator passes only the two named Cloudflare
credentials to a separate hosted website consumer after validation succeeds.
The required aggregate also requires deployment success when deployment is expected.

## Host installation and isolation

`scripts/tdx/controller.py` is installed by an administrator on tdx2, never run
from a PR checkout on the host. Its trusted workflow allowlist, numeric job IDs,
fixed resource table and domain prefix constrain provisioning and destruction.
The seed contains Xcode 26.6 (17F113), iOS 26.5 (23F77), Python 3.12 and pinned
Actions runner 2.337.0. It has no runner registration, GitHub CLI login, private
SSH keys, wallet state or inherited user Keychain. XcodeGen is separately
checksum-pinned by `scripts/install-xcodegen`.

The separate immutable `OpenCore-autoboot-v4.qcow2` boot disk uses OpenCore
1.0.6 RELEASE with the picker and preboot hotkeys disabled. It disables the
missing SSDT-USBX table and absent VoodooPS2Controller (including its keyboard
plugin), AppleMCEReporterDisabler, USBToolBox and UTBMap kext entries; the three
present kexts remain enabled. The matching OpenCore validator accepts its config.
The boot config enables `ProvideCustomSlide`: serial diagnostics showed only
244 of 256 kernel slides are usable in the guest firmware memory map. The
unmodified random selection could choose a conflicting location and abort before
macOS, returning to the picker. OpenCore now chooses randomly among usable
locations; no fixed `slide=0`, boot retry, or test retry is used. Apple boot
logging remains enabled for diagnosis.
Its SHA-256 is part of the validation identity and the host's startup checksum
list; the original macOS/toolchain image is unchanged. Earlier rollout attempts
with interactive or incomplete boot configurations remain recorded as failures,
and do not count toward the final three successful validation trials.

Read-only base disks and per-job overlays live in a bounded 230 GiB filesystem
under `/data/OSX-KVM/winnow-ci-pool`; the remaining 10 GiB of the allowance is
headroom. New allocations require 100 GiB free on `/data` and 20 GiB within the
pool. Completed or cancelled guests are destroyed and overlays removed.
Existing winnow-1/2/3 and the retired benchmark VM are never modified.

Guest QEMU runs as dedicated UID/GID 64060. The `winnow_ci` nftables output chain
rejects new connections from that UID to host management addresses, private,
loopback and link-local networks. Only DNS port 53 on the host resolver is exempted. No host filesystem or
management socket is shared with guests. SSH port forwards bind only to host
loopback; existing connections remain usable for host control. This filter must
be loaded before starting the controller, including after host reboot.

The controller polls final GitHub job status before cleanup; it does not shut
VMs down in a job-completion hook before the runner reports its result. A failed
boot, lost worker, storage reserve failure or 70-minute worker lifetime cancels
the run and cleans the guest. A stalled cancellation is escalated once after
15 seconds; GitHub may still use its documented five-minute cancellation period
to clear a lost runner. Queued work stays queued throughout that interval.
There are no automatic test retries.

## Evidence and caches

Compilation caches include only compatible source/build products and are keyed
by role, complete test-input fingerprint, toolchain and architecture. They never
include a node data directory, wallet, Keychain, result bundle or successful test
status. Every test run creates fresh state, even when compilation is cached.

`ci-validation` records the tested commit, repository/run/attempt, fingerprint,
workflow revision, image/toolchain/runtime, lane outcomes, test inventory and
hashes of lane records and normalized media. The minimum inventory preserves
647 package tests, 219 XCTest plus 13 Swift Testing app tests, and the complete
UI journey. Changes to those tests still change the fingerprint.

Only completed successful same-repository CI/trial runs can supply evidence.
Evidence older than seven days, changed inputs/tools, failed or missing lanes,
wrong repository, mismatched attempts, missing/corrupted artifacts or lookup
errors require fresh validation. Squash commit IDs may differ; original tested
commit and recording provenance remain intact. Nightly and manual validations
always run fresh. Media is normalized once, then reused for website and release
evidence. Each new signed archive is rebuilt and checked independently.

## Rollout and fallback

Until three fresh trials of one revision pass, `TDX_CI_ENABLED` remains unset or
false and normal CI stays hosted. `tdx-trial.yml` runs the pool for the rollout
branch while preserving the hosted baseline. Rerun the complete trial workflow
three times on the final revision; never count a failed or partial attempt.
Compare test inventories, all three confirmed payments, 16 captures, continuous
video and all 20 website files before enabling the pool. Preserve the 600-second
XCTest, 15-minute journey and 30-second video-finalization limits.

After rollout, the stable required aggregate is `validation`. Set repository
variable `TDX_CI_ENABLED=false` to restore hosted CI, or select the `hosted`
option for an explicit manual fallback run. No tags or uploads are needed for
this migration. Record lane/queue/build/simulator/fixture/test/media timings for
the next 20 normal runs and compare their median and slow tail to the hosted
baseline (30m19 validation, 7m9 signing/upload/processing in v0.7.7).

App Store submission still requires the user's physical-device iCloud recovery
and subsequent signing result. CI evidence does not replace that check.
