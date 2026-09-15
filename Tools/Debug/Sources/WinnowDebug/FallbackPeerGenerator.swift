import WalletCore
import Foundation
import CryptoKit

/// Generates release candidates from the canonical census artifact by default.
/// The shared validator checks schema, observation age, addresses, diversity,
/// height distance and size. Clearnet entries retain their source hash and
/// observation date. This offline validation does not probe live peers or
/// prove filter correctness; every selected wallet peer is checked again.
/// Explicit --from-crawl retains the bounded live discovery path.
enum FallbackPeerGenerator {
    /// A peer that completed the handshake, with what its version said —
    /// or, from a census artifact, an entry that re-verified offline, with
    /// what the census recorded. One shape so both inputs share the render
    /// path.
    struct VerifiedPeer: Equatable, Sendable {
        let endpoint: PeerEndpoint
        let userAgent: String
        let startHeight: Int32
    }

    struct Options {
        static let defaultOutput = "Sources/WalletCore/Network/Protocol/FallbackPeersGenerated.swift"
        /// Where the census artifact is read from when `--from-census` gives
        /// no URL or path: the winnow-census CI's published `peers.json`.
        static let defaultCensusURL = CensusCatalog.endpoint.absoluteString

        /// What feeds the run.
        enum Source: Equatable {
            /// A winnow-census `peers.json`: an http(s) URL or a local path.
            /// The default input — the crawl exists for when no usable
            /// artifact is published.
            case census(String)
            /// `census/peers.json` as committed in the census repository at
            /// this commit (`--census-commit`): fetched from GitHub at that
            /// revision, its blob id checked against the repository's tree
            /// there, and its signature verified. The release path: the
            /// bundled list then names the commit it came from.
            case censusCommit(String)
            /// The DNS-seed + getaddr crawl (`--from-crawl`).
            case crawl

            static func parse(_ arguments: [String]) throws -> Source {
                let census = WinnowGenerate.option("--from-census", in: arguments)
                let commit = WinnowGenerate.option("--census-commit", in: arguments)
                let crawl = arguments.contains("--from-crawl")
                if let census, census.hasPrefix("--") {
                    throw GenerateError.usage("--from-census needs a URL or a path")
                }
                if let commit, commit.count != 40 || !commit.allSatisfy(\.isHexDigit) {
                    throw GenerateError.usage("--census-commit needs a full 40-character commit id")
                }
                guard [census != nil, commit != nil, crawl].filter({ $0 }).count <= 1 else {
                    throw GenerateError.usage("--from-census, --census-commit and --from-crawl are three different inputs")
                }
                if let commit { return .censusCommit(commit.lowercased()) }
                return crawl ? .crawl : .census(census ?? defaultCensusURL)
            }
        }

        let source: Source
        /// Past this the returns diminish; Core's contrib/seeds filters to the
        /// same order of magnitude. Constrains a crawl only: a census artifact
        /// is already a curated selection and is kept whole.
        let target: Int
        /// Below this the run fails rather than shipping a thin list: a silent
        /// degradation is exactly what generation exists to prevent.
        let floor: Int
        /// Total dials the crawl may spend. Gossip keeps the queue full
        /// indefinitely — each verified peer offers up to 1,000 more
        /// candidates — so without a cap a starved run (filters are a
        /// minority service) would dial forever. 4,000 is ~20× what the
        /// seeds alone ever produced; the old behaviour is unchanged for any
        /// run that would have finished inside it.
        let maxDials: Int
        let out: URL

        init(_ arguments: [String]) throws {
            target = try WinnowGenerate.number("--target", in: arguments) ?? 96
            floor = try WinnowGenerate.number("--floor", in: arguments) ?? 24
            maxDials = try WinnowGenerate.number("--max-dials", in: arguments) ?? 4_000
            guard floor >= 1, target >= floor else {
                throw GenerateError.usage("--floor must be at least 1 and no more than --target")
            }
            guard maxDials >= 1 else {
                throw GenerateError.usage("--max-dials must be at least 1")
            }
            source = try Source.parse(arguments)
            out = WinnowGenerate.option("--out", in: arguments).map { URL(fileURLWithPath: $0) }
                ?? WinnowGenerate.packageRoot.appending(path: Self.defaultOutput)
        }
    }

