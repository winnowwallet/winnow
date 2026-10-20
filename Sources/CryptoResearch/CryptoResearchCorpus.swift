import Foundation

public enum CryptoResearchError: Error, Sendable, Equatable, LocalizedError {
    case missingFixture
    case invalidFixture

    public var errorDescription: String? {
        switch self {
        case .missingFixture: "The research reference file is missing. No comparison was completed."
        case .invalidFixture: "The research reference file is invalid. No comparison was completed."
        }
    }
}

struct CryptoResearchVector: Sendable {
    let name: String
    let x: Data
    let evenY: Data?
}

enum CryptoResearchCorpus {
    static func load() throws -> [CryptoResearchVector] {
        try decode(data: data())
    }

    static func data(bundle: Bundle = .module) throws -> Data {
        guard let url = bundle.url(
            forResource: "xonly-validation", withExtension: "json", subdirectory: "Fixtures"
        ) else { throw CryptoResearchError.missingFixture }
        return try Data(contentsOf: url)
    }

    static func decode(data: Data) throws -> [CryptoResearchVector] {
        let rows: [RawVector]
        do {
            rows = try JSONDecoder().decode([RawVector].self, from: data)
        } catch {
            throw CryptoResearchError.invalidFixture
        }
        guard rows.count == 318 else { throw CryptoResearchError.invalidFixture }
        guard Set(rows.map(\.name)).count == rows.count else { throw CryptoResearchError.invalidFixture }
        return try rows.map(validated)
    }

    private static func validated(_ row: RawVector) throws -> CryptoResearchVector {
        guard !row.name.isEmpty else { throw CryptoResearchError.invalidFixture }
        let x = try CryptoResearchHex.decodeCoordinate(row.x)
        let evenY = try row.evenY.map(CryptoResearchHex.decodeCoordinate)
        if let lastByte = evenY?.last, lastByte & 1 != 0 {
            throw CryptoResearchError.invalidFixture
        }
        return CryptoResearchVector(name: row.name, x: x, evenY: evenY)
    }

    private struct RawVector: Decodable {
        let name: String
        let x: String
        let evenY: String?

        private enum CodingKeys: String, CodingKey { case name, x, evenY }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            x = try values.decode(String.self, forKey: .x)
            // Missing expectations are corruption, not an invalid-key answer.
            evenY = try values.decode(String?.self, forKey: .evenY)
        }
    }
}

enum CryptoResearchHex {
    static func decodeCoordinate(_ value: String) throws -> Data {
        let text = Array(value.utf8)
        guard text.count == 64 else { throw CryptoResearchError.invalidFixture }
        let bytes = try stride(from: 0, to: text.count, by: 2).map { index in
            let high = try nibble(text[index])
            let low = try nibble(text[index + 1])
            return high << 4 | low
        }
        return Data(bytes)
    }

    private static func nibble(_ character: UInt8) throws -> UInt8 {
        switch character {
        case 48 ... 57: character - 48
        case 97 ... 102: character - 87
        default: throw CryptoResearchError.invalidFixture
        }
    }

    static func encode(_ value: Data) -> String {
        value.map { String(format: "%02x", $0) }.joined()
    }
}
