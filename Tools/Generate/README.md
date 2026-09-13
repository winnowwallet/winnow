[Back to main README](../../README.md)

# Release-path generators

`winnow-debug generate` produces two constants the app ships and that `swift test`
cannot: the mainnet fallback-peer list (#161), which needs the published census
artifact (or, from-crawl, the live network), and the mainnet header checkpoint
(#89), which needs a 77 MB genesis-validated header file. Both used to be test
suites gated behind environment variables no workflow set, so they never ran.
These commands share the `winnow-debug` debugging executable, outside the
shipping app. Their sources live in `Tools/Debug/Sources/WinnowDebug`; this
directory retains the generator runbook.

Run from the repository root:

```sh
swift run winnow-debug generate --help
scripts/generate-fallback-peers
scripts/refresh-checkpoint ~/…/mainnet/headers.bin [height]
```

`fallback-peers` re-verifies the winnow-census CI's `peers.json` offline.
That crawler descends from the btcnodes snapshot and re-crawls mainnet
continuously; the artifact records a schema version, the day the census was
taken, its recorded tip, and clearnet/tor/i2p candidate lists. With no
`--from-census URL-OR-PATH` the published artifact is fetched; a local path
reads a file. An artifact that is not schema v1 or is more than seven days
old is refused outright. Every clearnet entry is then checked against the
invariants the committed list is held to — public IP literal, port 8333, one
per /16 by the pool's own `netblock` rule, and a reported height within
`PeerPool.staleTipTolerance` of the artifact's tip in *either* direction (a
peer ahead of the tip is on another chain, not a fresher one) — before
`Sources/WalletCore/Network/Protocol/FallbackPeersGenerated.swift` is
rewritten. The tor and i2p lists are parsed into the same model but rendered
nowhere: no transport can dial them yet. The run fails rather than shipping
fewer than `--floor` peers, and the log stays the release artifact.

`--from-crawl` keeps the pre-census input as a fallback: it crawls mainnet
starting from the DNS seeds. Seed results seed the dial queue, and every peer
that verifies is sent one `getaddr`; the `addr` reply queues more candidates.
Gossiped candidates are dialled only when they advertise NODE_COMPACT_FILTERS,
sit on the default port and are public IP literals, so most dials reach a peer
that could actually be listed — the handshake (the same `PeerConnection` the
app uses, which refuses any peer not advertising NODE_COMPACT_FILTERS) remains
the authoritative check. The crawl keeps one peer per /16, drops peers more
than `PeerPool.staleTipTolerance` behind the median reported tip, is bounded
by `--max-dials` (default 4000) so it terminates, and honours `--target`.
Generation is deliberately not reproducible in either mode; keep the log.

`checkpoint` truncates a genesis-rooted `headers.bin` to the wanted height
and loads the copy through `HeaderChain` itself, so every header is
proof-of-work-checked by the code the app runs, then prints the constant as a
paste-ready literal for `NetworkParams.swift`. It then proves the shipped
claim in-process: a chain started from the derived checkpoint connects the
next 2,000 real headers and must reach the same tip, height and cumulative
work as the genesis-rooted chain; disagreement exits non-zero. `--vector-out`
writes those 2,000 headers, one per line as hex, which is how
`Tests/WalletCoreTests/Vectors/mainnet-headers-900001-902000.txt` is made and
how `HeaderChainTests` replays real headers past the checkpoint on every
CI run. Deriving the chainwork itself still needs the full file, so that part
remains release-time only.

The default output path is found from `#filePath`, so it lands in the
checkout the tool was built from whatever the working directory. Selection,
filtering and rendering are pure functions; `swift test` covers them offline
in `Tests/ToolsTests/GenerateTests.swift` alongside the library suites.