    static let dialTimeout: Duration = .seconds(5)
    /// How long a verified peer gets to answer `getaddr`. A slow or missing
    /// answer costs nothing but this peer's gossip — gossip is abundant
    /// (every other verified peer offers its own book), so the wait is short.
    static let gossipTimeout: Duration = .seconds(2)
    static let parallelDials = 24

    static func run(_ options: Options) async throws {
        switch options.source {
        case let .census(source):
            try await runCensus(options, input: CensusInput(data: try await censusData(from: source),
                                                            signature: nil, source: source, commit: nil))
        case let .censusCommit(commit):
            try await runCensus(options, input: try await pinnedCensus(commit: commit))
        case .crawl:
            try await runCrawl(options)
        }
    }

    /// The census bytes a run works from, and where they came from.
    struct CensusInput {
        let data: Data
        /// `peers.json.sig` next to the list, when the source had one.
        let signature: Data?
        let source: String
        /// The census commit the list was taken from, when pinned.
        let commit: String?
    }

    /// The census path: fetch (or read) the artifact, re-verify every
    /// clearnet entry offline, and render what survives. Nothing here dials
    /// — the census CI did the reaching; this run decides what to trust.
    static func runCensus(_ options: Options, input: CensusInput) async throws {
        try CensusPublisher.verify(input.data, signature: input.signature, trusting: CensusPublisher.trustedKeys)
        if CensusPublisher.trustedKeys.isEmpty {
            print("generator: no census publisher key is compiled in; the list is taken "
                  + (input.signature == nil ? "unsigned" : "unsigned although a signature was published"))
        }
        let catalog = try CensusCatalog.decode(input.data, minimumEntries: CensusCatalog.minimumClearnetEntries)
        let peers = (catalog.networks["clearnet"] ?? []).map {
            VerifiedPeer(endpoint: $0.endpoint, userAgent: $0.userAgent, startHeight: $0.startHeight)
        }
        guard peers.count >= options.floor else { throw GenerateError.thinList("too few validated census peers") }
        let hash = SHA256.hash(data: input.data).map { String(format: "%02x", $0) }.joined()
        var text = render(peers, tip: catalog.tip, date: catalog.date + "T00:00:00Z",
                          provenance: .census(artifactDate: catalog.date))
        text += """
        // Source: \(commentSafe(input.source))
        // Source SHA256: \(hash)

        """
        if let commit = input.commit {
            text += "// Source commit: \(commit)\n"
        }
        text += "// Observation date: \(catalog.date); generated: \(ISO8601DateFormatter().string(from: Date()))\n"
        try Data(text.utf8).write(to: options.out, options: .atomic)
        print("generator: wrote \(peers.count) clearnet candidates; observed \(catalog.date); SHA256 \(hash)")
    }

    static let censusRepository = "winnowwallet/census"
    static let censusPath = "census/peers.json"

    /// The list at one commit of the census repository. GitHub serves the
    /// blob at that revision; the tree entry the API reports for the same
    /// path and revision names the blob id, and the fetched bytes must hash
    /// to it — so the bundled list is tied to a reviewable commit rather than
    /// to whatever the live site served on the day.
    static func pinnedCensus(commit: String) async throws -> CensusInput {
        let client = RoutedHTTPClient()
        defer { client.cancel() }
        let raw = URL(string: "https://raw.githubusercontent.com/\(censusRepository)/\(commit)/\(censusPath)")!
        let data = try await client.get(raw, maximumBytes: CensusCatalog.maximumBytes)
        let tree = URL(string: "https://api.github.com/repos/\(censusRepository)/contents/\(censusPath)?ref=\(commit)")!
        // The contents API answers with the file's base64 content inline,
        // so the reply is bigger than the list itself; only `sha` is read.
        let entry = try JSONDecoder().decode(
            TreeEntry.self, from: try await client.get(tree, maximumBytes: CensusCatalog.maximumBytes * 2,
                                                       accept: "application/vnd.github+json"))
        guard entry.sha == gitBlobID(data) else {
            throw GenerateError.usage("peers.json fetched at \(commit) is not the blob the census tree names there")
        }
        let signature = try? await client.get(CensusSignature.endpoint(for: raw), maximumBytes: CensusSignature.maximumBytes)
        print("generator: census/peers.json at \(commit) is blob \(entry.sha)"
              + (signature == nil ? ", unsigned" : ", with its signature"))
        return CensusInput(data: data, signature: signature, source: "\(censusRepository)@\(commit):\(censusPath)",
                           commit: commit)
    }

