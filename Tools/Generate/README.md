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

`fallback-peers` defaults to the published [Winnow census catalog](https://census.winnowwallet.com/census/peers.json).
Use `--from-census URL-OR-PATH` to select another artifact. Winnow's census uses
BTCNodes as input and records its observation date, reference tip, and separate
clearnet, Tor, and I2P candidate lists; the wallet dials clearnet only. The generator downloads or reads the
artifact, then validates it offline with the same `CensusCatalog` policy used
by the app's **Refresh peer list** action.

Validation rejects unknown schemas, malformed or future observation dates,
observations older than seven UTC days, and input larger than 4 MiB. It
canonicalizes endpoints, rejects duplicates and non-public addresses,
and requires reported heights within 100 blocks of the reference tip in
either direction. Clearnet entries must be public IP literals on port 8333,
with at most one endpoint per IPv4 /16 or IPv6 /32. A height within the window
does not prove that a peer serves correct filters or remains reachable.

An accepted catalog generates the clearnet constant in
`Sources/WalletCore/Network/Protocol/FallbackPeersGenerated.swift`. The Tor
and I2P lists are carried through parsing and neither bundled nor dialed.
Census input retains every validated clearnet candidate; the crawl's default
96-peer target does not truncate it. The generator requires at least `--floor` clearnet
peers (default 24) before writing the output.

Selection from a fixed accepted artifact is deterministic. Generated
provenance includes the source, its SHA-256, the observation date and reference
tip, and generation time. Keep the input artifact and run log to reproduce the
selection; generation time means a later invocation need not be byte-identical.

`--from-crawl` selects bounded live discovery instead. It seeds a queue from
DNS answers and sends one `getaddr` to each peer that completes its handshake.
A missing or slow gossip reply leaves that peer verified. Candidates from
`addr` are deduplicated and queued only if they advertise
`NODE_COMPACT_FILTERS`, use the default port, and are public IP literals.
Every dial still performs the wallet's normal handshake; a service
advertisement alone is not a filter-response check.

The crawl keeps one peer per netblock, drops peers more than
`PeerPool.staleTipTolerance` behind the median reported tip, and stops after reaching
`--target` (default 96 verified candidates), spending `--max-dials` (default
4,000), or exhausting the queue. Live discovery and dial completion order can change its
result, so retain its log as well. This crawl belongs to release tooling;
the wallet's live peer pool does not crawl address gossip.

`checkpoint` truncates a genesis-rooted `headers.bin` to the wanted height
and loads the copy through `HeaderChain` itself, so every header is
proof-of-work-checked by the code the app runs, then prints the constant as a
paste-ready literal for `NetworkParams.swift`. It then proves the shipped
claim in-process: a chain started from the derived checkpoint connects the
next 2,000 real headers and must reach the same tip, height and cumulative
work as the genesis-rooted chain; disagreement exits non-zero. `--vector-out`
writes those 2,000 headers, one per line as hex, which is how
`Tests/WalletCoreTests/Vectors/mainnet-headers-959617-961616.txt` is made and
how `HeaderChainTests` replays real headers past the checkpoint on every
CI run. Deriving the chainwork itself still needs the full file, so that part
remains release-time only.

The default output path is found from `#filePath`, so it lands in the
checkout the tool was built from whatever the working directory. Selection,
filtering and rendering are pure functions; `swift test` covers them offline
in `Tests/ToolsTests/GenerateTests.swift` alongside the library suites.
