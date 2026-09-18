import WalletCore
import Foundation
import Testing
@testable import WinnowDebug

/// Offline checkpoint derivation and validation against header-file fixtures.
@Suite("winnow-generate")
struct WinnowGenerateTests {
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
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appending(path: "Sources/WalletCore/Network/Protocol/NetworkParams.swift"),
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
