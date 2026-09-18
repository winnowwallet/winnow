import WalletCore
import Foundation

/// Derives the mainnet header checkpoint from a genesis-validated header file.
/// This development command uses WalletCore outside the shipping app.
///
///   winnow-debug generate checkpoint <headers.bin> [--height H] [--vector-out PATH]
enum WinnowGenerate {
    static func execute(_ arguments: [String]) async throws {
        guard let command = arguments.first, !["help", "--help", "-h"].contains(command) else {
            return usage()
        }
        switch command {
        case "checkpoint":
            let options = try CheckpointGenerator.Options(arguments)
            try await CheckpointGenerator.run(options)
        default:
            throw GenerateError.usage("unknown command \(command)")
        }
    }

    static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func number<Value: FixedWidthInteger>(_ name: String, in arguments: [String]) throws -> Value? {
        guard let text = option(name, in: arguments) else { return nil }
        guard let value = Value(text) else { throw GenerateError.usage("\(name) needs a whole number, not \(text)") }
        return value
    }

    static func usage() {
        print(usageText)
    }

    static let usageText = """
    Winnow header checkpoint derivation

      swift run winnow-debug generate checkpoint <headers.bin> [--height H] [--vector-out PATH]
          Derive the mainnet checkpoint at H (default: the shipped height) from a
          genesis-rooted header file, through HeaderChain itself; print it as a
          paste-ready literal; then prove a chain started from it agrees with the
          genesis-rooted chain 2,000 blocks on. --vector-out writes those 2,000
          headers, one per line as hex, for HeaderChainTests.
    """
}

enum GenerateError: LocalizedError {
    case usage(String)
    case badSource(String)
    case divergence(String)

    var errorDescription: String? {
        switch self {
        case let .usage(detail): "\(detail)\n\n\(WinnowGenerate.usageText)"
        case let .badSource(detail): "unusable header file: \(detail)"
        case let .divergence(detail): "checkpoint disagreement: \(detail)"
        }
    }
}
