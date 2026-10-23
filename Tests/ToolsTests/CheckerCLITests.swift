import Foundation
import NativeSecp256k1
import Testing
import TestSupport
import WalletCore
@testable import WinnowChecker

/// `winnow-checker`: registration from the xpubs the setup tool read, and an
/// approval that needs the person to type APPROVE.
@Suite("Satochip checker CLI")
struct CheckerCLITests {
    static let cardSeed = Data(repeating: 0x2C, count: 32)
    static let pin = Data("1234".utf8)
    static let twoFactorKey = Data(hex: "00112233445566778899aabbccddeeff01234567")!
    static let cardPath: [UInt32] = [86 + HDKey.hardenedOffset, 1 + HDKey.hardenedOffset, HDKey.hardenedOffset]

    final class Captured: @unchecked Sendable {
        var lines: [String] = []
    }

    static func terminal(_ captured: Captured, confirm: String?) -> WinnowChecker.Terminal {
        var terminal = WinnowChecker.Terminal()
        terminal.input = { nil }
        terminal.confirm = { _ in confirm }
        terminal.output = { captured.lines.append($0) }
        terminal.paste = { "" }
        terminal.copy = { _ in }
        return terminal
    }

    /// A registered checker and a spend with every nonce attached.
    static func registeredSpend(in directory: URL) async throws -> (config: String, psbt: String) {
        let master = try HDKey(seed: cardSeed)
        let phone = try TestKeys.master(entropyByte: 0xA1)
        let cardExpression = try Satochip.Checker.cardKeyExpression(
            masterXpub: master.neutered.serialized(network: .testnet),
            accountXpub: try master.derived(path: cardPath).neutered.serialized(network: .testnet),
            path: cardPath, network: .testnet)
        let descriptor = "tr(musig(\(try TestKeys.bareKeyExpression(master: phone)),\(cardExpression))/<0;1>/*)"
        let keyFile = directory.appending(path: "2fa.key").path
        try WinnowChecker.writeKey(twoFactorKey, to: keyFile)
        let config = directory.appending(path: "checker.json").path
        let captured = Captured()
        try WinnowChecker.execute(
            ["register", "--config", config, "--key-file", keyFile, "--network", "signet", "--descriptor", descriptor,
             "--card-master-xpub", master.neutered.serialized(network: .testnet),
             "--card-account-xpub", try master.derived(path: cardPath).neutered.serialized(network: .testnet),
             "--search-limit", "20"],
            terminal: terminal(captured, confirm: nil))
        let account = try MuSig2Account(descriptor, network: .signet)
        #expect(captured.lines.joined().contains(try account.address(index: 0)))

        // The phone's round 1, with the card's nonces from an emulated card.
        let coin = WalletUTXO(txid: Data(repeating: 0x5A, count: 32), vout: 0, amount: 40_000,
                              scriptPubKey: try account.scriptPubKey(index: 1, choice: 0), chain: .receive,
                              index: 1, height: 100)
        let destination = Data([0x51, 0x20] + repeatElement(0x77, count: 32))
        var psbt = try account.createSpend(utxos: [coin], payments: [Payment(amount: 25_000, scriptPubKey: destination)],
                                           changeIndex: 0, feeRateSatPerVByte: 2, chainTip: testChainTip,
                                           randomness: { 0.5 })
        let owned = [MuSig2Account.OutputCoordinate(choice: 1, index: 0)]
        _ = try account.attachNonces(&psbt, signingKey: phone, knownUTXOs: [coin], ownedOutputCoordinates: owned,
                                     chainTip: testChainTip)
        let card = SatochipEmulator(pin: pin, seed: cardSeed, twoFactorKey: twoFactorKey)
        var session = Satochip.Session(transport: card)
        try await session.connect(pin: pin)
        try await session.derive(path: cardPath)
        let cardKey = try await session.derivedPublicKey()
        var nonces: [Int: Data] = [:]
        for request in try account.cardNonceRequests(psbt, participant: cardKey, knownUTXOs: [coin],
                                                     ownedOutputCoordinates: owned, chainTip: testChainTip) {
            nonces[request.input] = try await session.generateNonce(aggregateKey: request.aggregateKey,
                                                                    message: request.message).publicNonce
        }
        try account.attachCardNonces(&psbt, participant: cardKey, publicNonces: nonces, knownUTXOs: [coin])
        let psbtFile = directory.appending(path: "spend.psbt")
        try Data(psbt.base64.utf8).write(to: psbtFile)
        return (config, psbtFile.path)
    }

    @Test("approve shows the payment and prints approvals only after APPROVE")
    func approve() async throws {
        let directory = TempDir()
        let (config, psbtFile) = try await Self.registeredSpend(in: directory.url)

        let refused = Captured()
        #expect(throws: CheckerCLIError.self) {
            try WinnowChecker.execute(["approve", "--config", config, "--psbt", psbtFile],
                                      terminal: Self.terminal(refused, confirm: "yes"))
        }
        #expect(refused.lines.joined().contains("AWAY"))
        #expect(!refused.lines.joined().contains(Satochip.Approvals.header))

        let approved = Captured()
        try WinnowChecker.execute(["approve", "--config", config, "--psbt", psbtFile],
                                  terminal: Self.terminal(approved, confirm: "APPROVE"))
        let output = approved.lines.joined(separator: "\n")
        let text = try #require(output.components(separatedBy: "Approvals (paste into Winnow):\n").last)
        let approvals = try Satochip.Approvals(text: text)
        let psbt = try PSBT(base64: String(contentsOfFile: psbtFile, encoding: .utf8))
        let checker = try WinnowChecker.Config.load(config).checker()
        #expect(approvals == (try checker.approve(psbt)))
    }

    @Test("registration refuses a descriptor without the card's key; a 2FA secret is never overwritten")
    func refusals() throws {
        let directory = TempDir()
        let keyFile = directory.url.appending(path: "2fa.key").path
        try WinnowChecker.writeKey(Self.twoFactorKey, to: keyFile)
        #expect(throws: CheckerCLIError.self) { try WinnowChecker.writeKey(Self.twoFactorKey, to: keyFile) }
        let attributes = try FileManager.default.attributesOfItem(atPath: keyFile)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let master = try HDKey(seed: Self.cardSeed)
        let phones = try TestKeys.masters()
        let descriptor = "tr(musig(\(try TestKeys.bareKeyExpression(master: phones[0])),"
            + "\(try TestKeys.bareKeyExpression(master: phones[1])))/<0;1>/*)"
        #expect(throws: CheckerCLIError.self) {
            try WinnowChecker.execute(
                ["register", "--config", directory.url.appending(path: "c.json").path, "--key-file", keyFile,
                 "--network", "signet", "--descriptor", descriptor,
                 "--card-master-xpub", master.neutered.serialized(network: .testnet),
                 "--card-account-xpub", try master.derived(path: Self.cardPath).neutered.serialized(network: .testnet)],
                terminal: Self.terminal(Captured(), confirm: nil))
        }
        #expect(try WinnowChecker.parsePath("m/86'/1'/0'") == Self.cardPath)
        #expect(throws: CheckerCLIError.self) { try WinnowChecker.parsePath("86'/1'") }
    }
}
