import Darwin
import Foundation
import Security
import WalletCore

/// The Satochip checker on a trusted Mac: it holds the card's 2FA secret and
/// the account registered at setup, shows each spend computed from the PSBT
/// alone, and prints approvals only after the person types APPROVE. The
/// review and the approvals are WalletCore's `Satochip.Checker`; this file
/// only reads files and talks to the terminal.
@main
enum WinnowChecker {
    static func main() async {
        do {
            try execute(Array(CommandLine.arguments.dropFirst()), terminal: Terminal())
        } catch let error as CheckerCLIError {
            FileHandle.standardError.write(Data("\(error.message)\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    /// The person at the Mac, and the Mac's pasteboard.
    struct Terminal {
        var input: () -> String? = { readLine(strippingNewline: true) }
        /// Asks on the controlling terminal, so a PSBT piped on stdin cannot answer.
        var confirm: (String) -> String? = { prompt in
            FileHandle.standardError.write(Data(prompt.utf8))
            guard let tty = fopen("/dev/tty", "r") else { return nil }
            defer { fclose(tty) }
            var line: UnsafeMutablePointer<CChar>?
            var capacity = 0
            guard getline(&line, &capacity, tty) > 0, let line else { return nil }
            defer { free(line) }
            return String(cString: line).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var output: (String) -> Void = { print($0) }
        var paste: () throws -> String = { try run("/usr/bin/pbpaste") }
        var copy: (String) throws -> Void = { _ = try run("/usr/bin/pbcopy", input: $0) }
    }

    static func execute(_ arguments: [String], terminal: Terminal) throws {
        guard let command = arguments.first, !["help", "--help", "-h"].contains(command) else {
            return terminal.output(usage)
        }
        var options = try Options(Array(arguments.dropFirst()))
        switch command {
        case "new-key":
            let key = try randomKey()
            try writeKey(key, to: options.required("--key-file"))
            terminal.output("""
            2FA secret written to \(try options.required("--key-file")) (only you can read it).
            Load it onto the card from this Mac only, with pysatochip:
              satochip_cli.py satochip-import-unencrypted-2fa-key
            and enter: \(key.hex)
            """)
        case "import-key":
            guard let line = terminal.input(), let key = Data(hex: line), key.count == 20 else {
                throw CheckerCLIError("expected the 20-byte 2FA secret in hex on standard input")
            }
            try writeKey(key, to: options.required("--key-file"))
            terminal.output("2FA secret written to \(try options.required("--key-file")).")
        case "register":
            let destination = try options.required("--config")
            let config = try register(&options)
            try options.finishNoExtras()
            try JSONEncoder.pretty.encode(config).write(to: URL(fileURLWithPath: destination))
            let checker = try config.checker()
            terminal.output("""
            Registered. Compare these with Winnow on the phone before funding the account:
              card key:      \(config.cardKeyExpression)
              first address: \(try checker.account.address(index: 0))
            """)
        case "review", "approve":
            let config = try Config.load(options.required("--config"))
            let psbt = try readPSBT(&options, terminal: terminal)
            let shouldCopy = options.flag("--copy")
            try options.finishNoExtras()
            let checker = try config.checker()
            let review = try checker.review(psbt)
            terminal.output(render(review, network: config.network))
            guard command == "approve" else { return }
            guard review.isReadyToApprove else {
                throw CheckerCLIError("every participant must add a nonce before this payment can be approved")
            }
            guard terminal.confirm("Type APPROVE to let the card sign this payment: ") == "APPROVE" else {
                throw CheckerCLIError("not approved")
            }
            let text = try checker.approve(psbt).text
            terminal.output("\nApprovals (paste into Winnow):\n\(text)")
            if shouldCopy {
                try terminal.copy(text)
                terminal.output("\nCopied to the pasteboard.")
            }
        default:
            throw CheckerCLIError("unknown command \(command)\n\n\(usage)")
        }
    }

    static let usage = """
    winnow-checker: approves what a Satochip card signs for a Winnow MuSig2 account

      winnow-checker new-key --key-file PATH
      winnow-checker import-key --key-file PATH            (hex secret on standard input)
      winnow-checker register --config PATH --key-file PATH --network signet|mainnet
          --descriptor 'tr(musig(...)/<0;1>/*)' --card-master-xpub XPUB --card-account-xpub XPUB
          [--card-path "m/86'/1'/0'"] [--search-limit N]
      winnow-checker review --config PATH [--psbt FILE | --paste]
      winnow-checker approve --config PATH [--psbt FILE | --paste] [--copy]

    Without --psbt or --paste the PSBT (Base64) is read from standard input.
    """

    // MARK: - Configuration

    struct Config: Codable, Equatable {
        var network: String
        var descriptor: String
        var cardKeyExpression: String
        var cardKey: String
        var keyFile: String
        var searchLimit: UInt32

        static func load(_ path: String) throws -> Config {
            do {
                return try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            } catch {
                throw CheckerCLIError("cannot read the checker config \(path): \(error.localizedDescription)")
            }
        }

        var bitcoinNetwork: BitcoinNetwork {
            get throws {
                switch network {
                case "mainnet": .mainnet
                case "signet": .signet
                default: throw CheckerCLIError("unsupported network \(network)")
                }
            }
        }

        func checker() throws -> Satochip.Checker {
            guard let key = try? Data(contentsOf: URL(fileURLWithPath: keyFile)), key.count == 20 else {
                throw CheckerCLIError("cannot read the 20-byte 2FA secret from \(keyFile)")
            }
            guard let card = Data(hex: cardKey) else { throw CheckerCLIError("invalid card key in the config") }
            return try Satochip.Checker(descriptor: descriptor, network: bitcoinNetwork, cardKey: card,
                                        twoFactorKey: key, searchLimit: searchLimit)
        }
    }

    static func register(_ options: inout Options) throws -> Config {
        let network = try options.required("--network")
        let config = Config(network: network, descriptor: "", cardKeyExpression: "", cardKey: "",
                            keyFile: try options.required("--key-file"), searchLimit: 500)
        let hdNetwork: HDKey.Network = try config.bitcoinNetwork == .mainnet ? .mainnet : .testnet
        let path = try parsePath(options.value("--card-path") ?? "m/86'/\(hdNetwork == .mainnet ? 0 : 1)'/0'")
        let expression = try Satochip.Checker.cardKeyExpression(
            masterXpub: options.required("--card-master-xpub"), accountXpub: options.required("--card-account-xpub"),
            path: path, network: hdNetwork)
        let descriptor = try options.required("--descriptor")
        // The card's key, as this Mac read it, must appear verbatim in the
        // phone's descriptor: same key, same origin.
        guard descriptor.contains(expression) else {
            throw CheckerCLIError("the descriptor does not contain the card key \(expression)")
        }
        let accountKey = try HDKey.deserialize(options.required("--card-account-xpub")).publicKey
        var registered = config
        registered.descriptor = descriptor
        registered.cardKeyExpression = expression
        registered.cardKey = accountKey.hex
        if let limit = options.value("--search-limit") {
            guard let value = UInt32(limit), value > 0 else { throw CheckerCLIError("invalid --search-limit") }
            registered.searchLimit = value
        }
        _ = try registered.checker() // the key file and the account must both work
        return registered
    }

    // MARK: - Input and output

    static func readPSBT(_ options: inout Options, terminal: Terminal) throws -> PSBT {
        let text: String
        if let file = options.value("--psbt") {
            text = try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
        } else if options.flag("--paste") {
            text = try terminal.paste()
        } else {
            var lines: [String] = []
            while let line = terminal.input() { lines.append(line) }
            text = lines.joined()
        }
        do {
            return try PSBT(base64: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            throw CheckerCLIError("not a PSBT: \(error)")
        }
    }

    static func render(_ review: Satochip.Checker.Review, network: String) -> String {
        var lines = ["Payment \(review.txid) (\(network))", "", "Spends:"]
        for input in review.inputs {
            let chain = input.chain == .receive ? "receive" : "change"
            lines.append("  \(sats(input.amount))  \(input.txid):\(input.vout)  (\(chain) address \(input.index))")
        }
        lines.append("")
        lines.append("Pays:")
        for output in review.outputs {
            let label = output.isAccountOwned ? "back to this account" : "AWAY"
            lines.append("  \(sats(output.amount))  \(output.address ?? output.scriptPubKey.hex)  \(label)")
        }
        lines.append("")
        lines.append("Leaves the account: \(sats(review.sentAway)) plus a fee of \(sats(review.fee))")
        if !review.isReadyToApprove { lines.append("Waiting for every participant's nonce.") }
        return lines.joined(separator: "\n")
    }

    static func sats(_ amount: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "\(amount)") sat"
    }

    static func parsePath(_ text: String) throws -> [UInt32] {
        let parts = text.split(separator: "/")
        guard parts.first == "m" else { throw CheckerCLIError("a path starts with m/") }
        return try parts.dropFirst().map { part in
            let hardened = part.hasSuffix("'") || part.hasSuffix("h")
            guard let value = UInt32(hardened ? part.dropLast() : part), value < HDKey.hardenedOffset else {
                throw CheckerCLIError("invalid path step \(part)")
            }
            return hardened ? value + HDKey.hardenedOffset : value
        }
    }

    static func randomKey() throws -> Data {
        var key = Data(count: 20)
        let status = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 20, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CheckerCLIError("no secure random bytes") }
        return key
    }

    static func writeKey(_ key: Data, to path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else {
            throw CheckerCLIError("\(path) exists; a 2FA secret is never overwritten")
        }
        guard FileManager.default.createFile(atPath: path, contents: key, attributes: [.posixPermissions: 0o600]) else {
            throw CheckerCLIError("cannot write \(path)")
        }
    }

    @discardableResult
    static func run(_ executable: String, input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        let output = Pipe()
        process.standardOutput = output
        let stdin = Pipe()
        if input != nil { process.standardInput = stdin }
        try process.run()
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

struct CheckerCLIError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// `--name value` pairs and `--flag`s, each used once.
struct Options {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    private static let flagNames: Set<String> = ["--paste", "--copy"]

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let name = arguments[index]
            guard name.hasPrefix("--"), values[name] == nil, !flags.contains(name) else {
                throw CheckerCLIError("unexpected argument \(name)\n\n\(WinnowChecker.usage)")
            }
            if Self.flagNames.contains(name) {
                flags.insert(name)
                index += 1
            } else {
                guard index + 1 < arguments.count else { throw CheckerCLIError("\(name) needs a value") }
                values[name] = arguments[index + 1]
                index += 2
            }
        }
    }

    mutating func value(_ name: String) -> String? { values.removeValue(forKey: name) ?? used[name] }

    mutating func required(_ name: String) throws -> String {
        guard let value = value(name) else { throw CheckerCLIError("missing \(name)\n\n\(WinnowChecker.usage)") }
        used[name] = value
        return value
    }

    mutating func flag(_ name: String) -> Bool { flags.remove(name) != nil }

    /// Throws for options that no step of the command read.
    func finishNoExtras() throws {
        guard values.isEmpty, flags.isEmpty else {
            let extra = (Array(values.keys) + Array(flags)).sorted().joined(separator: ", ")
            throw CheckerCLIError("unexpected \(extra)\n\n\(WinnowChecker.usage)")
        }
    }

    private var used: [String: String] = [:]
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
