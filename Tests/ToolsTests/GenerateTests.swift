import WalletCore
import Foundation
import Testing
@testable import WinnowDebug

/// The generators' decisions, offline: everything `winnow-generate` does
/// between the network or the header file and the bytes it writes.
@Suite("winnow-generate")
struct WinnowGenerateTests {
    private typealias VerifiedPeer = FallbackPeerGenerator.VerifiedPeer

    private func peer(_ host: String, agent: String = "/Satoshi:31.0.0/",
                      height: Int32 = 963_930) -> VerifiedPeer {
        VerifiedPeer(endpoint: PeerEndpoint(host: host, port: 8_333), userAgent: agent, startHeight: height)
    }

    /// Synthetic 80-byte headers: any bytes decode, and nothing here checks
    /// proof of work — the chains do that, on real headers, elsewhere.
    private func syntheticHeaders(_ count: Int) -> [BlockHeader] {
        (0 ..< count).map { index in
            BlockHeader(version: 1, previousHash: Data(repeating: UInt8(index), count: 32),
                        merkleRoot: Data(repeating: 0xAB, count: 32), time: UInt32(index),
                        bits: 0x1D00_FFFF, nonce: UInt32(index))
        }
    }

    private func genesisRootedFile(_ headers: [BlockHeader]) -> Data {
        var raw = Data()
        raw.appendLittleEndian(UInt32(headers.count))
        for header in headers { raw.append(header.serialized) }
        return raw
    }

    /// Block 959,617, the one after the shipped checkpoint — the same 80 bytes
    /// `HeaderChainTests` connects.
    private static let blockAfterCheckpoint = Data(hex:
        "0000ff3f134d4218c42a45c3a2a1963b2267af5df0bf1443c7ee00000000000000000000"
        + "c1b77de7e764257238825b9aacf8e9cef6d068d82b036cfa516c909077ba1871"
        + "9d4c656ad43a0217203dd36f")!

    @Test("help never touches the network and an unknown command is refused")
    func dispatch() async throws {
        try await WinnowGenerate.execute([])
        try await WinnowGenerate.execute(["--help"])
        await #expect(throws: GenerateError.self) { try await WinnowGenerate.execute(["nope"]) }
    }

