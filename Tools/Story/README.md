# Winnow operator tooling

This development target drives a resumable acceptance journey through the real Winnow
app and verifies its transaction and media evidence. It uses public signet
peers. The storefront screenshot test uses the local signet fixture; each
runner retains its existing purpose and neither reruns the library test suite.

Run from the app checkout:

```sh
scripts/winnow-story help
scripts/winnow-story doctor
scripts/ci-story
```

The [runbook](../../.github/internal/story-run.md) covers start/resume,
checkpointing, signing roles, evidence verification and media review. Use
the wrapper for story commands: it keeps the app project, generated build,
and `.build/winnow-story/runs/` state rooted in the app checkout even when
invoked from another working directory.

The target belongs to the root Winnow package. `swift test` runs its offline
tests, `Tests/ToolsTests/StoryCLITests.swift`, alongside the library suites.
`scripts/ci-story` verifies the wrapper's environment checks from outside the
checkout.
These checks do not start a story, launch a wallet, fund transactions or publish
evidence. The public-signet journey and human media review remain manual.

The source, test coverage and runbook were consolidated from revision
`3eb34e2a349a5552d37f4d558414cd04f4e2db15` of the former story repository.
Existing local runs remain in that checkout's ignored `.build/winnow-story/`
directory. To resume one here, copy its chosen run directory to this app's
`.build/winnow-story/runs/` with permissions preserved and without overwriting
an existing run. Keep the original until the resumed run has been verified.

## Generators and network soak

The package builds three executables: `btc-swift` (offline), `winnow-story`
(the operator tool), and `WinnowFuzz` (the sanitizer harness). Story commands
and `.build/winnow-story/runs/` retain their existing names and format.

| Former command | Current command |
| --- | --- |
| `swift run winnow-generate …` | `swift run winnow-story generate …` |
| `swift run WinnowSoak …` | `swift run winnow-story soak …` |

The two former executable products are removed. The generator scripts keep
their names; see the [generator runbook](../Generate/README.md). Neither new
subcommand needs `--run`, a story state directory, or a simulator.

```sh
scripts/winnow-story generate --help
scripts/winnow-story soak --help
scripts/winnow-story soak --network signet --minutes 30 --out /tmp/signet-soak.jsonl
```

The soak still runs the read path against live peers, with synthetic watch
scripts, optional persisted headers/filter progress/peers, and the same JSONL
samples. It defaults to public signet, three peers and one sample per minute;
`--minutes 0` (or omission) runs until interrupted. Help exits successfully
without connecting; invalid soak options retain exit status 2. Existing
historical soak evidence remains valid for the driver that produced it.

`ToolsTests` now links this one executable plus the fuzz core. All 17 generator
tests and the story tests remain; operator tests cover dispatch and soak
options. CI also exercises both help paths through the wrapper and in release.
