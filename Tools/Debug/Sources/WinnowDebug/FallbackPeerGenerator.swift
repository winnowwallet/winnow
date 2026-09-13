import WalletCore
import Foundation

/// Release-path generator for the bundled mainnet fallback peers (#161), run
/// by `scripts/generate-fallback-peers`.
///
/// The input is a census, not a crawl. The winnow-census CI crawls mainnet
/// continuously — it descends from the btcnodes snapshot — and publishes a
/// `peers.json` artifact (`--from-census` overrides where it is read from;
/// the default is the published URL). Every clearnet entry is then
/// re-verified *offline* against the invariants the committed list is held
/// to: a public IP literal, the default port, one entry per netblock by the
/// same `netblock` the pool's diversity policy uses, and a reported height
/// within `PeerPool.staleTipTolerance` of the artifact's recorded tip in
/// either direction — a peer ahead of the tip is not fresher, it is on
/// another chain. An artifact that is not schema v1, or is more than a week
/// old, is refused outright. The artifact's tor and i2p entries parse into
/// the same model but are rendered nowhere: no transport can dial them yet.
///
/// `--from-crawl` keeps the pre-census input as a fallback. Candidates come
/// from a crawl, not only from the seeds. DNS-seed results seed the dial
/// queue — their services are unknown, so they are always dialled — and
/// every peer that verifies is asked once, with `getaddr`, for its address
/// book; the `addr` reply queues more candidates. Gossip arrives with each
/// address's advertised services, so a candidate missing
/// NODE_COMPACT_FILTERS, on a port the committed list may not carry, or not a
/// public IP literal is skipped *before* dialling: most dials then reach a
/// peer that could actually be listed, instead of being spent on one the
/// handshake would refuse. The crawl is bounded by `--max-dials` so the run
/// terminates even while gossip keeps the queue full.
///
/// The crawl's verification bar is not re-implemented: `PeerConnection.connect`
/// already refuses any peer whose version does not advertise
/// NODE_COMPACT_FILTERS, so a completed handshake *is* the check the
/// hand-curated list was held to. The gossip pre-filter only saves dials;
/// the handshake stays the authoritative check. Spread is enforced with the
/// same `netblock` the pool's diversity policy uses.
///
/// The network part is `run`; everything it decides with is a pure function
/// below, covered offline by `WinnowGenerateTests`.
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
        static let defaultCensusURL = "https://posix4e.github.io/winnow-census/peers.json"

        /// What feeds the run.
        enum Source: Equatable {
            /// A winnow-census `peers.json`: an http(s) URL or a local path.
            /// The default input — the crawl exists for when no usable
            /// artifact is published.
            case census(String)
            /// The DNS-seed + getaddr crawl (`--from-crawl`).
            case crawl
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
            let census = WinnowGenerate.option("--from-census", in: arguments)
            let crawl = arguments.contains("--from-crawl")
            if let census, census.hasPrefix("--") {
                throw GenerateError.usage("--from-census needs a URL or a path")
            }
            guard census == nil || !crawl else {
                throw GenerateError.usage("--from-census and --from-crawl are two different inputs")
            }
            source = crawl ? .crawl : .census(census ?? Self.defaultCensusURL)
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
        case let .census(source): try await runCensus(options, source: source)
        case .crawl: try await runCrawl(options)
        }
    }

    /// The census path: fetch (or read) the artifact, re-verify every
    /// clearnet entry offline, and render what survives. Nothing here dials
    /// — the census CI did the reaching; this run decides what to trust.
    static func runCensus(_ options: Options, source: String) async throws {
        let data = try await censusData(from: source)
        let artifact = try censusArtifact(from: data)
        let peers = try verifiedClearnetPeers(from: artifact,
                                              defaultPort: NetworkParams.mainnet.defaultPort,
                                              today: Date())
        guard peers.count >= options.floor else {
            throw GenerateError.thinList("only \(peers.count) of the census's clearnet peers re-verified")
        }
        let text = render(peers, tip: artifact.tip, date: ISO8601DateFormatter().string(from: Date()),
                          provenance: .census(artifactDate: artifact.date))
        try Data(text.utf8).write(to: options.out, options: .atomic)
        print("generator: wrote \(peers.count) peers from the winnow-census artifact of "
              + "\(artifact.date) (tip \(artifact.tip)) to \(options.out.path)")
    }

    /// The artifact's bytes: fetched over http(s), or read from a file. A
    /// URL goes to URLSession; anything else is a filesystem path.
    static func censusData(from source: String) async throws -> Data {
        if let url = URL(string: source), let scheme = url.scheme,
           scheme == "http" || scheme == "https" {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw GenerateError.badCensus(
                        "GET \(source) answered \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                }
                return data
            } catch let error as GenerateError {
                throw error
            } catch {
                throw GenerateError.badCensus("GET \(source) failed: \(error.localizedDescription)")
            }
        }
        let path = (source as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else {
            throw GenerateError.badCensus("no census artifact at \(path)")
        }
        return data
    }

    /// Parse, refusing anything that is not the fixed schema-v1 shape: the
    /// artifact is input, and input this rigid fails loud, never half-read.
    static func censusArtifact(from data: Data) throws -> CensusArtifact {
        do {
            return try JSONDecoder().decode(CensusArtifact.self, from: data)
        } catch {
            throw GenerateError.badCensus("not a schema-v1 peers.json: \(error.localizedDescription)")
        }
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
    ///   verify. Onioncat-encoded Tor destinations (fd87:d87e:eb43::/32 in
    ///   the 16-byte field) land in fc00::/7 and are filtered here too.
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
    /// default input. The tor and i2p arrays parse into the same model so
    /// the parser is ready for a transport; nothing renders them into the
    /// committed file until one exists.
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
        let networks: [OverlayNetwork: [Entry]]

        init(schemaVersion: Int, date: String, tip: Int32, networks: [OverlayNetwork: [Entry]]) {
            self.schemaVersion = schemaVersion
            self.date = date
            self.tip = tip
            self.networks = networks
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, date, tip, networks
        }

        /// The network keys are the overlay raw values exactly; an unknown
        /// key is a malformed artifact, not a network to skip — the schema
        /// is fixed, and input this rigid fails loud, never half-read.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decode([String: [Entry]].self, forKey: .networks)
            var networks: [OverlayNetwork: [Entry]] = [:]
            for (name, entries) in raw {
                guard let overlay = OverlayNetwork(rawValue: name) else {
                    throw DecodingError.dataCorruptedError(forKey: .networks, in: container,
                                                           debugDescription: "unknown network \(name)")
                }
                networks[overlay] = entries
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
        guard artifact.schemaVersion == 1 else {
            throw GenerateError.badCensus("schemaVersion \(artifact.schemaVersion), this build parses 1")
        }
        guard let artifactDay = censusDay(artifact.date) else {
            throw GenerateError.badCensus("date \(artifact.date) is not yyyy-MM-dd")
        }
        let age = censusDayNumber(of: today) - artifactDay
        guard age <= maximumCensusAgeDays else {
            throw GenerateError.badCensus("dated \(artifact.date), \(age) days before today")
        }
        var blocks = Set<String>()
        var kept: [VerifiedPeer] = []
        for entry in artifact.networks[.clearnet] ?? [] {
            let endpoint = PeerEndpoint(host: entry.host, port: entry.port)
            let distance = Int64(entry.startHeight) - Int64(artifact.tip)
            guard endpoint.port == defaultPort, let block = endpoint.netblock,
                  abs(distance) <= PeerPool.staleTipTolerance,
                  blocks.insert(block).inserted else { continue }
            kept.append(VerifiedPeer(endpoint: endpoint, userAgent: entry.userAgent,
                                     startHeight: entry.startHeight))
        }
        return kept
    }

    /// A yyyy-MM-dd day as a GMT day number, or nil when the text is not a
    /// real calendar day. The artifact's `date` is a day, not a timestamp,
    /// and days compare cleanly only in one time zone.
    static func censusDay(_ text: String) -> Int? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        return censusDayNumber(of: date)
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
        //
        // scripts/generate-fallback-peers rewrites this file on the release path
        // (#161) with `winnow-debug generate fallback-peers` (Tools/Debug). The input
        // is the winnow-census CI's peers.json — a crawler that descends from the
        // btcnodes snapshot and re-crawls mainnet continuously, so this list inherits
        // the census's view of the network rather than the generating host's. Every
        // clearnet entry is re-verified offline before it is written: public IP
        // literal, port 8333, one per /16 by the same `PeerEndpoint.netblock` the
        // pool's diversity policy uses, and a reported height within 100 of the
        // artifact's recorded tip in either direction (ahead of the tip is another
        // chain). With no usable artifact, `--from-crawl` crawls mainnet from the DNS
        // seeds instead, dialling candidates pre-filtered by their advertised
        // NODE_COMPACT_FILTERS bit with the same PeerConnection the app uses, whose
        // handshake already refuses any peer not advertising that bit.
        //
        // The committed copy is the last verified generation and the build's fallback;
        // a release regenerates so freshness tracks releases rather than memory.
        // `PeerPolicyTests` validates this file on every CI run.
        //
        // What this is not, recorded so it is not over-claimed: the list inherits
        // whatever the census — or, from a crawl, the generating host — could see,
        // and generation is not reproducible: two runs give different lists. The
        // generation log is kept as a release artifact so the list is auditable even
        // though it is not reproducible.
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