    @Test("the package root is the checkout this tool was compiled in")
    func packageRoot() {
        let manifest = WinnowGenerate.packageRoot.appending(path: "Package.swift")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test("fallback-peers options: census by default, crawl on request, never both")
    func fallbackOptions() throws {
        let defaults = try FallbackPeerGenerator.Options(["fallback-peers"])
        #expect(defaults.source == .census(FallbackPeerGenerator.Options.defaultCensusURL))
        #expect(defaults.target == 96)
        #expect(defaults.floor == 24)
        #expect(defaults.maxDials == 4_000)
        #expect(defaults.out == WinnowGenerate.packageRoot
            .appending(path: FallbackPeerGenerator.Options.defaultOutput))
        let custom = try FallbackPeerGenerator.Options(
            ["fallback-peers", "--target", "40", "--floor", "10", "--max-dials", "500",
             "--out", "/tmp/peers.swift"])
        #expect(custom.target == 40)
        #expect(custom.floor == 10)
        #expect(custom.maxDials == 500)
        #expect(custom.out.path == "/tmp/peers.swift")
        // The input is the census unless --from-crawl asks for the crawl.
        #expect(try FallbackPeerGenerator.Options(["fallback-peers", "--from-census"]).source
            == .census(FallbackPeerGenerator.Options.defaultCensusURL))
        #expect(try FallbackPeerGenerator.Options(["fallback-peers", "--from-census", "/tmp/peers.json"]).source
            == .census("/tmp/peers.json"))
        #expect(try FallbackPeerGenerator.Options(
            ["fallback-peers", "--from-census", "https://example.test/peers.json"]).source
            == .census("https://example.test/peers.json"))
        #expect(try FallbackPeerGenerator.Options(["fallback-peers", "--from-crawl"]).source == .crawl)
        // A pinned census commit is a full id, and is one input like the others.
        let commit = String(repeating: "ab", count: 20)
        #expect(try FallbackPeerGenerator.Options(["fallback-peers", "--census-commit", commit.uppercased()]).source
            == .censusCommit(commit))
        #expect(throws: GenerateError.self) {
            _ = try FallbackPeerGenerator.Options(["fallback-peers", "--census-commit", "abc123"])
        }
        #expect(throws: GenerateError.self) {
            _ = try FallbackPeerGenerator.Options(["fallback-peers", "--census-commit", commit, "--from-census", "p.json"])
        }
        #expect(FallbackPeerGenerator.gitBlobID(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(throws: GenerateError.self) {
            _ = try FallbackPeerGenerator.Options(["fallback-peers", "--from-census", "p.json", "--from-crawl"])
        }
        #expect(throws: GenerateError.self) {
            _ = try FallbackPeerGenerator.Options(["fallback-peers", "--from-census", "--out", "/tmp/x"])
        }
        #expect(throws: GenerateError.self) {
            _ = try FallbackPeerGenerator.Options(["fallback-peers", "--floor", "200"])
        }
        #expect(throws: GenerateError.self) {
            _ = try FallbackPeerGenerator.Options(["fallback-peers", "--target", "many"])
        }
        #expect(throws: GenerateError.self) {
            _ = try FallbackPeerGenerator.Options(["fallback-peers", "--max-dials", "0"])
        }
    }

    /// The crawl ends when the queue runs dry or the dial budget is spent,
    /// whichever comes first; the batch never exceeds the parallel width.
    @Test("the dial budget caps each batch and ends the crawl")
    func dialBudget() {
        #expect(FallbackPeerGenerator.nextBatchSize(queued: 100, dialed: 0, maxDials: 4_000) == 24)
        #expect(FallbackPeerGenerator.nextBatchSize(queued: 10, dialed: 0, maxDials: 4_000) == 10)
        #expect(FallbackPeerGenerator.nextBatchSize(queued: 100, dialed: 3_990, maxDials: 4_000) == 10)
        #expect(FallbackPeerGenerator.nextBatchSize(queued: 100, dialed: 4_000, maxDials: 4_000) == 0)
        #expect(FallbackPeerGenerator.nextBatchSize(queued: 0, dialed: 0, maxDials: 4_000) == 0)
        // A budget under the batch width still dials what it can.
        #expect(FallbackPeerGenerator.nextBatchSize(queued: 100, dialed: 0, maxDials: 7) == 7)
    }

    /// Gossip is pre-filtered before it costs a dial: the service bit the
    /// handshake would demand, the port the committed list may carry, a
    /// public IP literal — and every survivor deduplicated.
    @Test("gossip candidates keep only dialable peers, each exactly once")
    func gossipFilter() {
        let bit = PeerConnection.nodeCompactFilters
        func gossip(_ host: (UInt8, UInt8, UInt8, UInt8), services: UInt64 = bit,
                    port: UInt16 = 8_333) -> PeerAddress {
            PeerAddress(time: 1_700_000_000, services: services, ipv4: host, port: port)
        }
        let v6 = PeerAddress(time: 1_700_000_000, services: bit,
                             ip: Data(hex: "20010478000100020000000000000001")!, port: 8_333)
        let seen: Set<PeerEndpoint> = [PeerEndpoint(host: "9.9.9.9", port: 8_333)]
        let candidates = FallbackPeerGenerator.gossipCandidates([
            gossip((47, 206, 253, 100)),                 // kept
            gossip((47, 206, 253, 100)),                 // repeat inside the reply
            gossip((9, 9, 9, 9)),                        // already queued
            gossip((1, 2, 3, 4), services: 1),           // cannot serve filters
            gossip((1, 2, 3, 5), services: bit - 1),     // every bit but the one
            gossip((1, 2, 3, 6), port: 18_333),          // unlistable port
            gossip((192, 168, 1, 1)),                    // not a public literal
            gossip((74, 209, 75, 75), services: bit | 1),// kept; other bits irrelevant
            v6,                                          // kept, rendered compressed
        ], defaultPort: 8_333, alreadySeen: seen)
        #expect(candidates == [PeerEndpoint(host: "47.206.253.100", port: 8_333),
                               PeerEndpoint(host: "74.209.75.75", port: 8_333),
                               PeerEndpoint(host: "2001:478:1:2::1", port: 8_333)])
        // A second reply repeating all of it yields nothing new.
        #expect(FallbackPeerGenerator.gossipCandidates(
            [gossip((47, 206, 253, 100)), v6],
            defaultPort: 8_333, alreadySeen: seen.union(candidates)).isEmpty)
    }

    @Test("one peer per netblock, first seen wins; hostnames and private addresses are dropped")
    func spread() {
        let first = peer("47.206.253.100")
        let sameBlock = peer("47.206.1.1")
        let other = peer("47.207.253.100")
        let v6 = peer("2a01:4f8:1:2::1")
        let v6SameBlock = peer("2a01:4f8:9:9::9")
        let hostname = peer("node.example.com")
        let lan = peer("192.168.1.10")
        let kept = FallbackPeerGenerator.spread([first, sameBlock, other, v6, v6SameBlock, hostname, lan])
        #expect(kept == [first, other, v6])
        // Across batches the earlier selection holds its blocks.
        let later = peer("8.8.8.8")
        #expect(FallbackPeerGenerator.spread([sameBlock, later], keeping: kept) == [first, other, v6, later])
    }

    @Test("the median tip is the middle report and peers far behind it are dropped")
    func staleTip() {
        let tolerance = Int32(PeerPool.staleTipTolerance)
        let peers = [peer("1.1.1.1", height: 1_000), peer("2.2.2.2", height: 1_000 - tolerance),
                     peer("3.3.3.3", height: 1_000 - tolerance - 1), peer("4.4.4.4", height: 5_000),
                     peer("5.5.5.5", height: 1_000)]
        let tip = FallbackPeerGenerator.medianTip(peers)
        #expect(tip == 1_000)
        let (fresh, stale) = FallbackPeerGenerator.partitionByTip(peers, tip: tip)
        #expect(fresh.map(\.endpoint.host) == ["1.1.1.1", "2.2.2.2", "4.4.4.4", "5.5.5.5"])
        #expect(stale.map(\.endpoint.host) == ["3.3.3.3"])
        // One liar cannot move the median.
        #expect(FallbackPeerGenerator.medianTip(peers + [peer("6.6.6.6", height: .max)]) == 1_000)
    }

    // MARK: Census input

    private typealias CensusArtifact = FallbackPeerGenerator.CensusArtifact

    /// A GMT calendar day as a Date — the artifact's `date` counts days, not
    /// seconds, so the fixtures pick a day rather than a timestamp.
    private func today(_ text: String) throws -> Date {
        Date(timeIntervalSince1970: TimeInterval(try #require(FallbackPeerGenerator.censusDay(text)) * 86_400))
    }

    private func entry(_ host: String, port: UInt16 = 8_333,
                       height: Int32 = 966_774) -> CensusArtifact.Entry {
        CensusArtifact.Entry(host: host, port: port, userAgent: "/Satoshi:31.1.0/", startHeight: height)
    }

    private func artifact(date: String = "2026-09-12", tip: Int32 = 966_774,
                          clearnet: [CensusArtifact.Entry],
                          schemaVersion: Int = 1) -> CensusArtifact {
        CensusArtifact(schemaVersion: schemaVersion, date: date, tip: tip,
                       networks: [.clearnet: clearnet])
    }

    @Test("a peers.json parses into every overlay, tor and i2p included")
    func censusParses() throws {
        let json = """
        {
          "schemaVersion": 1,
          "date": "2026-09-12",
          "tip": 966774,
          "networks": {
            "clearnet": [
              {"host": "47.206.253.100", "port": 8333, "userAgent": "/Satoshi:31.1.0/", "startHeight": 966770}
            ],
            "tor": [
              {"host": "exampleonionaddressisherebutnotreal5581xyz.onion", "port": 8333,
               "userAgent": "/Satoshi:31.1.0/", "startHeight": 966770}
            ],
            "i2p": [
              {"host": "exampleb32addressisherebutnotrealaaaaaaaaaaaaaaaaaaaa.b32.i2p", "port": 8333,
               "userAgent": "/Satoshi:31.1.0/", "startHeight": 966770}
            ]
          }
        }
        """
        let parsed = try FallbackPeerGenerator.censusArtifact(from: Data(json.utf8))
        #expect(parsed.schemaVersion == 1)
        #expect(parsed.date == "2026-09-12")
        #expect(parsed.tip == 966_774)
        // The overlay lists are parsed into the model even though nothing
        // renders them yet — that is what the parser being "ready" means.
        #expect(parsed.networks[.clearnet]?.map(\.host) == ["47.206.253.100"])
        #expect(parsed.networks[.tor]?.map(\.host) == ["exampleonionaddressisherebutnotreal5581xyz.onion"])
        #expect(parsed.networks[.i2p]?.map(\.host)
            == ["exampleb32addressisherebutnotrealaaaaaaaaaaaaaaaaaaaa.b32.i2p"])
        #expect(parsed.networks[.tor]?.first?.startHeight == 966_770)
    }

    @Test("anything that is not the fixed schema-v1 shape is refused, not half-read")
    func censusMalformed() {
        #expect(throws: (any Error).self) {
            _ = try FallbackPeerGenerator.censusArtifact(from: Data("not json".utf8))
        }
        #expect(throws: (any Error).self) {
            _ = try FallbackPeerGenerator.censusArtifact(from: Data("{}".utf8))
        }
        // An unknown network key: the schema is clearnet/tor/i2p, exactly.
        let unknownNetwork = """
        {"schemaVersion": 1, "date": "2026-09-12", "tip": 966774,
         "networks": {"clearnet": [], "fakenet": []}}
        """
        #expect(throws: (any Error).self) {
            _ = try FallbackPeerGenerator.censusArtifact(from: Data(unknownNetwork.utf8))
        }
    }

    @Test("the census artifact comes from a file; a missing path is a refusal")
    func censusFromFile() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("peers-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{}".utf8).write(to: file)
        #expect(try await FallbackPeerGenerator.censusData(from: file.path) == Data("{}".utf8))
        await #expect(throws: (any Error).self) {
            _ = try await FallbackPeerGenerator.censusData(from: file.path + ".missing")
        }
    }

    @Test("every clearnet invariant is re-verified offline, in both tip directions")
    func censusFiltering() throws {
        let tolerance = Int32(PeerPool.staleTipTolerance)
        let tip: Int32 = 966_774
        let checked = try FallbackPeerGenerator.verifiedClearnetPeers(from: artifact(tip: tip, clearnet: [
            entry("47.206.253.100"), entry("9.9.9.9", height: tip - tolerance),
            entry("1.1.1.1", height: tip + tolerance), entry("2001:478:1:2::1"),
        ]), defaultPort: 8333, today: today("2026-09-13"))
        #expect(checked.map(\.endpoint.host) == ["1.1.1.1", "2001:478:1:2::1", "47.206.253.100", "9.9.9.9"])
        for bad in [entry("47.206.1.1"), entry("74.209.75.75", port: 18333), entry("node.example.com"),
                    entry("192.168.1.10"), entry("8.8.8.8", height: tip - tolerance - 1),
                    entry("2.2.2.2", height: tip + tolerance + 1)] {
            #expect(throws: CensusCatalog.Invalid.self) {
                try FallbackPeerGenerator.verifiedClearnetPeers(from: artifact(tip: tip, clearnet: [entry("47.206.253.100"), bad]),
                    defaultPort: 8333, today: today("2026-09-13"))
            }
        }
    }

    @Test("a census artifact that is not schema v1, dated wrong, or too old is refused")
    func censusRefusals() throws {
        let peers = [entry("47.206.253.100")]
        let recent = try today("2026-09-13")
        #expect(throws: (any Error).self) {
            _ = try FallbackPeerGenerator.verifiedClearnetPeers(
                from: artifact(clearnet: peers, schemaVersion: 2), defaultPort: 8_333, today: recent)
        }
        #expect(throws: (any Error).self) {
            _ = try FallbackPeerGenerator.verifiedClearnetPeers(
                from: artifact(date: "not-a-date", clearnet: peers), defaultPort: 8_333, today: recent)
        }
        // 2026-02-30 is not a real day.
        #expect(FallbackPeerGenerator.censusDay("2026-02-30") == nil)
        #expect(FallbackPeerGenerator.censusDay("2026-9-13") == nil, "days are zero-padded")
        // Seven days old is the most an artifact may be; eight is refused.
        _ = try FallbackPeerGenerator.verifiedClearnetPeers(
            from: artifact(date: "2026-09-06", clearnet: peers), defaultPort: 8_333, today: recent)
        #expect(throws: (any Error).self) {
            _ = try FallbackPeerGenerator.verifiedClearnetPeers(
                from: artifact(date: "2026-09-05", clearnet: peers), defaultPort: 8_333, today: recent)
        }
        #expect(throws: CensusCatalog.Invalid.future) {
            try FallbackPeerGenerator.verifiedClearnetPeers(
                from: artifact(date: "2026-09-14", clearnet: peers), defaultPort: 8_333, today: recent)
        }
    }

    @Test("the census generation line names the artifact and its tip")
    func censusRender() {
        let peers = [peer("9.9.9.9"), peer("1.2.3.4")]
        let source = FallbackPeerGenerator.render(peers, tip: 966_774, date: "2026-09-13T00:42:03Z",
                                                  provenance: .census(artifactDate: "2026-09-12"))
        // scripts/check-release-policy still reads the date off this line.
        #expect(source.contains("\n// Generation: 2026-09-13T00:42:03Z, 2 peers re-verified offline"
                                + " from the\n// winnow-census artifact of 2026-09-12, recorded tip 966774.\n"))
        #expect(source.contains("PeerEndpoint(host: \"1.2.3.4\", port: 8333)"))
    }

    @Test("the rendered source is the shape the release policy and the list test read")
    func render() {
        let peers = [peer("9.9.9.9", agent: "/Satoshi:31.0.0/"),
                     peer("1.2.3.4", agent: "/Satoshi:29.2.0/Knots:20260507/")]
        let source = FallbackPeerGenerator.render(peers, tip: 963_930, date: "2026-08-25T00:42:03Z")
        #expect(source.hasPrefix("// GENERATED FILE — edit by regenerating, not by hand.\n"))
        // scripts/check-release-policy reads the date off this line.
        #expect(source.contains("\n// Generation: 2026-08-25T00:42:03Z, 2 peers verified, median reported\n// tip 963930.\n"))
        #expect(source.hasSuffix("""
        extension NetworkParams {
            static let generatedMainnetFallbackPeers: [PeerEndpoint] = [
                PeerEndpoint(host: "1.2.3.4", port: 8333),  // /Satoshi:29.2.0/Knots:20260507/
                PeerEndpoint(host: "9.9.9.9", port: 8333),  // /Satoshi:31.0.0/
            ]
            static let generatedMainnetTorFallbackPeers: [PeerEndpoint] = [

            ]
        }

        """))
    }

    @Test("the committed list is what the tool renders, up to the generation line")
    func committedPreamble() throws {
        let committed = try String(
            contentsOf: WinnowGenerate.packageRoot.appending(path: FallbackPeerGenerator.Options.defaultOutput),
            encoding: .utf8)
        let rendered = FallbackPeerGenerator.render([], tip: 0, date: "now")
        func preamble(_ text: String) -> [Substring] {
            Array(text.split(separator: "\n", omittingEmptySubsequences: false)
                .prefix { !$0.hasPrefix("// Generation:") })
        }
        #expect(!preamble(committed).isEmpty)
        #expect(preamble(committed) == preamble(rendered))
    }

    @Test("a user agent cannot smuggle a line into the generated source")
    func agentSanitized() {
        let hostile = peer("9.9.9.9", agent: "/Evil:1/\n        PeerEndpoint(host: \"6.6.6.6\", port: 8333),  //")
        let source = FallbackPeerGenerator.render([hostile], tip: 1, date: "now")
        #expect(source.split(separator: "\n").filter { $0.contains("PeerEndpoint(host:") }.count == 1)
        #expect(FallbackPeerGenerator.commentSafe("/Satoshi:31.0.0/") == "/Satoshi:31.0.0/")
        #expect(FallbackPeerGenerator.commentSafe("a\nb\tc\u{7F}d\u{E9}") == "a?b?c?d?")
    }

    @Test("checkpoint options need a source path and take a height")
    func checkpointOptions() throws {
        let options = try CheckpointGenerator.Options(
            ["checkpoint", "~/headers.bin", "--height", "950000", "--vector-out", "out.txt"])
        #expect(options.height == 950_000)
        #expect(options.source.path.hasSuffix("/headers.bin"))
        #expect(!options.source.path.hasPrefix("~"))
        #expect(options.vectorOut?.lastPathComponent == "out.txt")
        #expect(try CheckpointGenerator.Options(["checkpoint", "h.bin"]).height == nil)
        #expect(throws: GenerateError.self) { try CheckpointGenerator.Options(["checkpoint"]) }
        #expect(throws: GenerateError.self) { try CheckpointGenerator.Options(["checkpoint", "--height", "1"]) }
    }

    @Test("truncation keeps exactly the requested headers and refuses the wrong source")
    func truncate() throws {
        let headers = syntheticHeaders(5)
        let raw = genesisRootedFile(headers)
        #expect(try CheckpointGenerator.truncated(raw, toHeaders: 3) == genesisRootedFile(Array(headers.prefix(3))))
        #expect(try CheckpointGenerator.truncated(raw, toHeaders: 5) == raw)
        #expect(throws: GenerateError.self) { try CheckpointGenerator.truncated(raw, toHeaders: 6) }
        // A checkpoint-rooted file would be assuming what is being derived.
        var rooted = Data()
        rooted.appendLittleEndian(CheckpointGenerator.checkpointRootedMarker)
        rooted.append(raw.dropFirst(4))
        #expect(throws: GenerateError.self) { try CheckpointGenerator.truncated(rooted, toHeaders: 1) }
        // A file shorter than its count claims.
        #expect(throws: GenerateError.self) { try CheckpointGenerator.truncated(raw.dropLast(1), toHeaders: 5) }
    }

    @Test("headers are sliced by height out of the genesis-rooted file")
    func slice() throws {
        let headers = syntheticHeaders(6)
        let raw = genesisRootedFile(headers)
        #expect(try CheckpointGenerator.headers(in: raw, from: 2, throughInclusive: 4) == Array(headers[2 ... 4]))
        #expect(try CheckpointGenerator.headers(in: raw, from: 5, throughInclusive: 5) == [headers[5]])
        #expect(throws: GenerateError.self) { try CheckpointGenerator.headers(in: raw, from: 4, throughInclusive: 6) }
        #expect(throws: GenerateError.self) { try CheckpointGenerator.headers(in: raw, from: 4, throughInclusive: 3) }
    }

    @Test("heights are spelled the way the source spells them")
    func grouped() {
        #expect(CheckpointGenerator.grouped(900_000, separator: "_") == "900_000")
        #expect(CheckpointGenerator.grouped(1_234_567, separator: ",") == "1,234,567")
        #expect(CheckpointGenerator.grouped(100, separator: "_") == "100")
        #expect(CheckpointGenerator.grouped(0, separator: "_") == "0")
    }

    @Test("the literal for the shipped checkpoint is the source, line for line")
    func literalMatchesSource() throws {
        let shipped = try #require(NetworkParams.mainnet.checkpoint)
        let literal = CheckpointGenerator.literal(height: shipped.height,
                                                  header: try BlockHeader.decode(shipped.header),
                                                  work: shipped.chainwork)
        let source = try String(
            contentsOf: WinnowGenerate.packageRoot.appending(path: "Sources/WalletCore/Network/Protocol/NetworkParams.swift"),
            encoding: .utf8)
        func trimmed(_ text: String) -> [String] {
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let wanted = trimmed(literal)
        let lines = trimmed(source)
        let start = try #require(lines.firstIndex(of: wanted[0]))
        try #require(start + wanted.count <= lines.count)
        // Contiguous, so the paste is a pure replacement.
        #expect(Array(lines[start ..< start + wanted.count]) == wanted)
    }

    @Test("vector lines are 160 lowercase hex characters that decode back to the header")
    func vector() throws {
        let real = try BlockHeader.decode(Self.blockAfterCheckpoint)
        let headers = syntheticHeaders(3) + [real]
        let text = CheckpointGenerator.vectorText(headers)
        let lines = text.split(separator: "\n")
        #expect(text.hasSuffix("\n"))
        #expect(lines.count == 4)
        #expect(lines.allSatisfy { line in
            line.count == 160 && line.allSatisfy { character in character.isHexDigit && !character.isUppercase }
        })
        let decoded = try lines.map { line -> BlockHeader in
            let bytes = try #require(Data(hex: String(line)))
            return try BlockHeader.decode(bytes)
        }
        #expect(decoded == headers)
    }

    @Test("the derived checkpoint replaces only the checkpoint in the parameters")
    func replacedCheckpoint() throws {
        let params = NetworkParams.mainnet
        let shipped = try #require(params.checkpoint)
        let replacement = NetworkParams.Checkpoint(height: 1, header: shipped.header, chainwork: shipped.chainwork)
        let swapped = CheckpointGenerator.parameters(params, with: replacement)
        #expect(swapped.checkpoint == replacement)
        #expect(swapped.magic == params.magic)
        #expect(swapped.dnsSeeds == params.dnsSeeds)
        #expect(swapped.fallbackPeers == params.fallbackPeers)
        #expect(swapped.genesisHash == params.genesisHash)
    }

    @Test("the shipped constant is compared only at its own height")
    func compareWithShipped() throws {
        let shipped = try #require(NetworkParams.mainnet.checkpoint)
        try CheckpointGenerator.compare(shipped, shipped: shipped)
        try CheckpointGenerator.compare(shipped, shipped: nil)
        let elsewhere = NetworkParams.Checkpoint(height: shipped.height + 1, header: shipped.header,
                                                 chainwork: shipped.chainwork)
        try CheckpointGenerator.compare(elsewhere, shipped: shipped)
        let wrong = NetworkParams.Checkpoint(height: shipped.height, header: shipped.header,
                                             chainwork: Data(repeating: 0, count: 32))
        #expect(throws: GenerateError.self) { try CheckpointGenerator.compare(wrong, shipped: shipped) }
    }

    @Test("agreement holds between chains on the same tip and fails once they differ")
    func agreement() async throws {
        let params = NetworkParams.mainnet
        let shipped = try #require(params.checkpoint)
        let one = try HeaderChain(params: params, storageURL: nil, start: .checkpoint)
        let other = try HeaderChain(params: params, storageURL: nil, start: .checkpoint)
        try await CheckpointGenerator.requireAgreement(one, other, at: [shipped.height])

        let next = try BlockHeader.decode(Self.blockAfterCheckpoint)
        #expect(try await one.connect([next]).appended == 1)
        await #expect(throws: GenerateError.self) {
            try await CheckpointGenerator.requireAgreement(one, other, at: [shipped.height])
        }
        #expect(try await other.connect([next]).appended == 1)
        try await CheckpointGenerator.requireAgreement(one, other, at: [shipped.height, shipped.height + 1])
    }
}