    private struct TreeEntry: Decodable {
        let sha: String
    }

    /// Git's id for a blob: SHA-1 over `blob <size>\0` and the bytes.
    static func gitBlobID(_ data: Data) -> String {
        Data(Insecure.SHA1.hash(data: Data("blob \(data.count)\u{0}".utf8) + data)).hex
    }

    static func censusData(from source: String) async throws -> Data {
        if let url = URL(string: source), let scheme = url.scheme, ["http", "https"].contains(scheme) {
            let client = RoutedHTTPClient()
            defer { client.cancel() }
            return try await client.get(url, maximumBytes: CensusCatalog.maximumBytes)
        }
        let url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: CensusCatalog.maximumBytes + 1) ?? Data()
        guard data.count <= CensusCatalog.maximumBytes else { throw CensusCatalog.Invalid.size }
        return data
    }

    static func censusArtifact(from data: Data) throws -> CensusArtifact {
        guard data.count <= CensusCatalog.maximumBytes else { throw CensusCatalog.Invalid.size }
        return try JSONDecoder().decode(CensusArtifact.self, from: data)
    }

    static func runCrawl(_ options: Options) async throws {
        let params = NetworkParams.mainnet
        var queue = await SeedResolver.live().resolveSeeds(params.dnsSeeds, port: params.defaultPort,
                                                           allowPrivate: false)
        queue.shuffle()
        print("generator: \(queue.count) candidates from \(params.dnsSeeds.count) seeds")
        guard queue.count >= options.floor else {
            throw GenerateError.thinList("seed resolution produced only \(queue.count) candidates")
        }

        /// Every endpoint ever queued, dialled or not: addr gossip repeats
        /// the popular peers endlessly, and re-dialling one buys nothing.
        var seen = Set(queue)
        var verified: [VerifiedPeer] = []
        var dialed = 0
        var gossiped = 0
        while verified.count < options.target {
            let size = nextBatchSize(queued: queue.count, dialed: dialed, maxDials: options.maxDials)
            guard size > 0 else { break }
            let batch = Array(queue.prefix(size))
            queue.removeFirst(size)
            dialed += batch.count
            let results = await dial(batch, params: params)
            let candidates = gossipCandidates(results.flatMap(\.gossip),
                                              defaultPort: params.defaultPort, alreadySeen: seen)
            seen.formUnion(candidates)
            queue.append(contentsOf: candidates)
            gossiped += candidates.count
            verified = spread(results.map(\.peer), keeping: verified)
            print("generator: \(verified.count)/\(options.target) verified after \(dialed) dials, "
                  + "\(gossiped) candidates from gossip (\(queue.count) queued)")
        }
        guard verified.count >= options.floor else {
            throw GenerateError.thinList("only \(verified.count) filter-serving peers verified")
        }

        let tip = medianTip(verified)
        let (fresh, stale) = partitionByTip(verified, tip: tip)
        for peer in stale {
            print("generator: dropping \(peer.endpoint) at height \(peer.startHeight), "
                  + "\(Int64(tip) - Int64(peer.startHeight)) behind the median \(peer.userAgent)")
        }
        guard fresh.count >= options.floor else {
            throw GenerateError.thinList("only \(fresh.count) peers near the tip")
        }
        let source = render(fresh, tip: tip, date: ISO8601DateFormatter().string(from: Date()))
        try Data(source.utf8).write(to: options.out, options: .atomic)
        print("generator: wrote \(fresh.count) peers, median tip \(tip), to \(options.out.path)")
    }

    /// What a successful dial learned: the peer itself, plus whatever its
    /// addr gossip said (empty when it did not answer `getaddr`).
    struct VerifyResult: Sendable {
        let peer: VerifiedPeer
        let gossip: [PeerAddress]
    }

    /// Dials one batch in parallel. A refused handshake, a timeout and a peer
    /// without NODE_COMPACT_FILTERS are the same answer here: not listed.
    static func dial(_ batch: [PeerEndpoint], params: NetworkParams) async -> [VerifyResult] {
        await withTaskGroup(of: VerifyResult?.self) { group in
            for endpoint in batch {
                group.addTask { await verify(endpoint, params: params) }
            }
            var collected: [VerifyResult] = []
            for await result in group { if let result { collected.append(result) } }
            return collected
        }
    }

    static func verify(_ endpoint: PeerEndpoint, params: NetworkParams) async -> VerifyResult? {
        let peer = PeerConnection(endpoint: endpoint, params: params)
        do {
            try await peer.connect(timeout: dialTimeout)
            let verified = VerifiedPeer(endpoint: endpoint, userAgent: await peer.peerUserAgent,
                                        startHeight: await peer.peerStartHeight)
            let gossip = await gossipedAddresses(from: peer)
            await peer.disconnect()
            return VerifyResult(peer: verified, gossip: gossip)
        } catch {
            return nil
        }
    }

    /// One `getaddr`, the first `addr` that answers it. A refused, failed or
    /// timed-out exchange is not the peer misbehaving — a node owes a light
    /// client nothing — so it means "no gossip from this peer", never
    /// "unverified".
    static func gossipedAddresses(from peer: PeerConnection) async -> [PeerAddress] {
        guard let reply = try? await peer.request(.getaddr, expecting: ["addr"], timeout: gossipTimeout),
              case let .addr(addresses) = reply else { return [] }
        return addresses
    }

    // MARK: - Pure parts

    /// How many dials the next round may spend: the batch width, bounded by
    /// what is queued and by the remaining dial budget. Zero ends the crawl —
    /// the queue ran dry or `--max-dials` was spent.
    static func nextBatchSize(queued: Int, dialed: Int, maxDials: Int) -> Int {
        min(parallelDials, queued, max(0, maxDials - dialed))
    }

    /// What an addr reply is worth to the crawl, as dial candidates.
    ///
    /// Gossip arrives with each address's advertised services, so the dials
    /// that would certainly be wasted are skipped up front:
    ///
    /// - no NODE_COMPACT_FILTERS bit — the handshake would refuse the peer
    ///   anyway (the handshake stays the authoritative check; this only saves
    ///   the dial);
    /// - a port other than the default — the committed list may carry only
    ///   `defaultPort` entries (`PeerPolicyTests` pins that), so a peer on
    ///   any other port could never be listed;
    /// - a host that is not a public IP literal — `netblock` is nil, and the
    ///   list is literals only, exactly the drop `spread` applies after a
    ///   verify. Onioncat-encoded destinations (fd87:d87e:eb43::/32 in the
    ///   16-byte field) land in fc00::/7 and are filtered here too.
    ///
    /// What survives is deduplicated, inside the reply and against everything
    /// already queued or dialled: addr gossip repeats the popular peers
    /// endlessly, and re-dialling one buys nothing.
    static func gossipCandidates(_ addresses: [PeerAddress], defaultPort: UInt16,
                                 alreadySeen: Set<PeerEndpoint>) -> [PeerEndpoint] {
        var seen = alreadySeen
        var candidates: [PeerEndpoint] = []
        for address in addresses where address.services & PeerConnection.nodeCompactFilters != 0 {
            let endpoint = PeerEndpoint(host: address.host, port: address.port)
            guard endpoint.port == defaultPort, endpoint.netblock != nil,
                  seen.insert(endpoint).inserted else { continue }
            candidates.append(endpoint)
        }
        return candidates
    }

    /// One peer per netblock, first seen wins, in the order given. A peer whose
    /// block cannot be computed is not a public IP literal and is dropped: the
    /// list is literals only, so no resolver joins the trust story.
    static func spread(_ peers: [VerifiedPeer], keeping existing: [VerifiedPeer] = []) -> [VerifiedPeer] {
        var blocks = Set(existing.compactMap(\.endpoint.netblock))
        var kept = existing
        for peer in peers {
            guard let block = peer.endpoint.netblock, blocks.insert(block).inserted else { continue }
            kept.append(peer)
        }
        return kept
    }

    /// The observed tip: the median of what the verified peers report, which
    /// no single lying peer can move.
    static func medianTip(_ peers: [VerifiedPeer]) -> Int32 {
        precondition(!peers.isEmpty, "no peers to take a median of")
        let heights = peers.map(\.startHeight).sorted()
        return heights[heights.count / 2]
    }

    /// A peer far behind the median tip is in initial download or on a dead
    /// fork, and the pool would only unseat it at first contact
    /// (`PeerPool.staleTipTolerance`). Shipping it wastes the user's first
    /// dials on a peer known to be useless when the list was made.
    static func partitionByTip(_ peers: [VerifiedPeer], tip: Int32) -> (fresh: [VerifiedPeer], stale: [VerifiedPeer]) {
        var fresh: [VerifiedPeer] = []
        var stale: [VerifiedPeer] = []
        for peer in peers {
            if Int64(tip) - Int64(peer.startHeight) > PeerPool.staleTipTolerance {
                stale.append(peer)
            } else {
                fresh.append(peer)
            }
        }
        return (fresh, stale)
    }

    /// The user agent goes into a `//` comment, and a peer chooses its own. A
    /// line break in one would put whatever followed it into the compiled
    /// list, so only printable ASCII — all BIP14 ever needs — survives.
    static func commentSafe(_ userAgent: String) -> String {
        String(userAgent.unicodeScalars.map { $0.value >= 0x20 && $0.value < 0x7F ? Character($0) : "?" })
    }

    // MARK: - Census input

    /// A winnow-census `peers.json` artifact, schema v1 — the generator's
    /// default input. The census also publishes `tor` and `i2p` arrays; the
    /// wallet dials clearnet only, so they are carried, never rendered.
    struct CensusArtifact: Equatable, Sendable, Decodable {
        struct Entry: Equatable, Sendable, Codable {
            let host: String
            let port: UInt16
            let userAgent: String
            let startHeight: Int32
        }

        let schemaVersion: Int
        /// The day the census was taken, "yyyy-MM-dd".
        let date: String
        /// The tip the census recorded; clearnet entries are judged against
        /// it in both directions.
        let tip: Int32
        let networks: [String: [Entry]]

        init(schemaVersion: Int, date: String, tip: Int32, networks: [String: [Entry]]) {
            self.schemaVersion = schemaVersion
            self.date = date
            self.tip = tip
            self.networks = networks
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, date, tip, networks
        }

        /// The network keys are the census's own — `clearnet`, `tor`,
        /// `i2p` — and `clearnet` must be there; an artifact without it is
        /// malformed, not empty. Input this rigid fails loud, never half-read.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let networks = try container.decode([String: [Entry]].self, forKey: .networks)
            let known: Set<String> = ["clearnet", "tor", "i2p"]
            guard networks["clearnet"] != nil, Set(networks.keys).isSubset(of: known) else {
                throw DecodingError.dataCorruptedError(forKey: .networks, in: container,
                                                       debugDescription: "networks must be clearnet, tor and i2p")
            }
            self.init(schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
                      date: try container.decode(String.self, forKey: .date),
                      tip: try container.decode(Int32.self, forKey: .tip),
                      networks: networks)
        }
    }

    /// How old an artifact may be before the run refuses it: a fallback list
    /// is precisely where a stale census does its damage, and the release
    /// path regenerates often enough that a week is generous already.
    static let maximumCensusAgeDays = 7

    /// The census mode's whole job, offline: refuse an artifact that is not
    /// the schema this build parses or is too old to trust, then re-verify
    /// every clearnet entry against the invariants the committed list is
    /// held to. Nothing here trusts the census — an entry is kept only if it
    /// is a public IP literal on the default port (no resolver joins the
    /// trust story), holds its netblock alone (first seen wins, `spread`'s
    /// own rule), and reports a height within `PeerPool.staleTipTolerance`
    /// of the artifact's tip *in either direction*: a peer ahead of the tip
    /// is not fresher, it is on another chain.
    static func verifiedClearnetPeers(from artifact: CensusArtifact, defaultPort: UInt16,
                                      today: Date) throws -> [VerifiedPeer] {
        let networks = artifact.networks.mapValues { entries in
            entries.map { CensusCatalog.Entry(host: $0.host, port: $0.port, userAgent: $0.userAgent, startHeight: $0.startHeight) }
        }
        let catalog = try CensusCatalog(schemaVersion: artifact.schemaVersion, date: artifact.date,
                                        tip: artifact.tip, networks: networks).validated(now: today)
        return (catalog.networks["clearnet"] ?? []).map {
            VerifiedPeer(endpoint: $0.endpoint, userAgent: $0.userAgent, startHeight: $0.startHeight)
        }
    }

    /// A yyyy-MM-dd day as a GMT day number, or nil when the text is not a
    /// real calendar day. The artifact's `date` is a day, not a timestamp,
    /// and days compare cleanly only in one time zone.
    static func censusDay(_ text: String) -> Int? {
        CensusCatalog.day(text)
    }

    /// Days since the epoch, GMT. Dividing a timestamp by the day length is
    /// exact because the artifact's days are GMT-aligned too.
    static func censusDayNumber(of date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 86_400)
    }

    /// What produced the peers being rendered. The header names it so the
    /// committed file says which input it descends from — the first thing a
    /// release audit checks.
    enum Provenance: Equatable {
        /// A winnow-census artifact, re-verified offline.
        case census(artifactDate: String)
        /// A direct crawl from the DNS seeds.
        case crawl
    }

    /// The generated source, in exactly the shape the rest of the repository
    /// reads: `scripts/check-release-policy` parses the `// Generation:` line
    /// for the date, and `PeerPolicyTests` validates the entries.
    static func render(_ peers: [VerifiedPeer], tip: Int32, date: String,
                       provenance: Provenance = .crawl) -> String {
        let entries = peers
            .sorted { $0.endpoint.host < $1.endpoint.host }
            .map { peer in
                "        PeerEndpoint(host: \"\(peer.endpoint.host)\", "
                + "port: \(peer.endpoint.port)),  // \(commentSafe(peer.userAgent))"
            }
            .joined(separator: "\n")
        let generation: String
        switch provenance {
        case let .census(artifactDate):
            generation = """
            // Generation: \(date), \(peers.count) peers re-verified offline from the
            // winnow-census artifact of \(artifactDate), recorded tip \(tip).
            """
        case .crawl:
            generation = """
            // Generation: \(date), \(peers.count) peers verified, median reported
            // tip \(tip).
            """
        }
        return """
        // GENERATED FILE — edit by regenerating, not by hand.
        // scripts/generate-fallback-peers validates the census artifact with the
        // same policy as manual refresh. Selection from a fixed artifact is
        // deterministic; the source hash and observation date identify evidence.
        // Public clearnet endpoints use /16 IPv4 or /32 IPv6 diversity. Entries
        // must report heights within 100 blocks of the reference tip. This does
        // not establish filter correctness or that an endpoint is still online.
        // --from-crawl instead performs bounded discovery and live handshakes.
        // PeerPolicyTests checks the bundled list on every CI run.
        //
        \(generation)
        extension NetworkParams {
            static let generatedMainnetFallbackPeers: [PeerEndpoint] = [
        \(entries)
            ]
        }

        """
    }
}
