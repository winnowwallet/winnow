import Foundation
import P256K
import TestSupport
import WalletCore
import XCTest
import UIKit

/// Smoke probe: the whole suite hinges on the iOS-simulator test runner
/// being able to spawn host processes (bitcoin-cli mining, pasteboard
/// copies). Runs first (alphabetical) and fails fast.
@MainActor
final class HostProcessProbeTests: XCTestCase {
    func test00CanSpawnHostProcesses() throws {
        WinnowAppJourney.forgetStories()
        let echo = try HostProcess.run("/bin/echo", ["host-spawn-ok"])
        XCTAssertEqual(echo.status, 0)
        XCTAssertEqual(echo.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "host-spawn-ok")
        // The UI job starts its own fixture at genesis, so height 0 is a
        // reachable node; only a non-numeric answer means it is not there.
        let node = try BitcoinCLI.run(["getblockcount"])
        let height = Int(node.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertNotNil(height, "local signet node unreachable: \(node)")
        XCTAssertGreaterThanOrEqual(height ?? -1, 0)
    }
}

/// Makes the fixture's bank on a fresh chain and nothing else, so that
/// `scripts/signet-fixture snapshot` can keep it as the template CI starts
/// from. Not a journey; run it by name:
/// `-only-testing:WinnowAppUITests/FixtureBankTests`.
@MainActor
final class FixtureBankTests: XCTestCase {
    func testMineTheBank() async throws {
        try await WinnowAppJourney.ensureBank()
        XCTAssertGreaterThanOrEqual(try BitcoinCLI.trustedBalanceSats(wallet: WinnowAppJourney.bankWallet), 1_000_000_000)
    }
}

/// End-to-end UI tests against the local custom-signet node (default datadir
/// ~/.bitcoin-mysignet, P2P 127.0.0.1:38401 — overridable via the
/// WINNOW_NODE_HOST/WINNOW_P2P_PORT/WINNOW_RPC_PORT/WINNOW_DATADIR
/// environment variables, see Tests/Support/Node/BitcoinCLI.swift). The app is launched with
/// WINNOW_E2E=1 (see Sources/WinnowApp/E2EMode.swift): throwaway storage
/// and Keychain namespace, custom-signet params, the node as manual peer, and
/// a fixed wallet entropy for reproducible screenshots.
///
/// The journeys are grouped into four stories (the `Story…` classes below),
/// each a wallet the story's journeys share, run in alphabetical order —
/// XCTest's order within a class — so a later journey builds on what an
/// earlier one left behind rather than making it again. The first failure
/// in a story blocks the rest of it, as failures, never skips
/// (`scripts/check-test-gates`). CI runs one story per runner.
///
/// Money comes from a "bank": one node wallet mined to maturity once per
/// fixture, which then pays wallets and vaults with an ordinary transaction
/// and a single block. A coinbase paid to the wallet under test would need a
/// hundred more blocks to mature, and the old suite mined five of those.
@MainActor
class WinnowAppJourney: XCTestCase {
    /// Fixed 16-byte entropy → the same mnemonic/addresses every run.
    nonisolated static let entropyHex = "000102030405060708090a0b0c0d0e0f"
    nonisolated static let mnemonic = try! BIP39.mnemonic(entropy: Data(hex: entropyHex)!)

    /// Facts about the payment that funded the fixed-entropy wallet: written
    /// by test02 and by the paying-people story's preparation, read by test06
    /// to build its import bundle. Persisted to the runner's temp dir because
    /// a crashed/restarted runner process loses statics.
    struct FundingInfo: Codable {
        var txid: String // display hex
        var vout: UInt32
        var amount: Int64
        var scriptPubKey: String // hex
        var height: Int
        var index: UInt32 // receive-chain index of the funded address
    }
    nonisolated(unsafe) static var funding: FundingInfo?

    static var fundingFile: URL {
        FileManager.default.temporaryDirectory.appending(path: "winnow-e2e-funding.json")
    }

    static func saveFunding(_ info: FundingInfo) {
        funding = info
        try? JSONEncoder().encode(info).write(to: fundingFile)
    }

    static func loadFunding() -> FundingInfo? {
        if let funding { return funding }
        guard let data = try? Data(contentsOf: fundingFile) else { return nil }
        funding = try? JSONDecoder().decode(FundingInfo.self, from: data)
        return funding
    }

    // MARK: - Stories

    /// The E2E run (storage namespace) the story's wallet lives in; the
    /// default for `launchApp`.
    class var runName: String { "main" }

    /// What the story needs before its first journey: at least the bank,
    /// usually a wallet with money in it. Runs once per story, on the first
    /// journey's set-up.
    class func prepare(_ journey: WinnowAppJourney) async throws {
        try await ensureBank()
    }

    struct StoryBlocked: Error, CustomStringConvertible {
        let story: String
        let by: String
        var description: String { "\(story) is blocked: \(by) failed earlier in the story" }
    }

    /// Which stories are prepared and which are blocked, by class name.
    /// Kept in a file as well as in memory: a failure inside an async test
    /// with `continueAfterFailure` off ends the runner process (exit 75) and
    /// xcodebuild starts a new one for the remaining tests, which would
    /// otherwise prepare the story again and forget what had failed.
    private struct StoryState: Codable {
        var prepared: Set<String> = []
        var blocked: [String: String] = [:]
    }
    private static var storyStateURL: URL {
        FileManager.default.temporaryDirectory.appending(path: "winnow-e2e-stories.json")
    }
    private static var storyState: StoryState = {
        (try? JSONDecoder().decode(StoryState.self, from: Data(contentsOf: storyStateURL))) ?? StoryState()
    }() {
        didSet { try? JSONEncoder().encode(storyState).write(to: storyStateURL) }
    }
    private static var blockedStories: [String: String] {
        get { storyState.blocked }
        set { storyState.blocked = newValue }
    }
    private static var preparedStories: Set<String> {
        get { storyState.prepared }
        set { storyState.prepared = newValue }
    }
    private var story: String { String(describing: type(of: self)) }

    /// A new run starts with no story prepared or blocked; the probe calls
    /// this first so a file left by an earlier run cannot skip preparation.
    static func forgetStories() {
        storyState = StoryState()
    }

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 600
        if let failed = Self.blockedStories[story] {
            throw StoryBlocked(story: story, by: failed)
        }
        guard !Self.preparedStories.contains(story) else { return }
        Self.preparedStories.insert(story)
        do {
            try await Self.prepare(self)
        } catch {
            Self.blockedStories[story] = "preparation"
            throw error
        }
    }

    /// The first failure a story's journey records blocks the journeys after
    /// it. Recorded here rather than read back from the run in `tearDown`,
    /// whose counters do not yet include the test that just failed. Only
    /// failures count: a runtime warning (the QoS inversion the host-process
    /// bridge triggers) is recorded through the same path and must not.
    override func record(_ issue: XCTIssue) {
        switch issue.type {
        case .assertionFailure, .thrownError, .uncaughtException:
            if Self.blockedStories[story] == nil { Self.blockedStories[story] = name }
        default:
            break
        }
        super.record(issue)
    }

    // MARK: - The bank

    nonisolated static let bankWallet = "ui-bank"

    /// Mines the bank to maturity once per fixture chain: 101 blocks, in
    /// place of the hundred blocks each funded test used to mine for itself.
    /// On CI the fixture starts from a snapshot taken after this ran
    /// (`scripts/signet-fixture snapshot`), so the balance check is all that
    /// happens there; `FixtureBankTests` makes such a snapshot. Off the main
    /// actor: every block is several host-process round trips, and a runner
    /// whose main thread is blocked for minutes has been killed for it.
    nonisolated static func ensureBank() async throws {
        try await Task.detached(priority: .userInitiated) {
            try BitcoinCLI.ensureWallet(bankWallet)
            guard try BitcoinCLI.trustedBalanceSats(wallet: bankWallet) < 1_000_000_000 else { return }
            let script = try AddressDecoder.scriptPubKey(for: BitcoinCLI.newAddress(wallet: bankWallet), network: .signet)
            for _ in 0 ..< 101 { try await SignetMiner.mineOntoTip(payingTo: script) }
        }.value
    }

    /// The bank pays `address` and one block confirms it. Returns the
    /// confirmed output as the node's UTXO set reports it.
    nonisolated static func fundFromBank(_ address: String, sats: Int64) async throws
        -> (txid: String, vout: UInt32, amount: Int64, height: UInt32) {
        try await Task.detached(priority: .userInitiated) {
            let txid = try BitcoinCLI.sendToAddress(wallet: bankWallet, address: address, sats: sats, feeRate: 2)
            let payout = try AddressDecoder.scriptPubKey(for: fixtureAddress(0xD4), network: .signet)
            try await SignetMiner.mineOntoTip(payingTo: payout)
            let script = try AddressDecoder.scriptPubKey(for: address, network: .signet)
            guard let coin = try BitcoinCLI.unspents(scriptHex: script.hex).first(where: { $0.txid == txid }) else {
                throw StoryBlocked(story: "bank", by: "the bank's payment \(txid) did not confirm")
            }
            return coin
        }.value
    }

    /// A wallet made through onboarding and paid by the bank, for the
    /// stories that begin past the first wallet.
    static func createFundedWallet(_ journey: WinnowAppJourney) async throws {
        try await ensureBank()
        let app = journey.launchApp(reset: true, expectOnboarding: true)
        app.buttons["createWalletButton"].tap()
        XCTAssertTrue(journey.backupConfirmationIsReachable(app), "backup sheet did not appear after create")
        XCTAssertTrue(journey.confirmBackupAndContinue(app), "backup confirmation was not completed")
        XCTAssertTrue(app.staticTexts["balanceText"].waitForExistence(timeout: 60), "home did not appear")
        _ = try await fundFromBank(try walletReceiveAddress(index: 0), sats: 5_000_000)
        XCTAssertTrue(journey.poll(timeout: 180, interval: 2, "the story's wallet sees its money") {
            journey.nudgeSync(app)
            let balance = journey.balanceText(app)
            return balance != "0 sats" && balance != ""
        })
        app.terminate()
    }

    // MARK: - Launch

    /// Launches the app in E2E mode against the local node and waits for the
    /// wallet shell (balance visible) unless onboarding is expected.
    @discardableResult
    func launchApp(run: String? = nil, reset: Bool = false, clipboard: String? = nil,
                   expectOnboarding: Bool = false,
                   configureLocalNode: Bool = true,
                   advanced: Bool = false,
                   environment: [String: String] = [:],
                   entropy: String = WinnowAppJourney.entropyHex) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "WINNOW_E2E": "1",
            "WINNOW_E2E_RUN": run ?? Self.runName,
            "WINNOW_E2E_ENTROPY": entropy,
        ]
        // Advanced mode on from the first frame, so a test can reach the
        // expert controls without tapping through Settings.
        if advanced { app.launchEnvironment["WINNOW_E2E_ADVANCED"] = "1" }
        if configureLocalNode {
            app.launchEnvironment["WINNOW_E2E_PEER"] =
                "\(BitcoinCLI.nodeHost):\(BitcoinCLI.p2pPort)"
            app.launchEnvironment["WINNOW_E2E_CHALLENGE"] = BitcoinCLI.challengeHex
        }
        if reset { app.launchEnvironment["WINNOW_E2E_RESET"] = "1" }
        if let clipboard { app.launchEnvironment["WINNOW_E2E_CLIPBOARD"] = clipboard }
        app.launchEnvironment.merge(environment) { _, new in new }
        removeStagedExports()
        app.launch()
        if expectOnboarding {
            XCTAssertTrue(app.buttons["createWalletButton"].waitForExistence(timeout: 120),
                          "onboarding did not appear")
        } else {
            XCTAssertTrue(app.staticTexts["balanceText"].waitForExistence(timeout: 120),
                          "wallet home did not appear")
        }
        return app
    }

    /// The simulator's data directory on the host, from the runner's own
    /// environment. Not `simctl`: the runner lives inside the simulator, and
    /// from there `simctl` cannot reach CoreSimulatorService on every host
    /// (the CI runner refuses the connection).
    static var simulatorDataDirectory: String? {
        let environment = ProcessInfo.processInfo.environment
        if let shared = environment["SIMULATOR_SHARED_RESOURCES_DIRECTORY"] { return shared }
        if let home = environment["SIMULATOR_HOST_HOME"], let device = environment["SIMULATOR_UDID"] {
            return home + "/Library/Developer/CoreSimulator/Devices/" + device + "/data"
        }
        return nil
    }

    /// Where every app on this simulator keeps its container; only Winnow
    /// stages `winnow-export-*` directories, so the app need not be singled out.
    static var applicationContainers: String? {
        simulatorDataDirectory.map { $0 + "/Containers/Data/Application" }
    }

    /// A backup export stages its file under the app container's tmp and
    /// removes it on Close. A test that fails with the sheet open leaves it
    /// there, and `stagedBackup()` expects exactly one file, so the next
    /// export in a later test would fail for the earlier test's reason.
    /// Sweep before every launch; no container yet is fine.
    fileprivate func removeStagedExports() {
        guard let containers = Self.applicationContainers else { return }
        _ = try? HostProcess.run("/usr/bin/find", [containers, "-maxdepth", "3", "-path", "*/tmp/winnow-export-*",
                                                   "-type", "d", "-prune", "-exec", "rm", "-rf", "{}", "+"])
    }

    // MARK: - 04 Vaults

    /// A deterministic cosigner key expression ([fp/86'/1'/0']tpub…/<0;1>/*)
    /// from a one-byte repeated seed — a fixture, not a real cosigner.
    nonisolated static func fixtureCosigner(_ byte: UInt8) throws -> String {
        let master = try HDKey(seed: Data(repeating: byte, count: 64))
        let account = try BIP86.accountKey(from: master, coinType: 1, account: 0)
        let fingerprint = String(format: "%08x", master.fingerprint)
        return "[\(fingerprint)/86'/1'/0']\(account.neutered.serialized(network: .testnet))/<0;1>/*"
    }

    /// The fixed-entropy test wallet's own key expression — the same text
    /// "Add this device's key" produced in test04 (AppModel.ownKeyExpression).
    nonisolated static func deviceKeyExpression() throws -> String {
        let master = try HDKey(seed: BIP39.seed(mnemonic: mnemonic))
        let account = try BIP86.accountKey(from: master, coinType: 1, account: 0)
        let fingerprint = String(format: "%08x", master.fingerprint)
        return "[\(fingerprint)/86'/1'/0']\(account.neutered.serialized(network: .testnet))/<0;1>/*"
    }

    /// A deterministic signet P2TR address from a one-byte repeated seed
    /// (fixture send destination / block payout).
    nonisolated static func fixtureAddress(_ byte: UInt8) throws -> String {
        let master = try HDKey(seed: Data(repeating: byte, count: 64))
        let account = try BIP86.accountKey(from: master, coinType: 1, account: 0)
        return try BIP86.address(internalKey: account.publicKey.dropFirst(), hrp: "tb")
    }

    /// The fixed-entropy test wallet's receive address at `index`
    /// (m/86'/1'/0'/0/index, signet).
    nonisolated static func walletReceiveAddress(index: UInt32) throws -> String {
        let master = try HDKey(seed: BIP39.seed(mnemonic: mnemonic))
        let account = try BIP86.accountKey(from: master, coinType: 1, account: 0)
        let key = try account.derived(path: "0/\(index)")
        return try BIP86.address(internalKey: key.publicKey.dropFirst(), hrp: "tb")
    }

    fileprivate func reviewFromAccount(_ app: XCUIApplication, name: String, address: String, amount: String,
                                   chooseInSend: Bool = false) {
        if chooseInSend {
            app.navigationTab("Send").tap()
            if app.buttons["newPaymentButton"].exists { app.buttons["newPaymentButton"].tap() }
            let picker = app.buttons["sendAccountPicker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 20))
            picker.tap()
            app.buttons[name].firstMatch.tap()
        } else {
            XCTAssertTrue(scrollUntilExists(app, app.buttons["sendFromAccountButton"]))
            app.buttons["sendFromAccountButton"].tap()
        }
        XCTAssertTrue(app.navigationTab("Send").isSelected)
        app.typeInto("destinationField", address)
        app.typeInto("amountField", amount)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["reviewButton"]))
        app.buttons["reviewButton"].tap()
        XCTAssertTrue(app.staticTexts["reviewAccount"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["reviewAccount"].label, name)
        XCTAssertEqual(app.staticTexts["reviewDestination"].label, address)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["sendButton"]))
        XCTAssertEqual(app.buttons["sendButton"].label, "Continue to approvals")
    }

    /// Saves the person sheet. A wallet that already knows people lists them
    /// above the form, so Save can sit below the fold: scroll to it first.
    fileprivate func savePerson(in app: XCUIApplication) {
        let save = app.buttons["savePersonButton"]
        XCTAssertTrue(scrollUntilExists(app, save, maxSwipes: 6), "no Save on the person sheet")
        save.tap()
    }

    fileprivate func openPayment(_ txid: String, in app: XCUIApplication) {
        let row = app.buttons["historyPayment-\(txid)"]
        XCTAssertTrue(scrollUntilExists(app, row, maxSwipes: 12), "payment missing from Wallet")
        row.tap()
    }

    fileprivate func addPastedRecipient(_ name: String, in app: XCUIApplication) {
        let row = app.buttons["chooseRecipient-\(name)"]
        if row.exists { return }
        app.buttons["addRecipientButton"].tap()
        XCTAssertTrue(app.buttons["personPasteButton"].waitForExistence(timeout: 20))
        app.buttons["personPasteButton"].tap()
        XCTAssertTrue(app.staticTexts["personPayToSummary"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["personPayToSummary"].label, "Fresh address each payment")
        savePerson(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "recipient was not saved")
    }

    /// Alice's receive address at `index`, as her wallet would derive it from
    /// the fixture 0xA1 account key.
    nonisolated static func fixtureReceiveAddress(_ byte: UInt8, index: UInt32) throws -> String {
        let master = try HDKey(seed: Data(repeating: byte, count: 64))
        let account = try BIP86.accountKey(from: master, coinType: 1, account: 0)
        let key = try account.derived(path: "0/\(index)")
        return try BIP86.address(internalKey: key.publicKey.dropFirst(), hrp: "tb")
    }

    /// The group's half of the ceremony: BIP327 two rounds over the
    /// script-path sighash with the BIP328 derivation tweaks — the same
    /// simulation the CLI's musig-sign-psbt performs.
    fileprivate static func groupSign(base64: String, memberSecrets: [Data],
                                  synthetic: HDKey) throws -> String {
        var psbt = try PSBT(base64: base64)
        let memberKeys = try memberSecrets.map {
            try P256K.Signing.PrivateKey(dataRepresentation: $0).publicKey.dataRepresentation
        }
        let aggregate = try MuSig.aggregate(memberKeys)
        guard let leaf = psbt.inputs[0].tapLeafScripts.first else {
            throw NSError(domain: "group", code: 1)
        }
        guard let derivation = psbt.inputs[0].tapBIP32Derivation.first(where: {
            $0.value.masterFingerprint == synthetic.fingerprint
        }) else { throw NSError(domain: "group", code: 2) }
        var tweaks: [Data] = []
        var step = synthetic
        for component in derivation.value.path {
            tweaks.append(MuSig.bip328Tweak(chainCode: step.chainCode,
                                            aggregatePublicKey: step.publicKey,
                                            index: component))
            step = try step.derived(path: "\(component)")
        }
        let sighash = try SighashBIP341.sighash(
            tx: try psbt.unsignedTransaction(), inputIndex: 0,
            spentOutputs: try psbt.spentOutputs(), hashType: .default,
            scriptPath: .init(leafScript: Script(leaf.script), leafVersion: leaf.leafVersion))
        var nonces: [(secret: Data, public_: Data)] = []
        for (secret, publicKey) in zip(memberSecrets, memberKeys) {
            let nonce = try MuSig.nonceGenerate(secretKey: secret, publicKey: publicKey,
                                                aggregateKey: Data(aggregate.dropFirst()),
                                                message: sighash)
            nonces.append((nonce.secretNonce, nonce.publicNonce))
        }
        let session = MuSig.Session(
            aggregateNonce: try MuSig.nonceAggregate(publicNonces: nonces.map(\.public_)),
            publicKeys: memberKeys, tweaks: tweaks,
            isXOnlyTweaks: tweaks.map { _ in false }, message: sighash)
        var partials: [Data] = []
        for (index, secret) in memberSecrets.enumerated() {
            var secretNonce = nonces[index].secret
            partials.append(try MuSig.partialSign(secretNonce: &secretNonce, secretKey: secret,
                                                  session: session))
        }
        let signature = try MuSig.partialSigAggregate(partialSignatures: partials, session: session)
        psbt.inputs[0].pairs.append(PSBT.KeyValue(
            type: 0x14, keyData: Data(derivation.key) + leaf.leafHash, value: signature))
        return psbt.base64
    }

    /// Both account types use the same backup action and omit the phone key by default.
    /// The sheet no longer previews the JSON; read the staged file it offers to share.
    fileprivate func accountBackup(in app: XCUIApplication) throws -> ImportBundle {
        XCTAssertTrue(scrollUntilExists(app, app.buttons["accountBackupButton"]))
        app.buttons["accountBackupButton"].tap()
        XCTAssertTrue(app.buttons["exportConfirmButton"].waitForExistence(timeout: 20))
        app.buttons["exportConfirmButton"].tap()
        let backup = try stagedExport(in: app, expectingNote: "Recovery words are not included. Keep them separately.",
                                      "no staged share link after the account backup").bundle
        XCTAssertNil(backup.mnemonic, "the normal backup must not expose the phone key")
        // Close clears the staged file, so the next export is again the only one.
        app.buttons["Close"].tap()
        return backup
    }

    /// Waits for the export the sheet was just asked for and reads the staged
    /// backup it offers to share; the share link and the contents note render
    /// together once the file is written. Shared by the Settings and account
    /// backups so the next change to the sheet cannot desync them.
    fileprivate func stagedExport(in app: XCUIApplication, expectingNote expected: String,
                              _ message: String) throws -> (path: String, bundle: ImportBundle) {
        XCTAssertTrue(app.buttons["exportShareLink"].waitForExistence(timeout: 60), message)
        let note = app.staticTexts["backupContentsNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        XCTAssertEqual(note.label, expected)
        return try stagedBackup()
    }

    fileprivate func stagedBackup() throws -> (path: String, bundle: ImportBundle) {
        let containers = try XCTUnwrap(Self.applicationContainers, "no simulator data directory in the environment")
        let files = try HostProcess.run("/usr/bin/find", [containers, "-maxdepth", "4",
                                                          "-path", "*/tmp/winnow-export-*/*.json", "-type", "f"])
        XCTAssertEqual(files.status, 0, files.stderr)
        let paths = files.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(paths.count, 1, "expected exactly one staged backup file")
        let path = try XCTUnwrap(paths.first)
        let file = try HostProcess.run("/bin/cat", [path])
        XCTAssertEqual(file.status, 0, file.stderr)
        return (path, try ImportBundle.decode(json: file.stdout))
    }

    // MARK: - 17 Save sender from a received payment (mines)

    /// A fresh P2WPKH UTXO in the wallet: a payment that spends it reveals
    /// its funding address in the witness, which is what the sender sheet
    /// offers to attach.
    fileprivate func ensureSegwitUtxo(wallet: String) async throws -> (txid: String, vout: Int, address: String) {
        try await ensureUtxo(wallet: wallet, type: "bech32", sats: 400_000)
    }

    /// `send` with the input pinned, so the payment's funding type is a
    /// test fact rather than coin selection's mood.
    fileprivate func payFromNode(wallet: String, input utxo: (txid: String, vout: Int),
                             to address: String, sats: Int64) throws -> String {
        let amount = "\(sats / 100_000_000)." + String(format: "%08d", sats % 100_000_000)
        let result = try BitcoinCLI.runObject([
            "-named", "send",
            "outputs={\"\(address)\":\(amount)}",
            "inputs=[{\"txid\":\"\(utxo.txid)\",\"vout\":\(utxo.vout)}]",
        ], wallet: wallet)
        return try BitcoinCLI.string(result, "txid")
    }

    // MARK: - 18 Infer sender with the explorer (mines)

    /// Serves one canned Esplora `/tx` answer over loopback HTTP. The app
    /// treats it as its configured custom explorer; no test traffic leaves
    /// the machine.
    fileprivate final class StubExplorer {
        let directory: URL
        private(set) var port: UInt16 = 0
        private var processID: String?

        init() {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "winnow-stub-explorer-\(UUID().uuidString)")
        }

        /// The kernel assigns a free port and this fixture owns one server
        /// process. Concurrent journeys cannot kill or contact each other.
        func serve(txid: String, addresses: [String]) throws {
            stop()
            let txDir = directory.appending(path: "tx", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: txDir, withIntermediateDirectories: true)
            let vin = addresses.map { "{\"prevout\":{\"scriptpubkey_address\":\"\($0)\"}}" }
            try Data("{\"txid\":\"\(txid)\",\"vin\":[\(vin.joined(separator: ","))]}".utf8)
                .write(to: txDir.appending(path: txid))
            try start()
        }

        func catalog(_ data: Data) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: "peers.json"), options: .atomic)
            if processID == nil { try start() }
        }

        private func start() throws {
            let script = directory.appending(path: "server.py")
            try """
            import http.server, pathlib, os
            root = pathlib.Path(__file__).parent
            os.chdir(root)
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), http.server.SimpleHTTPRequestHandler)
            (root / 'port').write_text(str(server.server_port))
            server.serve_forever()
            """.write(to: script, atomically: true, encoding: .utf8)
            let result = try HostProcess.run("/bin/sh", ["-c",
                "/usr/bin/python3 '\(script.path)' >'\(directory.path)/requests.log' 2>&1 </dev/null & echo $!"])
            processID = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            for _ in 0..<100 where port == 0 {
                let value = try? String(contentsOf: self.directory.appending(path: "port"), encoding: .utf8)
                self.port = UInt16(value ?? "") ?? 0
                if port == 0 { Thread.sleep(forTimeInterval: 0.1) }
            }
            XCTAssertGreaterThan(port, 0, "the isolated explorer listener did not start")
        }

        func stop() {
            guard let processID, Int32(processID) != nil else { return }
            let command = try? HostProcess.run("/bin/ps", ["-p", processID, "-o", "command="]).stdout
            if command?.contains(directory.appending(path: "server.py").path) == true {
                _ = try? HostProcess.run("/bin/kill", [processID])
            }
            self.processID = nil
        }
        var baseURL: String { "http://127.0.0.1:\(port)" }
        var requestCount: Int {
            let log = (try? String(contentsOf: directory.appending(path: "requests.log"), encoding: .utf8)) ?? ""
            return log.components(separatedBy: "GET /tx/").count - 1
        }
    }

    /// Makes a fresh taproot UTXO in the wallet, sized to fund the test's
    /// payment: the input type whose key-path spend reveals nothing offline.
    fileprivate func ensureTaprootUtxo(wallet: String) async throws -> (txid: String, vout: Int, address: String) {
        try await ensureUtxo(wallet: wallet, type: "bech32m", sats: 200_000)
    }

    /// A fresh UTXO of the given address type, made by a self-transfer and
    /// one block. Never scavenges — the node's mempool may hold stale spends
    /// of any UTXO an aborted run left behind.
    fileprivate func ensureUtxo(wallet: String, type: String, sats: Int64) async throws
        -> (txid: String, vout: Int, address: String) {
        let address = try BitcoinCLI.run(["getnewaddress", "", type], wallet: wallet)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try BitcoinCLI.sendToAddress(wallet: wallet, address: address, sats: sats, feeRate: 1)
        // Mine only once the node itself holds the transaction: a template
        // built earlier would silently leave it behind.
        poll(timeout: 30, interval: 1, "self-transfer in the node's mempool") {
            ((try? BitcoinCLI.mempoolTxids().isEmpty) ?? true) == false
        }
        let payout = try AddressDecoder.scriptPubKey(for: Self.fixtureAddress(0xD7), network: .signet)
        try await SignetMiner.mineOntoTip(payingTo: payout)
        let coin = try XCTUnwrap(unspents(wallet: wallet, minConf: 1)
            .first { ($0["address"] as? String) == address }, "the self-transfer did not confirm")
        return (try BitcoinCLI.string(coin, "txid"), try BitcoinCLI.int(coin, "vout"), address)
    }

    fileprivate func unspents(wallet: String, minConf: Int) throws -> [[String: Any]] {
        try XCTUnwrap(BitcoinCLI.runJSON(["listunspent", "\(minConf)"], wallet: wallet)
                      as? [[String: Any]])
    }
}

/// Story A — Your first wallet: create it, receive, send, back it up, the beginner shell, an incoming payment.
@MainActor
final class StoryFirstWallet: WinnowAppJourney {

    // balanceText, nudgeSync and scrollUntilExists live in TestHelpers.swift,
    // shared across the app journeys.

    // MARK: - 01 Onboarding

    func test01OnboardingCreateWallet() throws {
        let app = launchApp(reset: true, expectOnboarding: true)
        Screenshots.capture(app, "01-onboarding", testCase: self)

        let createStart = Date()
        app.buttons["createWalletButton"].tap()
        // Backup is deliberately independent of peer/header catch-up.
        let toggle = app.switches["writtenDownToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "backup sheet did not appear promptly")
        XCTAssertTrue(app.buttons["backupCopyPhraseButton"].exists,
                      "backup sheet does not offer an explicit phrase copy")
        Timings.record("onboarding", step: "wallet-create", from: createStart)
        Screenshots.capture(app, "02-backup-mnemonic", testCase: self)

        // iOS 26: the toggle is a container switch element wrapping the real
        // UISwitch as a child — tapping the container/label does nothing.
        // Tap the child switch (right side of the row).
        let toggleThumb = toggle.children(matching: .switch).firstMatch
        let done = app.buttons["backupDoneButton"]
        // The switch reports its own state ("1" when on), so read that
        // rather than using Done's enablement as a proxy: on a 6.3-inch
        // class Done sits below the fold, and an off-screen Form row is not
        // in the accessibility tree at all.
        func toggleIsOn() -> Bool {
            let value = (toggleThumb.exists ? toggleThumb.value : toggle.value) as? String
            return value == "1"
        }
        let flipped = poll(timeout: 20, interval: 1, "written-down toggle on") {
            if toggleIsOn() { return true }
            _ = self.scrollUntilExists(app, toggle, maxSwipes: 4, up: true)
            app.flipSwitch(toggle)
            return toggleIsOn()
        }
        if !flipped {
            Screenshots.capture(app, "debug-01-backup", testCase: self)
            print("E2E debug: writtenDownToggle value = \(toggle.value ?? "nil")")
            print(app.debugDescription)
        }
        XCTAssertTrue(flipped, "the written-down toggle never read on")
        let backupStart = Date()
        XCTAssertTrue(scrollUntilExists(app, done, maxSwipes: 4), "backup Done button was not reachable")
        XCTAssertTrue(poll(timeout: 10, interval: 1, "backup Done button enabled") { done.isEnabled })
        done.tap()
        XCTAssertTrue(app.staticTexts["balanceText"].waitForExistence(timeout: 60),
                      "wallet home did not appear after backup")
        Timings.record("onboarding", step: "backup→home", from: backupStart)
    }

    // MARK: - 02 Receive + funding

    func test02ReceiveAndFunding() async throws {
        var app = launchApp()

        let receiveStart = Date()
        app.buttons["receiveButton"].tap()
        XCTAssertTrue(app.textFields["receiveAddressLabelField"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["receiveAddress"].exists, "sharing waits for a label or explicit skip")
        XCTAssertFalse(app.buttons["saveReceiveAddressLabelButton"].isEnabled)
        app.typeInto("receiveAddressLabelField", "Alice / invoice 12")
        Screenshots.capture(app, "54-receive-label-prompt", testCase: self)
        app.buttons["saveReceiveAddressLabelButton"].tap()
        let addressElement = app.staticTexts["receiveAddress"]
        XCTAssertTrue(addressElement.waitForExistence(timeout: 30), "no receive address")
        Timings.record("receive", step: "address-shown", from: receiveStart)
        Screenshots.capture(app, "03-receive", testCase: self)
        guard let address = addressElement.value as? String, address.hasPrefix("tb1") else {
            XCTFail("could not read the receive address from the UI")
            return
        }
        XCTAssertEqual(app.staticTexts["receiveAddressLabel"].label, "Alice / invoice 12")
        app.buttons["newReceiveAddressButton"].tap()
        XCTAssertTrue(app.textFields["receiveAddressLabelField"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["receiveAddressLabelField"].value as? String, "Alice · invoice 12",
                       "the new address must not inherit the previous label")
        app.buttons["skipReceiveAddressLabelButton"].tap()
        XCTAssertTrue(addressElement.waitForExistence(timeout: 10))
        let freshAddress = try XCTUnwrap(addressElement.value as? String)
        XCTAssertNotEqual(freshAddress, address)
        XCTAssertFalse(app.staticTexts["receiveAddressLabel"].exists)
        app.buttons["Done"].tap()
        app.terminate()
        app = launchApp()

        // Which receive-chain index did the app show? (It advances once an
        // address is used, so resolve it rather than assuming 0.)
        var fundingIndex: UInt32?
        for i: UInt32 in 0 ..< 10
        where try Self.walletReceiveAddress(index: i) == address { fundingIndex = i }
        guard let fundingIndex else {
            XCTFail("the displayed address is not index 0..<10 of the fixed-entropy wallet")
            return
        }

        // The bank pays the address and one block confirms it. The height is
        // read back from the node rather than assumed, because test06 builds
        // its import bundle from these facts.
        let script = try AddressDecoder.scriptPubKey(for: address, network: .signet)
        let fundStart = Date()
        let coin = try await Self.fundFromBank(address, sats: 5_000_000)
        Self.saveFunding(FundingInfo(txid: coin.txid, vout: coin.vout, amount: coin.amount,
                                     scriptPubKey: script.hex, height: Int(coin.height),
                                     index: fundingIndex))
        Timings.record("funding", step: "bank-payment-confirmed", from: fundStart)

        // Filters see blocks, not the mempool: poll (nudging "Sync now")
        // until the confirmed balance shows.
        let detectStart = Date()
        poll(timeout: 300, interval: 2, "confirmed balance after funding") {
            self.nudgeSync(app)
            return self.balanceText(app) != "0 sats" && self.balanceText(app) != ""
        }
        Timings.record("funding", step: "mined→detected-by-filters", from: detectStart)
        // A history entry must be there too.
        XCTAssertTrue(app.staticTexts["Received"].waitForExistence(timeout: 60),
                      "no history entry after funding")
        let labelRow = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "paymentReceiveLabels-")).firstMatch
        XCTAssertTrue(labelRow.waitForExistence(timeout: 30))
        XCTAssertEqual(labelRow.label, "Alice / invoice 12", "payment to the old address keeps its label after rotation and relaunch")
        Screenshots.capture(app, "04-home-funded", testCase: self)
        labelRow.tap()
        XCTAssertTrue(app.staticTexts["Receive address labels"].waitForExistence(timeout: 10))
        Screenshots.capture(app, "55-payment-receive-label", testCase: self)
    }

    // MARK: - 03 Send

    func test03Send() async throws {
        // Send 0.01 BTC back out to a fixture address derived in-process
        // (the node's "miner" wallet is a signing-only wallet with no
        // keypool — it can't hand out receive addresses). Typed, not pasted:
        // cross-process pasteboard consent prompts proved flaky.
        let destination = try Self.fixtureAddress(0xC3)
        let app = launchApp()
        XCTAssertTrue(poll(timeout: 120, "persisted funded balance") {
            self.balanceText(app) != "0 sats" && self.balanceText(app) != ""
        })

        app.navigationTab("Send").tap()
        XCTAssertFalse(app.buttons["reviewButton"].isEnabled)
        XCTAssertFalse(app.textFields["feeOverrideField"].exists)
        XCTAssertFalse(app.staticTexts["Network floor"].exists)
        app.typeInto("destinationField", destination)
        app.typeInto("amountField", "100000")
        app.buttons["reviewButton"].tap()
        let sendButton = app.buttons["sendButton"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 30), "review did not replace the form")
        XCTAssertTrue(sendButton.isHittable, "sending should not require scrolling past the form")
        XCTAssertEqual(app.staticTexts["reviewDestination"].label, destination, "show the full address")
        XCTAssertFalse(app.textFields["amountField"].exists)

        // Editing preserves the fields and withdraws authorization. Only a
        // fresh review of the changed amount can expose Send again.
        app.buttons["editPaymentButton"].tap()
        XCTAssertEqual(app.textFields["destinationField"].value as? String, destination)
        XCTAssertEqual(app.textFields["amountField"].value as? String, "100000")
        XCTAssertFalse(sendButton.exists)
        app.typeInto("amountField", String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "1000000")
        app.buttons["reviewButton"].tap()
        XCTAssertTrue(sendButton.waitForExistence(timeout: 30))
        XCTAssertTrue(sendButton.isHittable)
        let amount = try XCTUnwrap(app.staticTexts["reviewAmount"].value as? String)
        let fee = try XCTUnwrap(app.staticTexts["reviewFee"].value as? String)
        let total = try XCTUnwrap(app.staticTexts["reviewTotal"].value as? String)
        XCTAssertEqual(Int64(amount.filter(\.isNumber)), 1_000_000)
        XCTAssertEqual(Int64(total.filter(\.isNumber)), 1_000_000 + (try XCTUnwrap(Int64(fee.filter(\.isNumber)))))
        XCTAssertFalse(app.staticTexts["Inputs"].exists)

        // A custom fee from Advanced mode must not silently survive in a
        // beginner payment after its controls have been hidden.
        app.buttons["editPaymentButton"].tap()
        app.navigationTab("Settings").tap()
        let advancedToggle = app.switches["advancedModeToggle"]
        XCTAssertTrue(scrollUntilExists(app, advancedToggle))
        app.flipSwitch(advancedToggle)
        app.navigationTab("Send").tap()
        app.typeInto("feeOverrideField", "99")
        // Keyboard dismissal animates independently of app idleness. Await
        // the resulting state, including when iPad supplies a Return key.
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "Return or Done must dismiss the fee keypad")
        // Exercise the app's accessory separately from the system Return key.
        app.textFields["feeOverrideField"].tap()
        let feeDone = app.buttons["sendKeyboardDone"]
        XCTAssertTrue(feeDone.waitForExistence(timeout: 5))
        XCTAssertTrue(feeDone.isHittable)
        feeDone.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "The fee keypad's Done button must end editing")
        app.navigationTab("Settings").tap()
        XCTAssertTrue(scrollUntilExists(app, advancedToggle, up: true))
        app.flipSwitch(advancedToggle)
        app.navigationTab("Send").tap()
        XCTAssertFalse(app.textFields["feeOverrideField"].exists)
        Screenshots.capture(app, "05-send-form", testCase: self)
        app.buttons["reviewButton"].tap()
        XCTAssertTrue(sendButton.waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["reviewFee"].value as? String, fee)
        XCTAssertEqual(app.staticTexts["reviewTotal"].value as? String, total)
        Screenshots.capture(app, "06-send-review", testCase: self)

        let mempoolBefore = Set(try BitcoinCLI.mempoolTxids())
        let broadcastStart = Date()
        app.buttons["sendButton"].tap()
        XCTAssertTrue(poll(timeout: 60, "broadcast status") {
            app.staticTexts["broadcastPending"].exists || app.staticTexts["broadcastConfirmed"].exists
        })
        Timings.record("send", step: "form→broadcast", from: broadcastStart)
        XCTAssertFalse(sendButton.exists, "a sent payment must not offer Send again")
        XCTAssertFalse(app.textFields["destinationField"].exists)
        XCTAssertFalse(app.buttons["copyRawTransactionButton"].exists)
        Screenshots.capture(app, "07-send-broadcast", testCase: self)
        // Recovery diagnostics remain reachable without crowding the status.
        let details = app.buttons["transactionDetailsButton"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()
        XCTAssertTrue(scrollUntilExists(app, app.buttons["copyRawTransactionButton"], maxSwipes: 2))
        app.navigationBars["Transaction details"].buttons["Payment"].tap()

        // Wait until the node actually has the tx (inv → getdata relay takes
        // a moment after the UI reports the broadcast), THEN mine.
        let relayStart = Date()
        poll(timeout: 60, interval: 1, "tx relayed into the node's mempool") {
            ((try? Set(BitcoinCLI.mempoolTxids()).isSubset(of: mempoolBefore)) ?? true) == false
        }
        Timings.record("send", step: "broadcast→echo/relay", from: relayStart)
        let payout = try AddressDecoder.scriptPubKey(for: Self.fixtureAddress(0xD4), network: .signet)
        let confirmStart = Date()
        try await SignetMiner.mineOntoTip(payingTo: payout)

        // The same status screen changes to confirmed after the wallet syncs.
        poll(timeout: 240, interval: 2, "send confirmation") {
            app.navigationTab("Wallet").tap()
            self.nudgeSync(app)
            app.navigationTab("Send").tap()
            return self.scrollUntilExists(app, app.staticTexts["broadcastConfirmed"], maxSwipes: 3)
        }
        Timings.record("send", step: "mine→confirmed", from: confirmStart)
        Screenshots.capture(app, "08-send-confirmed", testCase: self)
        app.buttons["newPaymentButton"].tap()
        XCTAssertTrue(app.textFields["destinationField"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["reviewButton"].isEnabled)
        XCTAssertFalse(sendButton.exists)

        app.navigationTab("Wallet").tap()
        self.nudgeSync(app)
        XCTAssertTrue(app.staticTexts["Sent"].waitForExistence(timeout: 60),
                      "no sent entry in history")
        Screenshots.capture(app, "09-home-after-send", testCase: self)
    }

    // MARK: - 08 Export bundle (Settings -> Backup, #18)

    /// Save a backup, open the share sheet, then explicitly include the key.
    /// Inspect the real staged files and their deletion after dismissal.
    func test08ExportBundle() throws {
        let app = launchApp()
        app.navigationTab("Settings").tap()
        let exportButton = app.buttons["exportBundleButton"]
        XCTAssertTrue(scrollUntilExists(app, exportButton), "no export button in Settings")
        exportButton.tap()

        // Watch-only is the default: no toggle flip, straight to export.
        let confirm = app.buttons["exportConfirmButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "no export confirm button")
        let toggle = app.switches["exportIncludeMnemonicToggle"]
        XCTAssertEqual(toggle.value as? String, "0", "seed export must not be the default")
        confirm.tap()
        let shareLink = app.buttons["exportShareLink"]
        let watchOnly = try stagedExport(in: app, expectingNote: "Recovery words are not included. Keep them separately.",
                                         "no staged share link after export")
        XCTAssertNil(watchOnly.bundle.mnemonic)
        XCTAssertNotNil(watchOnly.bundle.descriptor)
        XCTAssertFalse(watchOnly.bundle.utxos.isEmpty, "backup lost the funded wallet")
        XCTAssertFalse(watchOnly.bundle.transactions.isEmpty, "backup lost the payment history")
        Screenshots.capture(app, "16-export-watch-only", testCase: self)

        // The share link stages a real file and opens the system share sheet.
        shareLink.tap()
        let sheetTitle = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "winnow-signet-")).firstMatch
        let shareSheet = poll(timeout: 20, interval: 1, "share sheet") {
            app.otherElements["ActivityListView"].exists || sheetTitle.exists
        }
        XCTAssertTrue(shareSheet, "share sheet did not appear")
        Screenshots.capture(app, "17-export-share-sheet", testCase: self)
        let closeShare = app.buttons["Close"].firstMatch
        if UIDevice.current.userInterfaceIdiom == .pad {
            // ShareLink presents a popover on iPad. A tap on its backdrop
            // dismisses only that popover; the backup form remains open.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).tap()
        } else if closeShare.waitForExistence(timeout: 5), closeShare.isHittable {
            closeShare.tap()
        } else {
            // Fallback: drag the iPhone sheet down to dismiss.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                .press(forDuration: 0.05, thenDragTo:
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        XCTAssertTrue(poll(timeout: 10, interval: 0.5, "share sheet dismissed") {
            !app.otherElements["ActivityListView"].exists && !sheetTitle.exists
        }, "share UI still covers the backup form")

        // Including the key replaces the staged file only after confirmation.
        XCTAssertTrue(scrollUntilExists(app, toggle, up: true), "no seed toggle")
        app.flipSwitch(toggle)
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "toggle did not reset the export")
        confirm.tap()
        let alert = app.alerts["Include the recovery phrase?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no seed confirm alert")
        Screenshots.capture(app, "18-export-seed-confirm", testCase: self)
        alert.buttons["Export with phrase"].tap()
        let withKey = try stagedExport(in: app, expectingNote: "Includes your recovery words. Keep this file private.",
                                       "no share link after seed export")
        XCTAssertEqual(withKey.bundle.mnemonic, Self.mnemonic)
        XCTAssertEqual(withKey.bundle.utxos, watchOnly.bundle.utxos)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", Self.mnemonic)).firstMatch.exists,
                       "backup screen exposed the recovery words")
        Screenshots.capture(app, "19-export-with-phrase", testCase: self)

        backgroundAndReturn(app)
        // Await an actual background transition before checking the sensitive
        // export. A Home/activate pair can leave an iPad scene foregrounded.
        XCTAssertTrue(poll(timeout: 15, interval: 1, "staged seed export cleared on backgrounding") {
            !shareLink.exists
        }, "staged seed export survived backgrounding")
        XCTAssertFalse(shareLink.exists,
                       "staged seed export survived backgrounding")
        XCTAssertNotEqual(watchOnly.path, withKey.path)
        for path in [watchOnly.path, withKey.path] {
            let exists = try HostProcess.run("/bin/test", ["-e", path])
            XCTAssertNotEqual(exists.status, 0, "backup file survived replacement or dismissal")
        }
        XCTAssertTrue(scrollUntilExists(app, exportButton, up: true),
                      "seed export sheet did not dismiss to Settings")
    }

    // MARK: - 11 Beginner shell (mine-free)

    /// The wallet shows three tabs, one line of sync status, and a Settings
    /// screen without the expert rows; the Advanced switch brings them back
    /// and takes them away again without deleting anything.
    func test11BeginnerShellHidesAdvancedControls() throws {
        let app = launchApp()

        for title in ["Wallet", "Send", "Settings"] {
            XCTAssertTrue(app.navigationTab(title).exists, "missing beginner tab: \(title)")
        }
        XCTAssertFalse(app.navigationTab("People").exists)
        XCTAssertTrue(app.buttons["walletSharedSavingsButton"].exists)
        XCTAssertFalse(app.buttons["walletExtraDeviceButton"].exists)
        app.buttons["walletSharedSavingsButton"].tap()
        XCTAssertTrue(app.buttons["addSavingsCoOwnerButton"].waitForExistence(timeout: 20))
        app.buttons["addSavingsCoOwnerButton"].tap()
        XCTAssertTrue(app.textFields["personNameField"].waitForExistence(timeout: 20))
        app.navigationBars["Add co-owner"].buttons["Cancel"].tap()
        app.navigationBars["New shared savings"].buttons["Cancel"].tap()
        // The one-liner is a ProgressView, a Label or a Text depending on the
        // phase, so match the identifier across every element type.
        let syncSummary = app.descendants(matching: .any).matching(identifier: "syncSummaryText").firstMatch
        XCTAssertTrue(syncSummary.waitForExistence(timeout: 10) || app.buttons["retryPeersButton"].exists,
                      "no one-line sync status")
        XCTAssertTrue(scrollUntilExists(app, app.buttons["syncNowButton"]))

        app.navigationTab("Send").tap()
        XCTAssertTrue(app.textFields["amountField"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["feeOverrideField"].exists)
        app.navigationTab("Settings").tap()
        let toggle = app.switches["advancedModeToggle"]
        XCTAssertTrue(scrollUntilExists(app, toggle), "no Advanced mode switch")
        XCTAssertTrue(app.buttons["exportBundleButton"].exists)
        Screenshots.capture(app, "23-settings-beginner", testCase: self)

        XCTAssertTrue(scrollUntilExists(app, toggle, up: true))
        app.flipSwitch(toggle)
        app.navigationTab("Send").tap()
        XCTAssertTrue(scrollUntilExists(app, app.textFields["feeOverrideField"]), "Advanced mode did not reveal fee controls")
        app.navigationTab("Wallet").tap()
        XCTAssertTrue(scrollUntilExists(app, app.buttons["walletExtraDeviceButton"], up: true))
        XCTAssertTrue(scrollUntilExists(app, app.buttons["newVaultButton"]), "Advanced mode did not reveal the Vaults section")
        app.navigationTab("Settings").tap()
        XCTAssertTrue(scrollUntilExists(app, toggle, up: true))
        app.flipSwitch(toggle)
        app.navigationTab("Send").tap()
        XCTAssertTrue(app.textFields["amountField"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["feeOverrideField"].exists)
    }

    func test14IncomingPaymentBeforeConfirmation() async throws {
        // The bank pays: a payer wallet of its own would need a hundred
        // blocks before its first coinbase could be spent.
        let payer = Self.bankWallet
        let payout = try AddressDecoder.scriptPubKey(for: Self.fixtureAddress(0xD4), network: .signet)

        let app = launchApp()
        app.buttons["receiveButton"].tap()
        if app.buttons["skipReceiveAddressLabelButton"].waitForExistence(timeout: 5) {
            app.buttons["skipReceiveAddressLabelButton"].tap()
        }
        let field = app.staticTexts["receiveAddress"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        let address = try XCTUnwrap(field.value as? String)
        let txid = try BitcoinCLI.sendToAddress(
            wallet: payer, address: address, sats: 50_000, feeRate: 2)
        let pending = app.staticTexts["unconfirmedPayment"]
        XCTAssertTrue(pending.waitForExistence(timeout: 120),
                      "Receive did not show the peer-relayed payment before confirmation")
        XCTAssertEqual(pending.label.filter(\.isNumber), "50000")
        Screenshots.capture(app, "33-receive-unconfirmed", testCase: self)

        try await SignetMiner.mineOntoTip(payingTo: payout)
        app.buttons["Done"].tap()
        XCTAssertTrue(poll(timeout: 180, interval: 2, "receipt confirmed in the app") {
            self.nudgeSync(app)
            return app.staticTexts["transactionConfirmation-\(txid)"].exists
        })
        app.buttons["receiveButton"].tap()
        if app.buttons["skipReceiveAddressLabelButton"].waitForExistence(timeout: 5) {
            app.buttons["skipReceiveAddressLabelButton"].tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        XCTAssertFalse(pending.exists, "confirmed payment still shown as unconfirmed")
        app.buttons["Done"].tap()
    }
}

/// Story B — Paying people: a wallet restored from a backup, saved recipients, fee replacement, senders and the explorer.
@MainActor
final class StoryPayingPeople: WinnowAppJourney {
    /// The story's wallet is the one test06 restores from a backup.
    override class var runName: String { "import" }

    /// The bank pays the fixed-entropy wallet's first address, so test06
    /// has a funded UTXO to claim and the wallet it restores has money.
    override class func prepare(_ journey: WinnowAppJourney) async throws {
        try await ensureBank()
        let address = try walletReceiveAddress(index: 0)
        let coin = try await fundFromBank(address, sats: 5_000_000)
        saveFunding(FundingInfo(txid: coin.txid, vout: coin.vout, amount: coin.amount,
                                scriptPubKey: try AddressDecoder.scriptPubKey(for: address, network: .signet).hex,
                                height: Int(coin.height), index: 0))
    }

    // MARK: - 06 Import

    func test06ImportBundleVerification() async throws {
        guard let funding = Self.loadFunding() else {
            XCTFail("no funding info — the story's preparation did not pay the wallet")
            return
        }
        // Minimal bundle: the fixed mnemonic plus the bank's payment as the
        // claimed UTXO/history, as of its block. Verification scans forward
        // from there; the report shows the claimed UTXO still unspent, and
        // whatever the chain holds past it.
        let bundle: [String: Any] = [
            "version": 1,
            "network": "signet",
            "mnemonic": Self.mnemonic,
            "lastKnownHeight": funding.height,
            "utxos": [[
                "txid": funding.txid, "vout": funding.vout, "amount": funding.amount,
                "scriptPubKey": funding.scriptPubKey, "chain": 0,
                "index": funding.index, "height": funding.height,
            ]],
            "transactions": [[
                "txid": funding.txid, "height": funding.height,
                "received": funding.amount, "spent": 0,
            ]],
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: bundle), as: UTF8.self)

        // The app puts the bundle on its own pasteboard at boot.
        let app = launchApp(run: "import", reset: true, clipboard: json, expectOnboarding: true)
        app.buttons["importWalletButton"].tap()
        XCTAssertTrue(app.buttons["importPasteButton"].waitForExistence(timeout: 20))
        app.buttons["importPasteButton"].tap()
        // The system may still ask for paste consent — allow it, retry.
        let allowPaste = app.buttons["Allow Paste"]
        let pasted = poll(timeout: 15, interval: 1, "bundle pasted") {
            if allowPaste.exists { allowPaste.tap() }
            if ((app.textViews["importJSONEditor"].value as? String) ?? "").contains("lastKnownHeight") {
                return true
            }
            if app.buttons["importPasteButton"].exists { app.buttons["importPasteButton"].tap() }
            return false
        }
        if !pasted {
            // Fallback: type the JSON into the editor (autocorrect disabled).
            app.typeInto("importJSONEditor", json)
        }

        // Imported JSON may contain the seed. Leaving the active scene must
        // erase it before the app can be foregrounded again.
        backgroundAndReturn(app)
        XCTAssertTrue(app.buttons["importPasteButton"].waitForExistence(timeout: 20),
                      "import sheet did not return after activation")
        XCTAssertFalse(((app.textViews["importJSONEditor"].value as? String) ?? "")
            .contains("lastKnownHeight"), "seed-bearing import JSON survived backgrounding")
        app.buttons["importPasteButton"].tap()
        _ = poll(timeout: 15, interval: 1, "bundle re-pasted after lifecycle clearing") {
            if allowPaste.exists { allowPaste.tap() }
            return ((app.textViews["importJSONEditor"].value as? String) ?? "")
                .contains("lastKnownHeight")
        }
        let verifyStart = Date()
        app.buttons["importVerifyButton"].tap()
        let reportVisible = poll(timeout: 300, interval: 3, "verification report") {
            app.staticTexts["Verification report"].exists
        }
        if reportVisible {
            Timings.record("import", step: "verify", from: verifyStart)
        }
        if !reportVisible {
            Screenshots.capture(app, "debug-06-import", testCase: self)
            let texts = app.staticTexts.allElementsBoundByIndex.map(\.label)
            print("E2E debug import staticTexts: \(texts)")
        }
        XCTAssertTrue(reportVisible, "no verification report")
        XCTAssertFalse(app.textViews["importJSONEditor"].exists, "completed import left an empty editor")
        Screenshots.capture(app, "14-import-report", testCase: self)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["importContinueButton"]),
                      "no Continue button after report")
        app.buttons["importContinueButton"].tap()
        XCTAssertTrue(app.staticTexts["balanceText"].waitForExistence(timeout: 60),
                      "wallet home did not appear after import")
    }

    // MARK: - 10 Save a recipient from a payment, then pay a fresh card address

    func test10SaveRecipientFromPayment() async throws {
        let address = try Self.fixtureAddress(0xE1)
        var app = launchApp()
        app.navigationTab("Send").tap()
        app.typeInto("destinationField", address)
        app.typeInto("amountField", "20000")
        app.buttons["reviewButton"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.buttons["sendButton"]))
        let before = Set(try BitcoinCLI.mempoolTxids())
        app.buttons["sendButton"].tap()
        XCTAssertTrue(poll(timeout: 60, interval: 1, "payment reaches Core") {
            ((try? Set(BitcoinCLI.mempoolTxids()).subtracting(before).isEmpty) ?? true) == false
        })
        let txid = try XCTUnwrap(Set(try BitcoinCLI.mempoolTxids()).subtracting(before).first)
        let payout = try AddressDecoder.scriptPubKey(for: Self.fixtureAddress(0xD4), network: .signet)
        try await SignetMiner.mineOntoTip(payingTo: payout)
        app.navigationTab("Wallet").tap()
        openPayment(txid, in: app)
        let save = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'savePaymentRecipient-'" )).firstMatch
        XCTAssertTrue(scrollUntilExists(app, save), "the outgoing address has no save action")
        save.tap()
        app.typeInto("personNameField", "Coffee")
        savePerson(in: app)
        XCTAssertTrue(app.buttons["Rename recipient"].waitForExistence(timeout: 20))
        save.tap()
        app.typeInto("personNameField", String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "Cafe")
        savePerson(in: app)
        XCTAssertTrue(app.staticTexts["Cafe"].waitForExistence(timeout: 20))

        // The name belongs to the address and survives reopening the wallet.
        app.terminate()
        app = launchApp()
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["Sent to Cafe"]), "the payment lost its name after restart")
        openPayment(txid, in: app)
        XCTAssertTrue(poll(timeout: 10, interval: 0.2, "payment details fully on screen") {
            save.exists && save.isHittable && save.frame.maxX <= app.frame.maxX
        })
        Screenshots.capture(app, "24-saved-recipient", testCase: self)
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'removePaymentRecipient-'" )).firstMatch
        XCTAssertTrue(scrollUntilExists(app, remove))
        remove.tap()
        XCTAssertTrue(app.buttons["Save recipient"].waitForExistence(timeout: 20))
        app.navigationTab("Send").tap()
        app.buttons["savedRecipientsButton"].tap()
        XCTAssertTrue(app.buttons["addRecipientButton"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["chooseRecipient-Cafe"].exists)
        app.buttons["Done"].tap()
        app.navigationTab("Wallet").tap()
        XCTAssertTrue(app.staticTexts["Sent to Cafe"].exists, "removing a shortcut erased the old label")
        save.tap()
        savePerson(in: app)
        XCTAssertTrue(app.buttons["Rename recipient"].waitForExistence(timeout: 20))
        app.navigationTab("Send").tap()
        app.buttons["savedRecipientsButton"].tap()
        XCTAssertTrue(app.buttons["chooseRecipient-Cafe"].waitForExistence(timeout: 20))
        app.buttons["chooseRecipient-Cafe"].tap()
        app.typeInto("amountField", "1000")
        app.buttons["reviewButton"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["reviewRecipient"]))
        XCTAssertEqual(app.staticTexts["reviewDestination"].label, address)
        XCTAssertTrue(scrollUntilExists(app, app.descendants(matching: .any)["addressReuseWarning"]),
                      "a saved fixed address must explain reuse")

        // A card uses a fresh address for each committed payment.
        let aliceKey = try Self.fixtureCosigner(0xA1)
        let card = try PersonCard(network: .signet, name: "Alice", payTo: "tr(\(aliceKey))",
                                  signerKey: aliceKey).serialized()
        app.terminate()
        app = launchApp(clipboard: card)
        app.navigationTab("Send").tap()
        app.buttons["savedRecipientsButton"].tap()
        addPastedRecipient("Alice", in: app)
        app.buttons["chooseRecipient-Alice"].tap()
        app.typeInto("amountField", "20000")
        app.buttons["reviewButton"].tap()
        let recipient = app.staticTexts["reviewRecipient"]
        XCTAssertTrue(scrollUntilExists(app, recipient))
        let destination = app.staticTexts["reviewDestination"]
        let firstAddress = destination.label
        XCTAssertEqual(firstAddress, try Self.fixtureReceiveAddress(0xA1, index: 0))
        XCTAssertFalse(app.staticTexts["addressReuseWarning"].exists)
        Screenshots.capture(app, "25-pay-person-review", testCase: self)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["sendButton"]))
        let beforeAlice = Set(try BitcoinCLI.mempoolTxids())
        app.buttons["sendButton"].tap()
        XCTAssertTrue(poll(timeout: 60, interval: 1, "payment to Alice reaches Core") {
            ((try? Set(BitcoinCLI.mempoolTxids()).subtracting(beforeAlice).isEmpty) ?? true) == false
        })
        try await SignetMiner.mineOntoTip(payingTo: payout)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["newPaymentButton"]))
        app.buttons["newPaymentButton"].tap()
        app.buttons["savedRecipientsButton"].tap()
        app.buttons["chooseRecipient-Alice"].tap()
        app.typeInto("amountField", "1000")
        app.buttons["reviewButton"].tap()
        XCTAssertTrue(scrollUntilExists(app, recipient))
        XCTAssertEqual(destination.label, try Self.fixtureReceiveAddress(0xA1, index: 1))
    }

    func test15ReviewAndReplacePendingPayment() async throws {
        var app = launchApp(advanced: true)
        app.navigationTab("Send").tap()
        app.typeInto("amountField", "20000")
        app.typeInto("destinationField", try Self.fixtureAddress(0xD5))
        XCTAssertTrue(scrollUntilExists(app, app.buttons["reviewButton"]))
        app.buttons["reviewButton"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.buttons["sendButton"], maxSwipes: 5))
        let before = Set(try BitcoinCLI.mempoolTxids())
        // Cut only the disposable node's P2P connections; RPC stays available
        // to prove the payment has not reached it and to restore service.
        _ = try BitcoinCLI.run(["setnetworkactive", "false"])
        defer { _ = try? BitcoinCLI.run(["setnetworkactive", "true"]) }
        app.buttons["sendButton"].tap()
        XCTAssertTrue(app.staticTexts["broadcastPending"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["sendButton"].exists, "a saved payment must not offer Send again")
        app.buttons["transactionDetailsButton"].tap()
        let identifier = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9a-f]{64}")).firstMatch
        XCTAssertTrue(identifier.waitForExistence(timeout: 10))
        let original = identifier.label
        XCTAssertEqual(try BitcoinCLI.mempoolTxids().sorted(), before.sorted(), "the offline node received a payment")

        app.terminate()
        app = launchApp(advanced: true)
        openPayment(original, in: app)
        XCTAssertTrue(app.staticTexts["awaiting confirmation"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["transactionConfirmation-\(original)"].exists)
        Screenshots.capture(app, "39-payment-after-disconnect", testCase: self)
        _ = try BitcoinCLI.run(["setnetworkactive", "true"])
        XCTAssertTrue(poll(timeout: 180, interval: 1, "saved payment resumes relay after reopening") {
            (try? Set(BitcoinCLI.mempoolTxids()).subtracting(before)) == [original]
        })
        // The original payment survived the interruption. Its existing fee
        // replacement journey continues from the same history entry.
        app.navigationBars.buttons["Winnow"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "historyPayment-\(original)").count, 1)
        openPayment(original, in: app)
        let bump = app.buttons["bumpFeeButton"].firstMatch
        XCTAssertTrue(scrollUntilExists(app, bump, maxSwipes: 8))
        bump.tap()
        let rate = app.textFields["bumpFeeRateField"]
        XCTAssertTrue(rate.waitForExistence(timeout: 30))
        XCTAssertTrue(poll(timeout: 30, interval: 0.2, "suggested replacement fee loaded") {
            Double((rate.value as? String) ?? "") != nil
        })
        app.buttons["reviewFeeBumpButton"].tap()
        let confirm = app.buttons["confirmFeeBumpButton"]
        XCTAssertTrue(scrollUntilExists(app, confirm, maxSwipes: 5))
        Screenshots.capture(app, "34-fee-replacement-review", testCase: self)
        confirm.tap()
        XCTAssertTrue(app.buttons["copyReplacementTransactionIDButton"].waitForExistence(timeout: 60))
        XCTAssertTrue(poll(timeout: 60, interval: 1, "replacement in Core mempool") {
            guard let current = try? Set(BitcoinCLI.mempoolTxids()) else { return false }
            return !current.contains(original) && !current.subtracting(before).isEmpty
        })
        let replacement = try XCTUnwrap(Set(try BitcoinCLI.mempoolTxids()).subtracting(before).first)
        XCTAssertNotEqual(original, replacement)
        app.buttons["Done"].tap()
        let replaced = app.staticTexts["transactionReplaced-\(original)"]
        XCTAssertTrue(scrollUntilExists(app, replaced, maxSwipes: 5),
                      "the original payment was not marked replaced in history")
        XCTAssertTrue(replaced.label.contains(String(replacement.prefix(8))))
        app.navigationBars.buttons["Winnow"].tap()
        let payout = try AddressDecoder.scriptPubKey(for: Self.fixtureAddress(0xD4), network: .signet)
        try await SignetMiner.mineOntoTip(payingTo: payout)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["syncNowButton"], maxSwipes: 5, up: true))
        XCTAssertTrue(poll(timeout: 180, interval: 2, "replacement confirmed in the app") {
            self.nudgeSync(app)
            return app.staticTexts["transactionConfirmation-\(replacement)"].exists
        })
    }

    /// The node pays the app from a P2WPKH UTXO: the input's witness reveals
    /// the funding address, the app offers it — with its warning — while the
    /// sender is saved as a person, and "Send to" pays that address back.
    func test17SaveSenderFromReceivedPayment() async throws {
        // The bank pays from a P2WPKH output of its own, so the input's
        // witness names the funding address the sender sheet can offer.
        let utxo = try await ensureSegwitUtxo(wallet: Self.bankWallet)
        var app = launchApp()

        app.buttons["receiveButton"].tap()
        if app.buttons["skipReceiveAddressLabelButton"].waitForExistence(timeout: 5) {
            app.buttons["skipReceiveAddressLabelButton"].tap()
        }
        let receiveField = app.staticTexts["receiveAddress"]
        XCTAssertTrue(receiveField.waitForExistence(timeout: 30))
        let address = try XCTUnwrap(receiveField.value as? String)
        app.buttons["Done"].tap()

        let txid = try payFromNode(wallet: Self.bankWallet, input: (utxo.txid, utxo.vout),
                                   to: address, sats: 300_000)
        poll(timeout: 30, interval: 1, "payment in the node's mempool") {
            (try? BitcoinCLI.mempoolTxids().contains(txid)) == true
        }
        let payout = try AddressDecoder.scriptPubKey(for: Self.fixtureAddress(0xD6), network: .signet)
        try await SignetMiner.mineOntoTip(payingTo: payout)
        XCTAssertTrue(poll(timeout: 300, interval: 2, "received payment in history") {
            self.nudgeSync(app)
            return app.buttons["historyPayment-\(txid)"].exists
        })

        openPayment(txid, in: app)
        app.buttons["saveSenderButton"].tap()
        XCTAssertTrue(app.textFields["personNameField"].waitForExistence(timeout: 20))
        // Even a sole candidate requires an explicit choice. First save only a label.
        XCTAssertNotEqual(app.textFields["personPasteField"].value as? String, utxo.address)
        app.typeInto("personNameField", "Node")
        Screenshots.capture(app, "44-name-only-label", testCase: self)
        savePerson(in: app)
        XCTAssertTrue(app.staticTexts["senderName"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["senderName"].label, "Node")
        app.navigationBars.buttons["Winnow"].tap()
        XCTAssertTrue(app.staticTexts["Received from Node"].waitForExistence(timeout: 20),
                      "history did not label the sender")

        // The label survives reopening the wallet.
        app.terminate()
        app = launchApp()
        XCTAssertTrue(app.staticTexts["Received from Node"].waitForExistence(timeout: 60))

        // Pay the sender back from the payment screen.
        openPayment(txid, in: app)
        XCTAssertFalse(app.buttons["sendToSenderButton"].exists)
        app.buttons["attachSenderDestinationButton"].tap()
        let candidate = app.buttons["senderCandidate-0"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 20))
        XCTAssertNotEqual(app.textFields["personPasteField"].value as? String, utxo.address)
        candidate.tap()
        XCTAssertEqual(app.textFields["personPasteField"].value as? String, utxo.address)
        XCTAssertTrue(app.staticTexts["senderCandidateWarning"].exists)
        Screenshots.capture(app, "40-save-sender", testCase: self)
        savePerson(in: app)
        XCTAssertTrue(app.buttons["sendToSenderButton"].waitForExistence(timeout: 20))
        app.buttons["sendToSenderButton"].tap()
        XCTAssertTrue(app.navigationTab("Send").isSelected)
        app.typeInto("amountField", "1000")
        app.buttons["reviewButton"].tap()
        XCTAssertTrue(app.staticTexts["reviewRecipient"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["reviewDestination"].label, utxo.address)
        XCTAssertTrue(scrollUntilExists(app, app.descendants(matching: .any)["addressReuseWarning"]),
                      "paying a fixed funding address must warn about reuse")
        Screenshots.capture(app, "41-send-to-person", testCase: self)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["sendButton"]))
        let mempoolBefore = Set(try BitcoinCLI.mempoolTxids())
        app.buttons["sendButton"].tap()
        XCTAssertTrue(poll(timeout: 60, "broadcast status") {
            app.staticTexts["broadcastPending"].exists || app.staticTexts["broadcastConfirmed"].exists
        })
        poll(timeout: 60, interval: 1, "repayment relayed into the node's mempool") {
            ((try? Set(BitcoinCLI.mempoolTxids()).isSubset(of: mempoolBefore)) ?? true) == false
        }
        try await SignetMiner.mineOntoTip(payingTo: payout)
        poll(timeout: 240, interval: 2, "repayment confirmation") {
            app.navigationTab("Wallet").tap()
            self.nudgeSync(app)
            app.navigationTab("Send").tap()
            return self.scrollUntilExists(app, app.staticTexts["broadcastConfirmed"], maxSwipes: 3)
        }
    }

    /// A taproot-input payment shows no local funding address, so the sender
    /// sheet asks the configured explorer — after its warning — and attaches
    /// the single answer it gets back.
    func test18InferSenderWithExplorer() async throws {
        let trUtxo = try await ensureTaprootUtxo(wallet: Self.bankWallet)
        let stub = StubExplorer()
        defer { stub.stop() }

        // Advanced, because the explorer picker is an expert row; the
        // sender flow itself is not gated.
        let app = launchApp(advanced: true)

        app.buttons["receiveButton"].tap()
        if app.buttons["skipReceiveAddressLabelButton"].waitForExistence(timeout: 5) {
            app.buttons["skipReceiveAddressLabelButton"].tap()
        }
        let receiveField = app.staticTexts["receiveAddress"]
        XCTAssertTrue(receiveField.waitForExistence(timeout: 30))
        let address = try XCTUnwrap(receiveField.value as? String)
        app.buttons["Done"].tap()

        let txid = try payFromNode(wallet: Self.bankWallet, input: (trUtxo.txid, trUtxo.vout),
                                   to: address, sats: 90_000)
        try stub.serve(txid: txid, addresses: [trUtxo.address])
        poll(timeout: 30, interval: 1, "payment in the node's mempool") {
            (try? BitcoinCLI.mempoolTxids().contains(txid)) == true
        }
        let payout = try AddressDecoder.scriptPubKey(for: Self.fixtureAddress(0xD6), network: .signet)
        try await SignetMiner.mineOntoTip(payingTo: payout)
        XCTAssertTrue(poll(timeout: 300, interval: 2, "received payment in history") {
            self.nudgeSync(app)
            return app.buttons["historyPayment-\(txid)"].exists
        })

        // Point the app at the loopback explorer.
        app.navigationTab("Settings").tap()
        let picker = app.buttons["explorerProviderPicker"]
        XCTAssertTrue(scrollUntilExists(app, picker))
        picker.tap()
        XCTAssertTrue(app.buttons["Custom"].waitForExistence(timeout: 10))
        app.buttons["Custom"].tap()
        XCTAssertTrue(app.textFields["esploraURLField"].waitForExistence(timeout: 10))
        app.typeInto("esploraURLField", stub.baseURL)

        app.navigationTab("Wallet").tap()
        openPayment(txid, in: app)
        app.buttons["saveSenderButton"].tap()
        XCTAssertTrue(app.textFields["personNameField"].waitForExistence(timeout: 20))
        // Taproot key-path: nothing to attach locally — the explorer is asked.
        // (An empty field reports its placeholder, never the address.)
        XCTAssertNotEqual(app.textFields["personPasteField"].value as? String, trUtxo.address)
        XCTAssertEqual(stub.requestCount, 0, "No explorer request before consent")
        let infer = app.buttons["inferSenderButton"]
        XCTAssertTrue(scrollUntilExists(app, infer), "no infer button for an opaque payment")
        infer.tap()
        let confirm = app.buttons["confirmInferSenderButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no infer warning")
        XCTAssertEqual(stub.requestCount, 0, "Opening the consent dialog cannot send a request")
        Screenshots.capture(app, "45-explorer-consent", testCase: self)
        confirm.tap()
        let inferred = app.buttons["inferredSender-\(trUtxo.address)"]
        XCTAssertTrue(inferred.waitForExistence(timeout: 60), "stub explorer answer did not arrive (\(stub.requestCount) request(s) reached the stub)")
        XCTAssertEqual(stub.requestCount, 1)
        // The sole returned address is still unselected until tapped.
        XCTAssertNotEqual(app.textFields["personPasteField"].value as? String, trUtxo.address)
        inferred.tap()
        XCTAssertEqual(app.textFields["personPasteField"].value as? String, trUtxo.address)
        app.typeInto("personNameField", "Miner")
        Screenshots.capture(app, "43-infer-sender", testCase: self)
        savePerson(in: app)
        XCTAssertTrue(app.staticTexts["senderName"].waitForExistence(timeout: 20))
        app.navigationBars.buttons["Winnow"].tap()
        XCTAssertTrue(app.staticTexts["Received from Miner"].waitForExistence(timeout: 20))
    }
}

/// Story C — Shared savings: a vault, an approval, savings with co-owners, a group cosigner.
@MainActor
final class StorySharedSavings: WinnowAppJourney {
    override class func prepare(_ journey: WinnowAppJourney) async throws {
        try await createFundedWallet(journey)
    }

    func test04VaultCreate() throws {
        // The raw vault tools live in Wallet,
        // in Advanced mode; beginners see the same records as shared savings.
        let app = launchApp(advanced: true)
        app.navigationTab("Wallet").tap()
        let createStart = Date()
        let newVault = app.buttons["newVaultButton"]
        XCTAssertTrue(scrollUntilExists(app, newVault), "no Vaults section in Advanced mode")
        newVault.tap()

        app.typeInto("vaultNameField", "E2E Vault")
        // Default policy: 2-of-n script path; three cosigners → 2-of-3.
        app.buttons["addDeviceKeyButton"].tap()
        for byte: UInt8 in [0xA1, 0xB2] {
            app.typeInto("cosignerField", try Self.fixtureCosigner(byte))
            app.buttons["addPastedKeyButton"].tap()
        }
        let threshold = app.steppers["vaultThresholdStepper"]
        XCTAssertTrue(scrollUntilExists(app, threshold, up: true))
        threshold.buttons["vaultThresholdStepper-Decrement"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.buttons["buildDescriptorButton"]))
        app.buttons["buildDescriptorButton"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["vaultSingleKeyRule"]))
        XCTAssertEqual(app.staticTexts["vaultSingleKeyRule"].label, "One signing key can spend these funds.")
        XCTAssertTrue(scrollUntilExists(app, threshold, up: true))
        threshold.buttons["vaultThresholdStepper-Increment"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.buttons["buildDescriptorButton"]))
        app.buttons["buildDescriptorButton"].tap()
        // The descriptor preview is a CopyableTextBlock whose Text starts
        // with "tr(" — below the fold, and SwiftUI Forms materialize rows
        // lazily, so scroll it into existence.
        let descriptor = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'tr('")).firstMatch
        XCTAssertTrue(scrollUntilExists(app, descriptor), "descriptor preview did not appear")
        app.dismissKeyboard()
        XCTAssertTrue(scrollUntilExists(app, app.textFields["vaultNameField"], up: true, fullyVisible: true),
                      "account name and signing threshold are off-screen")
        Screenshots.capture(app, "10-vault-create", testCase: self)

        XCTAssertTrue(scrollUntilExists(app, app.buttons["saveVaultButton"]),
                      "save button did not appear")
        app.buttons["saveVaultButton"].tap()
        XCTAssertTrue(app.staticTexts["E2E Vault"].firstMatch.waitForExistence(timeout: 30),
                      "vault was not saved")
        Timings.record("vault", step: "create", from: createStart)
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 of 3 keys required'")).firstMatch),
                      "the Vaults section does not describe the policy")
        Screenshots.capture(app, "11-vault-list", testCase: self)
    }

    // MARK: - 07 Approve a request (mines)

    /// The beginner's side of a shared-savings spend, on the "E2E Vault"
    /// from test04 (this device + fixture co-owners 0xA1/0xB2, 2 of 3):
    /// fund it from the wallet, let "Alice" (0xA1, in-process) propose and
    /// approve a spend, approve it here in plain words, and Finish. Real
    /// coins, so the finish broadcasts and a block settles it.
    func test07ApproveRequest() async throws {
        let descriptor = try Vault.multiADescriptor(
            threshold: 2,
            cosigners: try [Self.deviceKeyExpression(), Self.fixtureCosigner(0xA1),
                            Self.fixtureCosigner(0xB2)])
        let vault = try Vault(descriptor: descriptor, network: .signet)
        let recordID = String(descriptor.serialized().split(separator: "#").last!)
        let savingsAddress = try vault.address(index: 0)
        let savingsScript = try vault.scriptPubKey(index: 0)

        // 1. Fund the savings from the wallet. Coins an earlier suite run
        // left at this script (same entropy, same fixture keys) are invisible
        // to the app, which scans forward from the vault's creation in
        // test04, so only a coin mined from here on counts.
        let startHeight = UInt32(try BitcoinCLI.blockCount())
        func freshCoins() throws -> [(txid: String, vout: UInt32, amount: Int64, height: UInt32)] {
            try BitcoinCLI.unspents(scriptHex: savingsScript.hex).filter { $0.height >= startHeight }
        }
        var app = launchApp()
        app.navigationTab("Wallet").tap()
        let savingsRow = app.staticTexts["E2E Vault"].firstMatch
        XCTAssertTrue(savingsRow.waitForExistence(timeout: 30),
                      "savings from test04 missing — run the full suite")
        // The balance the app shows before funding: it may already hold
        // coins from earlier attempts, so "non-zero" would not prove the
        // app has scanned the coin this request is about to spend.
        savingsRow.tap()
        let balance = app.staticTexts["accountBalance"]
        func shownBalance() -> Int64 {
            guard balance.exists else { return -1 }
            let text = balance.label.isEmpty ? ((balance.value as? String) ?? "") : balance.label
            return Int64(text.filter(\.isNumber)) ?? -1
        }
        _ = balance.waitForExistence(timeout: 20)
        let balanceBefore = max(shownBalance(), 0)
        var fundedNow: Int64 = 0
        if try freshCoins().isEmpty {
            fundedNow = 200_000
            let mempoolBefore = Set(try BitcoinCLI.mempoolTxids())
            app.navigationTab("Send").tap()
            app.typeInto("destinationField", savingsAddress)
            app.typeInto("amountField", "200000")
            app.dismissKeyboard()
            app.buttons["reviewButton"].tap()
            XCTAssertTrue(scrollUntilExists(app, app.buttons["sendButton"], maxSwipes: 5), "no send review")
            app.buttons["sendButton"].tap()
            XCTAssertTrue(poll(timeout: 60, "broadcast into the savings") {
                app.staticTexts["broadcastPending"].exists || app.staticTexts["broadcastConfirmed"].exists
            })
            // The UI reports the broadcast before the node has the bytes
            // (inv → getdata); mining first would leave the tx behind.
            XCTAssertTrue(poll(timeout: 60, interval: 1, "funding relayed into the node's mempool") {
                ((try? Set(BitcoinCLI.mempoolTxids()).isSubset(of: mempoolBefore)) ?? true) == false
            })
            let payout = try AddressDecoder.scriptPubKey(for: Self.fixtureAddress(0xD4), network: .signet)
            try await SignetMiner.mineOntoTip(payingTo: payout)
        }
        XCTAssertTrue(poll(timeout: 30, interval: 2, "the node sees the funding coin") {
            (try? freshCoins().isEmpty) == false
        })
        guard let coin = try freshCoins().max(by: { $0.height < $1.height }) else {
            return XCTFail("the savings were not funded")
        }
        app.navigationTab("Wallet").tap()
        if !balance.exists { savingsRow.tap() }
        let target = max(balanceBefore + fundedNow, 1)
        XCTAssertTrue(poll(timeout: 240, interval: 2, "the savings see their coin") {
            if shownBalance() >= target { return true }
            app.navigationTab("Wallet").tap()
            if app.navigationBars.buttons["Winnow"].exists { app.navigationBars.buttons["Winnow"].tap() }
            self.nudgeSync(app)
            if savingsRow.exists { savingsRow.tap() }
            return false
        })

        // 2. Alice proposes 100,000 sats to Carol (0xE5) and approves first.
        let utxo = WalletUTXO(txid: Data(Data(hex: coin.txid)!.reversed()), vout: coin.vout,
                              amount: coin.amount, scriptPubKey: savingsScript,
                              chain: .receive, index: 0, height: coin.height)
        var psbt = try vault.createSpend(
            utxos: [utxo],
            payments: [Payment(amount: 100_000, address: Self.fixtureAddress(0xE5), network: .signet)],
            changeIndex: 0, feeRateSatPerVByte: 2, chainTip: UInt32(try BitcoinCLI.blockCount()),
            randomness: { 0.5 })
        let alice = try HDKey(seed: Data(repeating: 0xA1, count: 64))
        try vault.partialSign(&psbt, master: alice, knownUTXOs: [utxo],
                              ownedOutputCoordinates: [.init(choice: 1, index: 0)],
                              chainTip: UInt32(try BitcoinCLI.blockCount()))
        let request = try ApprovalRequest(network: .signet, vault: recordID, name: "E2E Vault",
                                          psbt: psbt).serialized()

        // 3. This phone reads it, approves, and finishes.
        app.terminate()
        app = launchApp(clipboard: request)
        app.navigationTab("Wallet").tap()
        XCTAssertTrue(savingsRow.waitForExistence(timeout: 30))
        savingsRow.tap()
        let approve = app.buttons["approveRequestButton"]
        XCTAssertTrue(scrollUntilExists(app, approve), "savings detail did not load")
        approve.tap()
        XCTAssertTrue(app.buttons["approvalPasteButton"].waitForExistence(timeout: 20),
                      "approval sheet did not appear")
        let reviewStart = Date()
        app.buttons["approvalPasteButton"].tap()
        // The pasted envelope grows the field by several lines and pushes
        // Review below the fold.
        let review = app.buttons["reviewApprovalButton"]
        XCTAssertTrue(scrollUntilExists(app, review, maxSwipes: 4), "no Review request button")
        XCTAssertTrue(poll(timeout: 10, interval: 1, "Review request enabled") { review.isEnabled })
        review.tap()
        let progress = app.staticTexts["approvalProgress"]
        XCTAssertTrue(scrollUntilExists(app, progress), "the request was not reviewed")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Pays'")).firstMatch.exists,
                      "review lists no payment")
        XCTAssertTrue(app.staticTexts["Back into E2E Vault"].exists, "review lists no output back into the savings")
        XCTAssertTrue(progress.label.contains("1 of 2"), progress.label)
        XCTAssertTrue(progress.label.contains("unnamed co-owner"), "an unknown co-owner should be named as such: \(progress.label)")
        Timings.record("vault", step: "cosign-review", from: reviewStart)
        Screenshots.capture(app, "15-approve-request", testCase: self)

        let approveNow = app.buttons["approveButton"]
        XCTAssertTrue(scrollUntilExists(app, approveNow), "no Approve button")
        approveNow.tap()
        XCTAssertTrue(poll(timeout: 60, "this phone's approval") {
            _ = self.scrollUntilExists(app, progress, maxSwipes: 2, up: true)
            return progress.exists && progress.label.contains("2 of 2")
        })
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["Share your approval"]), "no approval to share back")
        let finish = app.buttons["finishApprovalButton"]
        XCTAssertTrue(scrollUntilExists(app, finish, up: true) && finish.isEnabled, "Finish is not offered at threshold")
        finish.tap()
        XCTAssertTrue(poll(timeout: 60, "the finish broadcasts") {
            self.scrollUntilExists(app, app.staticTexts["approvalBroadcast"], maxSwipes: 2)
        }, "the finish did not broadcast")
        XCTAssertTrue(poll(timeout: 60, interval: 1, "spend in the node's mempool") {
            (try? BitcoinCLI.mempoolTxids().isEmpty == false) ?? false
        })
        let payout = try AddressDecoder.scriptPubKey(for: Self.fixtureAddress(0xD4), network: .signet)
        try await SignetMiner.mineOntoTip(payingTo: payout)
        XCTAssertTrue(poll(timeout: 120, interval: 2, "the spend leaves the savings' UTXO set") {
            (try? freshCoins().isEmpty) ?? false
        })

        // Sensitive state is dropped on a background transition.
        backgroundAndReturn(app)
        XCTAssertFalse(progress.waitForExistence(timeout: 3), "approval review survived backgrounding")
    }

    // MARK: - 12 Shared savings from Wallet (mines)

    /// Create "Savings with Alice, Bob" from Wallet (2 of 3 with
    /// this phone), share the card, fund it from the wallet, and ask Alice
    /// for approval of a payment to her. The approve-and-finish half is
    /// test07; this is the creation half a beginner does.
    func test12SharedSavingsCreateAndAsk() async throws {
        let aliceKey = try Self.fixtureCosigner(0xA1)
        // 0xC3, not 0xB2: with the device key and Alice that would be the
        // very descriptor test04 saved as "E2E Vault", and a vault is
        // identified by its descriptor.
        let bobKey = try Self.fixtureCosigner(0xC3)
        let bobCard = try PersonCard(network: .signet, name: "Bob", payTo: "tr(\(bobKey))",
                                     signerKey: bobKey).serialized()
        var app = launchApp(clipboard: bobCard)
        app.navigationTab("Send").tap()
        app.buttons["savedRecipientsButton"].tap()
        addPastedRecipient("Bob", in: app)
        if !app.buttons["chooseRecipient-Alice"].exists {
            let aliceCard = try PersonCard(network: .signet, name: "Alice", payTo: "tr(\(aliceKey))",
                                           signerKey: aliceKey).serialized()
            app.terminate()
            app = launchApp(clipboard: aliceCard)
            app.navigationTab("Send").tap()
            app.buttons["savedRecipientsButton"].tap()
            addPastedRecipient("Alice", in: app)
        }
        app.buttons["Done"].tap()
        app.navigationTab("Wallet").tap()

        let savingsName = "Savings with Alice, Bob"
        let creationHeight = UInt32(try BitcoinCLI.blockCount())
        if !app.staticTexts[savingsName].exists {
            let createStart = Date()
            app.navigationTab("Wallet").tap()
            XCTAssertTrue(scrollUntilExists(app, app.buttons["walletSharedSavingsButton"], up: true))
            app.buttons["walletSharedSavingsButton"].tap()
            XCTAssertTrue(app.buttons["coOwnerToggle-Alice"].waitForExistence(timeout: 20), "no co-owner picker")
            app.buttons["coOwnerToggle-Alice"].tap()
            app.buttons["coOwnerToggle-Bob"].tap()
            // The count lives in the Stepper's label, not in a Text of its own.
            let threshold = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS '2 of 3' OR value CONTAINS '2 of 3'")).firstMatch
            XCTAssertTrue(threshold.waitForExistence(timeout: 5), "the threshold did not settle at 2 of 3")
            app.typeInto("savingsNameField", savingsName)
            XCTAssertTrue(scrollUntilExists(app, app.buttons["createSharedSavingsButton"]))
            app.buttons["createSharedSavingsButton"].tap()
            XCTAssertTrue(app.staticTexts["savingsShareNotice"].waitForExistence(timeout: 60),
                          "creating did not lead to the share step")
            Timings.record("vault", step: "shared-savings-create", from: createStart)
            Screenshots.capture(app, "26-savings-share", testCase: self)
            app.buttons["savingsShareDoneButton"].tap()
        }

        // Fund it from the wallet, then ask Alice for approval of 20,000 to her.
        app.navigationTab("Wallet").tap()
        let savingsRow = app.buttons["walletSavings-\(savingsName)"]
        XCTAssertTrue(scrollUntilExists(app, savingsRow, up: true), "the savings were not listed")
        savingsRow.tap()
        let addressBlock = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'tb1p'")).firstMatch
        XCTAssertTrue(addressBlock.waitForExistence(timeout: 20), "no receive address on the savings")
        let savingsAddress = addressBlock.label
        let savingsScript = try AddressDecoder.scriptPubKey(for: savingsAddress, network: .signet)
        // Only a coin mined since the savings were created is one the app
        // can see; an earlier run's coin at this script does not count.
        if try BitcoinCLI.unspents(scriptHex: savingsScript.hex).filter({ $0.height >= creationHeight }).isEmpty {
            let mempoolBefore = Set(try BitcoinCLI.mempoolTxids())
            app.navigationTab("Send").tap()
            app.typeInto("destinationField", savingsAddress)
            app.typeInto("amountField", "50000")
            app.dismissKeyboard()
            app.buttons["reviewButton"].tap()
            XCTAssertTrue(scrollUntilExists(app, app.buttons["sendButton"], maxSwipes: 5), "no send review")
            app.buttons["sendButton"].tap()
            XCTAssertTrue(poll(timeout: 60, "broadcast into the savings") {
                app.staticTexts["broadcastPending"].exists || app.staticTexts["broadcastConfirmed"].exists
            })
            XCTAssertTrue(poll(timeout: 60, interval: 1, "funding relayed into the node's mempool") {
                ((try? Set(BitcoinCLI.mempoolTxids()).isSubset(of: mempoolBefore)) ?? true) == false
            })
            let payout = try AddressDecoder.scriptPubKey(for: Self.fixtureAddress(0xD4), network: .signet)
            try await SignetMiner.mineOntoTip(payingTo: payout)
            app.navigationTab("Wallet").tap()
        }
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["vaultRequiredKeys"]))
        XCTAssertEqual(app.staticTexts["vaultRequiredKeys"].label, "2 of 3 signing keys required")
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["vaultSingleKeyRule"]))
        XCTAssertEqual(app.staticTexts["vaultSingleKeyRule"].label, "One signing key cannot spend these funds.")
        let ask = app.buttons["sendFromAccountButton"]
        XCTAssertTrue(poll(timeout: 240, interval: 2, "the savings see their coin") {
            if self.scrollUntilExists(app, ask, maxSwipes: 2), ask.isEnabled { return true }
            app.navigationBars.buttons["Winnow"].tap()
            XCTAssertTrue(self.scrollUntilExists(app, app.buttons["syncNowButton"]))
            self.nudgeSync(app)
            XCTAssertTrue(self.scrollUntilExists(app, savingsRow, up: true))
            savingsRow.tap()
            return false
        })
        let backup = try accountBackup(in: app)
        let savedAccount = try XCTUnwrap(backup.vaults?.first { $0.name == savingsName })
        XCTAssertFalse(savedAccount.utxos.isEmpty, "the shared-account backup lost its funded outputs")
        XCTAssertTrue(scrollUntilExists(app, ask, up: true))
        ask.tap()
        XCTAssertTrue(app.navigationTab("Send").isSelected)
        app.buttons["savedRecipientsButton"].tap()
        let aliceItem = app.buttons["chooseRecipient-Alice"]
        XCTAssertTrue(aliceItem.waitForExistence(timeout: 20))
        aliceItem.tap()
        app.typeInto("amountField", "20000")
        app.buttons["reviewButton"].tap()
        XCTAssertTrue(app.staticTexts["reviewAccount"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["reviewAccount"].label, savingsName)
        XCTAssertEqual(app.staticTexts["reviewRecipient"].label, "Alice")
        Screenshots.capture(app, "27-shared-payment-review", testCase: self)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["sendButton"]))
        XCTAssertEqual(app.buttons["sendButton"].label, "Continue to approvals")
        app.buttons["sendButton"].tap()
        XCTAssertTrue(app.staticTexts["approvalProgress"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["approvalProgress"].label.contains("No approvals yet"))
        XCTAssertTrue(scrollUntilExists(app, app.buttons["finishApprovalButton"]))
        XCTAssertFalse(app.buttons["finishApprovalButton"].isEnabled)
        let request = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '\"winnow\":\"approval\"'")).firstMatch
        XCTAssertTrue(scrollUntilExists(app, request), "reviewed payment was not handed to approvals")

    }

    // MARK: - 13 Group cosigner (Advanced mode, mines)

    /// Two-level custody through the app, in the Advanced-mode vault tools
    /// that live inside Wallet: a MuSig2 2-of-2 *group* — entered
    /// as its BIP328 synthetic xpub, like any pasted cosigner — is one
    /// signer of a 2-of-3, and the app carries the whole ceremony: create
    /// the vault, create the spend, accept the group's signature from the
    /// clipboard, sign the device leg, finalize, broadcast. The test plays
    /// the group (both member secrets in-process, the same simulation the
    /// CLI's musig-sign-psbt performs); the node judges the result — the
    /// funding outpoint must actually be spent on chain.
    func test13GroupCosignerVault() async throws {
        // A fresh group each run: the vault's identity is its descriptor's
        // checksum, so a repeated group would collide with a previous run's
        // vault in the persistent simulator state and the save would be
        // (rightly) refused as a duplicate.
        let salt = UInt8.random(in: 1 ... 250)
        let memberSecrets = [Data([0x74, salt] + Data(repeating: 0x33, count: 30)),
                             Data([0x75, salt] + Data(repeating: 0x44, count: 30))]
        let memberKeys = try memberSecrets.map {
            try P256K.Signing.PrivateKey(dataRepresentation: $0).publicKey.dataRepresentation
        }
        let aggregate = try MuSig.aggregate(memberKeys)
        let synthetic = try MuSig.syntheticExtendedKey(aggregatePublicKey: aggregate)
        let groupExpression = "[\(String(format: "%08x", synthetic.fingerprint))]"
            + "\(synthetic.serialized(network: .testnet))/<0;1>/*"

        // 1. Create the vault through the UI: device key + the group + a
        //    silent third.
        let vaultName = "Group Vault \(UInt16.random(in: 100 ..< 999))"
        var app = launchApp(advanced: true)
        app.navigationTab("Wallet").tap()
        let newVault = app.buttons["newVaultButton"]
        XCTAssertTrue(scrollUntilExists(app, newVault), "no Vaults section in Advanced mode")
        newVault.tap()
        app.typeInto("vaultNameField", vaultName)
        app.buttons["addDeviceKeyButton"].tap()
        for expression in [groupExpression, try Self.fixtureCosigner(0xB2)] {
            app.typeInto("cosignerField", expression)
            app.buttons["addPastedKeyButton"].tap()
        }
        XCTAssertTrue(scrollUntilExists(app, app.buttons["buildDescriptorButton"]))
        app.buttons["buildDescriptorButton"].tap()
        let descriptorPreview = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'tr('")).firstMatch
        XCTAssertTrue(scrollUntilExists(app, descriptorPreview), "descriptor preview missing")
        app.dismissKeyboard()
        XCTAssertTrue(scrollUntilExists(app, app.buttons["saveVaultButton"]))
        app.buttons["saveVaultButton"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts[vaultName].firstMatch),
                      "group vault was not saved")
        Screenshots.capture(app, "30-group-vault", testCase: self)

        // 2. Fund it from the bank — same derivation the app made.
        let descriptor = try Vault.multiADescriptor(
            threshold: 2,
            cosigners: [try Self.deviceKeyExpression(), groupExpression,
                        try Self.fixtureCosigner(0xB2)])
        let vault = try Vault(descriptor: descriptor, network: .signet)
        let funding = try await Self.fundFromBank(try vault.address(index: 0), sats: 2_000_000)
        let fundingTxid = funding.txid
        let fundingVout = String(funding.vout)

        // 3. Relaunch so the scan credits the coin, then create the spend in
        //    the UI and read the PSBT off the screen.
        app = launchApp(advanced: true)
        app.navigationTab("Wallet").tap()
        let vaultRow = app.staticTexts[vaultName].firstMatch
        XCTAssertTrue(scrollUntilExists(app, vaultRow), "group vault row not reachable")
        vaultRow.tap()
        // Read the account's confirmed balance before spending.
        let fundedBalance = app.staticTexts["accountBalance"]
        XCTAssertTrue(scrollUntilExists(app, fundedBalance), "no shared-savings balance")
        poll(timeout: 300, interval: 2, "group vault funding scanned in") {
            if fundedBalance.exists, !fundedBalance.label.isEmpty, fundedBalance.label != "0 sats" {
                return true
            }
            app.navigationTab("Wallet").tap()
            if app.navigationBars.buttons["Winnow"].exists { app.navigationBars.buttons["Winnow"].tap() }
            self.nudgeSync(app)
            if vaultRow.exists { vaultRow.tap() }
            return false
        }
        reviewFromAccount(app, name: vaultName, address: try Self.fixtureAddress(0xE5), amount: "1000000", chooseInSend: true)
        Screenshots.capture(app, "31-group-spend-created", testCase: self)
        app.buttons["sendButton"].tap()
        let progress = app.staticTexts["approvalProgress"]
        XCTAssertTrue(scrollUntilExists(app, progress))
        XCTAssertTrue(progress.label.contains("No approvals yet"))
        XCTAssertTrue(scrollUntilExists(app, app.buttons["approveButton"]))
        app.buttons["approveButton"].tap()
        XCTAssertTrue(poll(timeout: 60, "phone approves before the group") {
            self.scrollUntilExists(app, progress, up: true) && progress.label.contains("1 of 2")
        })
        XCTAssertTrue(scrollUntilExists(app, app.buttons["finishApprovalButton"]))
        XCTAssertFalse(app.buttons["finishApprovalButton"].isEnabled, "phone approval alone enabled sending")
        let rawDisclosure = app.buttons["approvalRawPSBTDisclosure"]
        XCTAssertTrue(scrollUntilExists(app, rawDisclosure))
        rawDisclosure.tap()
        let rawRequest = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'cHNidP'")).firstMatch
        XCTAssertTrue(scrollUntilExists(app, rawRequest))
        let phoneSigned = rawRequest.label
        XCTAssertEqual(try PSBT(base64: phoneSigned).inputs.first?.tapScriptSignatures.count, 1)

        // 4. The group signs the raw request exported by the phone.
        let signed = try Self.groupSign(base64: phoneSigned, memberSecrets: memberSecrets,
                                        synthetic: synthetic)

        // 5. Relaunch with the group's PSBT on the clipboard; the app pastes,
        //    reviews both approvals, finalizes, and broadcasts.
        app = launchApp(clipboard: signed, advanced: true)
        app.navigationTab("Wallet").tap()
        let signingVaultRow = app.staticTexts[vaultName].firstMatch
        XCTAssertTrue(scrollUntilExists(app, signingVaultRow), "group vault row not reachable")
        signingVaultRow.tap()
        XCTAssertFalse(app.buttons["Continue signing"].exists, "shared accounts still have a second signing entry")
        let approveRequest = app.buttons["approveRequestButton"]
        XCTAssertTrue(scrollUntilExists(app, approveRequest))
        approveRequest.tap()
        XCTAssertTrue(app.buttons["approvalPasteButton"].waitForExistence(timeout: 20))
        app.buttons["approvalPasteButton"].tap()
        let resumedProgress = app.staticTexts["approvalProgress"]
        XCTAssertTrue(poll(timeout: 240, interval: 2, "group approval reviewed once the tip caught up") {
            let review = app.buttons["reviewApprovalButton"]
            guard self.scrollUntilExists(app, review) else { return false }
            review.tap()
            return self.scrollUntilExists(app, resumedProgress)
        })
        XCTAssertTrue(resumedProgress.label.contains("2 of 2"), "both approvals were not retained")
        XCTAssertTrue(scrollUntilExists(app, app.buttons["approveButton"]))
        XCTAssertFalse(app.buttons["approveButton"].isEnabled, "the phone can approve a second time")
        let finish = app.buttons["finishApprovalButton"]
        XCTAssertTrue(scrollUntilExists(app, finish) && finish.isEnabled)
        finish.tap()
        XCTAssertTrue(poll(timeout: 60, "shared approval flow sends the group payment") {
            self.scrollUntilExists(app, app.staticTexts["approvalBroadcast"])
        })
        XCTAssertFalse(app.staticTexts["Winnow cannot safely review this request"].exists,
                       "a successful payment is still showing a stale-coin warning")
        XCTAssertTrue(app.navigationBars["Payment"].exists)
        Screenshots.capture(app, "32-group-broadcast", testCase: self)

        // 6. The node is the judge — patiently: the app broadcasts over P2P
        //    (inv → getdata → tx), so the mempool arrival is asynchronous.
        //    Wait for it, then mine until the funding outpoint is gone.
        let burnMaster = try HDKey(seed: BIP39.seed(mnemonic: Self.mnemonic))
        let burn = try BIP86.scriptPubKey(
            internalKey: BIP86.xonlyPublicKey(of: burnMaster.derived(path: "m/86'/1'/9'/0/9")))
        poll(timeout: 120, interval: 3, "spend reached the node's mempool") {
            let mempool = (try? BitcoinCLI.runJSON(["getrawmempool"])) as? [Any]
            return (mempool?.isEmpty == false)
                || (try? BitcoinCLI.runObject(["gettxout", fundingTxid, fundingVout])) == nil
        }
        for _ in 0 ..< 3 where (try? BitcoinCLI.runObject(["gettxout", fundingTxid, fundingVout])) != nil {
            _ = try await SignetMiner.mineOntoTip(payingTo: burn)
        }
        let spent = try? BitcoinCLI.runObject(["gettxout", fundingTxid, fundingVout])
        XCTAssertNil(spent, "the vault coin was not spent on chain")
    }
}

/// Story D — A second device and the network: settings, backup resume, MuSig2 with Core, peers, the census, Tor.
@MainActor
final class StoryDevicesAndNetwork: WinnowAppJourney {
    override class func prepare(_ journey: WinnowAppJourney) async throws {
        try await createFundedWallet(journey)
    }

    // MARK: - 05 Settings

    func test05SettingsPeersAndExplorerWarning() throws {
        // Connected peers and the explorer setting are Advanced-mode rows.
        let app = launchApp(advanced: true)
        app.navigationTab("Settings").tap()

        // SwiftUI Forms materialize rows lazily: scroll the Connected peers
        // section into existence first.
        let refresh = app.buttons["refreshPeersButton"]
        if !scrollUntilExists(app, refresh) {
            Screenshots.capture(app, "debug-05-settings", testCase: self)
            print(app.debugDescription)
            XCTFail("settings form did not load")
            return
        }
        refresh.tap()
        let localPeer = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(BitcoinCLI.nodeHost):\(BitcoinCLI.p2pPort)")).firstMatch
        poll(timeout: 60, interval: 3, "connected local peer in settings") {
            if localPeer.exists { return true }
            if refresh.exists, refresh.isHittable { refresh.tap() }
            return localPeer.exists
        }
        // Bring the Connected peers section into view for the screenshot.
        if !localPeer.isHittable { app.collectionViews.firstMatch.swipeUp() }
        Screenshots.capture(app, "12-settings-peers", testCase: self)

        // Esplora is a selectable external link only, never a wallet backend.
        // Presets show the provider picker; a URL field exists only for Custom.
        let explorerPicker = app.buttons["explorerProviderPicker"]
        XCTAssertTrue(scrollUntilExists(app, explorerPicker, up: true), "no explorer provider picker")

        // Opening a transaction is the privacy boundary: capture the warning
        // and cancel before iOS contacts the selected endpoint.
        app.navigationTab("Wallet").tap()
        let payment = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'historyPayment-'" )).firstMatch
        XCTAssertTrue(scrollUntilExists(app, payment))
        payment.tap()
        let explorerLink = app.buttons["explorerTransactionButton"].firstMatch
        XCTAssertTrue(scrollUntilExists(app, explorerLink), "no transaction explorer link")
        explorerLink.tap()
        let alert = app.alerts["Open external block explorer?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "explorer warning did not appear")
        Screenshots.capture(app, "13-esplora-warning", testCase: self)
        alert.buttons["Cancel"].tap()
    }

    // MARK: - 09 Backup resume + recovery-phrase reveal (#5)

    /// Mine-free. Kills the app on the mnemonic backup sheet and asserts the
    /// relaunch resumes it (the backup-pending flag survives restarts), then
    /// completes the backup, proves a further relaunch stays on home, and
    /// reveals the phrase from Settings -> Backup (device auth is bypassed in
    /// E2E mode; simulators have no passcode). Numbered after PR #22's
    /// test08.
    func test09BackupResumeAndReveal() throws {
        let backupEnvironment: [String: String] = [
            "WINNOW_E2E": "1",
            "WINNOW_E2E_RUN": "backup",
            "WINNOW_E2E_ENTROPY": Self.entropyHex,
        ]
        let app = launchApp(run: "backup", reset: true, expectOnboarding: true,
                            configureLocalNode: false)
        app.buttons["createWalletButton"].tap()
        XCTAssertTrue(backupConfirmationIsReachable(app),
                      "backup sheet did not appear after create")
        Screenshots.capture(app, "20-backup-sheet", testCase: self)

        // Kill mid-backup, before Done.
        app.terminate()
        let resumed = XCUIApplication()
        resumed.launchEnvironment = backupEnvironment // same run, NO reset
        resumed.launch()
        XCTAssertTrue(backupConfirmationIsReachable(resumed),
                      "relaunch did not resume the backup sheet — backup skipped (#5)")
        Screenshots.capture(resumed, "21-backup-resumed", testCase: self)

        // A background transition erases the phrase and dismisses its sheet;
        // resuming requires another explicit action (and production auth).
        backgroundAndReturn(resumed)
        XCTAssertFalse(resumed.switches["writtenDownToggle"].waitForExistence(timeout: 3),
                       "onboarding recovery phrase survived backgrounding")
        let resumeBackup = resumed.buttons["resumeBackupButton"]
        XCTAssertTrue(resumeBackup.waitForExistence(timeout: 20),
                      "pending backup has no explicit resume action")
        resumeBackup.tap()
        XCTAssertTrue(backupConfirmationIsReachable(resumed),
                      "explicit backup resume did not restore the authenticated flow")

        // Complete the backup: toggle + Done -> wallet home.
        XCTAssertTrue(confirmBackupAndContinue(resumed),
                      "backup confirmation was not completed after explicit resume")
        XCTAssertTrue(resumed.staticTexts["balanceText"].waitForExistence(timeout: 60),
                      "home did not appear after backup Done")

        // A confirmed backup must not re-prompt on the next launch.
        resumed.terminate()
        let settled = XCUIApplication()
        settled.launchEnvironment = backupEnvironment
        settled.launch()
        XCTAssertTrue(settled.staticTexts["balanceText"].waitForExistence(timeout: 60),
                      "confirmed backup re-prompted on relaunch")

        // Reveal from Settings -> Backup: the fixed entropy's numbered first
        // word renders in the grid.
        settled.navigationTab("Settings").tap()
        let revealButton = settled.buttons["revealPhraseButton"]
        XCTAssertTrue(scrollUntilExists(settled, revealButton), "no reveal button in Backup")
        revealButton.tap()
        let firstWord = "1. " + (Self.mnemonic.split(separator: " ").first.map(String.init) ?? "")
        XCTAssertTrue(settled.staticTexts[firstWord].waitForExistence(timeout: 30),
                      "revealed phrase grid missing \(firstWord)")
        XCTAssertTrue(settled.buttons["settingsCopyPhraseButton"].exists,
                      "Settings recovery screen does not offer phrase copy")
        Screenshots.capture(settled, "22-phrase-revealed", testCase: self)
        backgroundAndReturn(settled)
        // Await the cleared state after the verified background transition.
        XCTAssertTrue(poll(timeout: 15, interval: 1, "recovery phrase cleared on backgrounding") {
            !settled.staticTexts[firstWord].exists
        }, "Settings recovery phrase survived backgrounding")
        XCTAssertTrue(scrollUntilExists(settled, revealButton, up: true),
                      "phrase sheet did not dismiss to Settings")

        // A seed-bearing export is staged only for the lifetime of its sheet.
        let exportButton = settled.buttons["exportBundleButton"]
        XCTAssertTrue(scrollUntilExists(settled, exportButton, up: true),
                      "no export button after phrase dismissal")
        exportButton.tap()
        let seedToggle = settled.switches["exportIncludeMnemonicToggle"]
        XCTAssertTrue(seedToggle.waitForExistence(timeout: 20), "no seed-export toggle")
        settled.flipSwitch(seedToggle)
        settled.buttons["exportConfirmButton"].tap()
        let seedAlert = settled.alerts["Include the recovery phrase?"]
        XCTAssertTrue(seedAlert.waitForExistence(timeout: 10), "no seed-export warning")
        seedAlert.buttons["Export with phrase"].tap()
        let shareLink = settled.buttons["exportShareLink"]
        XCTAssertTrue(shareLink.waitForExistence(timeout: 30), "seed export was not staged")
        backgroundAndReturn(settled)
        // `waitForExistence` answers at once for an element that is still
        // there, so give the scene-phase change time to land, as test08 does.
        XCTAssertTrue(poll(timeout: 15, interval: 1, "staged seed export cleared on backgrounding") {
            !shareLink.exists
        }, "seed-bearing staged export survived backgrounding")
        XCTAssertTrue(scrollUntilExists(settled, exportButton, up: true),
                      "seed export sheet did not dismiss to Settings")
        settled.terminate()

        // Imported JSON can carry the same seed. It is erased immediately on
        // background even before parsing or authentication begins.
        let importApp = launchApp(run: "import-lifecycle", reset: true,
                                  expectOnboarding: true, configureLocalNode: false)
        importApp.buttons["importWalletButton"].tap()
        let privateMarker = "seed-bearing-private-material"
        importApp.typeInto("importJSONEditor", privateMarker)
        XCTAssertTrue(((importApp.textViews["importJSONEditor"].value as? String) ?? "")
            .contains(privateMarker), "import test marker was not entered")
        backgroundAndReturn(importApp)
        XCTAssertTrue(importApp.buttons["importPasteButton"].waitForExistence(timeout: 20),
                      "empty import sheet did not remain available")
        XCTAssertFalse(((importApp.textViews["importJSONEditor"].value as? String) ?? "")
            .contains(privateMarker), "import text survived backgrounding")
        importApp.terminate()
    }

    // The phone and Bitcoin Core each hold one key and exchange ordinary
    // PSBT files. No test-side Winnow signer stands in for the second device.
    func test16MuSig2RequiresSecondDevice() async throws {
        let external = try CoreSigner(wallet: "ui-musig-\(UUID().uuidString)")
        let externalKey = external.publicExpression
        let ownKey = String(try Self.deviceKeyExpression().dropLast("/<0;1>/*".count))
        let vault = try Vault("tr(musig(\(ownKey),\(externalKey))/<0;1>/*)", network: .signet)
        try external.importVault(vault)
        let name = "Extra device \(UUID().uuidString.prefix(6))"
        var app = launchApp(advanced: true)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["walletExtraDeviceButton"]))
        app.buttons["walletExtraDeviceButton"].tap()
        XCTAssertTrue(app.staticTexts["vaultPurpose"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["vaultPurpose"].label.contains("Every key is needed"))
        app.typeInto("vaultNameField", name)
        app.buttons["addDeviceKeyButton"].tap()
        app.typeInto("cosignerField", externalKey)
        app.buttons["addPastedKeyButton"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.buttons["buildDescriptorButton"]))
        app.buttons["buildDescriptorButton"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["vaultRequiredKeys"]))
        XCTAssertEqual(app.staticTexts["vaultRequiredKeys"].label, "2 of 2 signing keys required")
        XCTAssertTrue(scrollUntilExists(app, app.buttons["saveVaultButton"]))
        app.buttons["saveVaultButton"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.buttons["walletSavings-\(name)"], up: true))

        let coin = try await Self.fundFromBank(try vault.address(index: 0), sats: 2_000_000)
        let fundingTxid = coin.txid
        app = launchApp(advanced: true)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["walletSavings-\(name)"]))
        app.buttons["walletSavings-\(name)"].tap()
        XCTAssertTrue(poll(timeout: 240, interval: 2, "extra-device balance scanned") {
            if self.scrollUntilExists(app, app.staticTexts["accountBalance"]),
               app.staticTexts["accountBalance"].label != "0 sats" { return true }
            app.navigationBars.buttons["Winnow"].tap()
            self.nudgeSync(app)
            _ = self.scrollUntilExists(app, app.buttons["walletSavings-\(name)"], up: true)
            app.buttons["walletSavings-\(name)"].tap()
            return false
        })
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["vaultSingleKeyRule"], fullyVisible: true))
        XCTAssertEqual(app.staticTexts["vaultSingleKeyRule"].label, "One signing key cannot spend these funds.")
        Screenshots.capture(app, "35-extra-device-policy", testCase: self)
        var backup = try accountBackup(in: app)
        let backedUpAccount = try XCTUnwrap(backup.vaults?.first { $0.name == name })
        XCTAssertEqual(backedUpAccount.descriptor, vault.descriptor.serialized())
        XCTAssertEqual(backedUpAccount.utxos.count, 1)

        reviewFromAccount(app, name: name, address: try Self.fixtureAddress(0xE5), amount: "1000000")
        app.buttons["sendButton"].tap()
        let psbtOutput = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'cHNidP'")).firstMatch
        XCTAssertTrue(scrollUntilExists(app, psbtOutput), "payment was not handed straight to the second-signer flow")
        let unsigned = psbtOutput.label

        func combine(_ text: String) {
            XCTAssertTrue(scrollUntilExists(app, app.textFields["psbtField"], up: true))
            app.typeInto("psbtField", text)
            app.buttons["addPSBTButton"].tap()
        }
        XCTAssertTrue(scrollUntilExists(app, app.buttons["musigSignButton"]))
        XCTAssertFalse(app.buttons["musigSignButton"].isEnabled, "round two needs both nonces")
        XCTAssertFalse(app.buttons["musigBroadcastButton"].isEnabled)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["musigNonceButton"], up: true))
        app.buttons["musigNonceButton"].tap()
        XCTAssertTrue(poll(timeout: 30, interval: 1, "first nonce session") {
            self.scrollUntilExists(app, psbtOutput)
                && (try? PSBT(base64: psbtOutput.label).inputs[0].musig2PubNonces.count) == 1
        })
        let abandoned = psbtOutput.label
        app.buttons["Done"].tap()
        app.navigationTab("Wallet").tap()
        XCTAssertTrue(scrollUntilExists(app, app.buttons["Continue signing"]))
        app.buttons["Continue signing"].tap()
        combine(abandoned)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["musigSignButton"]))
        XCTAssertFalse(app.buttons["musigSignButton"].isEnabled, "reopening must not restore secret nonces")
        XCTAssertTrue(scrollUntilExists(app, app.buttons["musigRestartButton"]))
        app.buttons["musigRestartButton"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.buttons["musigNonceButton"]))
        app.buttons["musigNonceButton"].tap()
        XCTAssertTrue(poll(timeout: 30, interval: 1, "fresh nonce after abandoning session") {
            self.scrollUntilExists(app, psbtOutput) && psbtOutput.label != abandoned
                && (try? PSBT(base64: psbtOutput.label).inputs[0].musig2PubNonces.count) == 1
        })

        // Core starts with the original proposal so it only contributes a
        // nonce. The phone must still review and approve before either side
        // can complete the payment.
        let coreNonce = try external.process(PSBT(base64: unsigned))
        XCTAssertEqual(coreNonce.inputs[0].musig2PubNonces.count, 1)
        XCTAssertTrue(coreNonce.inputs[0].musig2PartialSigs.isEmpty)
        let bothNonces = try PSBT(base64: psbtOutput.label).combined(with: [coreNonce])
        combine(try bothNonces.base64V0())
        XCTAssertTrue(scrollUntilExists(app, app.buttons["musigSignButton"]))
        XCTAssertTrue(app.buttons["musigSignButton"].isEnabled)
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["Check this payment"], up: true))
        Screenshots.capture(app, "36-extra-device-review", testCase: self)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["musigSignButton"]))
        app.buttons["musigSignButton"].tap()
        XCTAssertTrue(poll(timeout: 30, interval: 1, "phone partial signature") {
            self.scrollUntilExists(app, psbtOutput)
                && (try? PSBT(base64: psbtOutput.label).inputs[0].musig2PartialSigs.count) == 1
        })
        let phoneSigned = try PSBT(base64: psbtOutput.label)
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["musigNextStep"], up: true))
        Screenshots.capture(app, "37-extra-device-waiting", testCase: self)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["musigBroadcastButton"], up: true))
        XCTAssertFalse(app.buttons["musigBroadcastButton"].isEnabled, "phone alone must not spend")
        let signed = try external.process(phoneSigned)
        XCTAssertEqual(signed.inputs[0].musig2PartialSigs.count, 2)
        combine(try signed.base64V0())
        XCTAssertTrue(scrollUntilExists(app, app.buttons["musigBroadcastButton"]))
        XCTAssertTrue(app.buttons["musigBroadcastButton"].isEnabled)
        let before = Set(try BitcoinCLI.mempoolTxids())
        app.buttons["musigBroadcastButton"].tap()
        XCTAssertTrue(poll(timeout: 60, interval: 1, "MuSig2 spend accepted by Core") {
            ((try? Set(BitcoinCLI.mempoolTxids()).subtracting(before).isEmpty) ?? true) == false
        })
        XCTAssertTrue(app.staticTexts["vaultPaymentSent"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.staticTexts["Winnow cannot safely review this proposal"].exists)
        XCTAssertFalse(app.buttons["musigBroadcastButton"].exists)
        Screenshots.capture(app, "39-extra-device-sent", testCase: self)
        let txid = try XCTUnwrap(Set(BitcoinCLI.mempoolTxids()).subtracting(before).first)
        let tx = try BitcoinCLI.runObject(["getrawtransaction", txid, "true"])
        let inputs = try XCTUnwrap(tx["vin"] as? [[String: Any]])
        let witness = try XCTUnwrap(inputs.first?["txinwitness"] as? [String])
        XCTAssertEqual(witness.count, 1, "key-path spend exposed a script")
        XCTAssertEqual(witness.first?.count, 128, "expected one 64-byte signature")
        _ = try await SignetMiner.mineOntoTip(payingTo: AddressDecoder.scriptPubKey(
            for: Self.fixtureAddress(0xD4), network: .signet))
        let spent = try BitcoinCLI.runJSON(["gettxout", fundingTxid, String(coin.vout)])
        XCTAssertTrue(spent == nil || spent is NSNull, "the funded output was not spent")
        backup.mnemonic = Self.mnemonic // represents the separately saved words
        let expectedChange = try XCTUnwrap(signed.outputs.first { output in
            output.script == (try? vault.scriptPubKey(index: 0, choice: 1))
        }?.amount)
        app = launchApp(run: "musig-restore", reset: true,
                        clipboard: try backup.serialized(), expectOnboarding: true, advanced: true)
        app.buttons["importWalletButton"].tap()
        XCTAssertTrue(app.buttons["importPasteButton"].waitForExistence(timeout: 20))
        app.buttons["importPasteButton"].tap()
        XCTAssertTrue(poll(timeout: 15, interval: 1, "backup pasted for restore") {
            if app.buttons["Allow Paste"].exists { app.buttons["Allow Paste"].tap() }
            return ((app.textViews["importJSONEditor"].value as? String) ?? "").contains("lastKnownHeight")
        })
        app.buttons["importVerifyButton"].tap()
        XCTAssertTrue(app.staticTexts["Verification report"].waitForExistence(timeout: 180))
        XCTAssertTrue(scrollUntilExists(app, app.buttons["importContinueButton"]))
        app.buttons["importContinueButton"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.buttons["walletSavings-\(name)"]))
        app.buttons["walletSavings-\(name)"].tap()
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["accountBalance"]))
        let restoredBalance = app.staticTexts["accountBalance"].label.filter(\.isNumber)
        XCTAssertEqual(Int64(restoredBalance), expectedChange, "restoring replayed the old balance")
        Screenshots.capture(app, "38-extra-device-restored", testCase: self)

    }

    // MARK: - 19 Reset and shuffle peers

    /// Advanced mode's escape hatch for peers the user does not like: forget
    /// the remembered good peers and dial fresh ones. On the custom signet
    /// the manual peer is the only source, so the same peer must return —
    /// the shuffle itself is covered in PeerPoolTests.
    func test19ResetAndShufflePeers() throws {
        let app = launchApp(advanced: true)
        app.navigationTab("Settings").tap()

        let refresh = app.buttons["refreshPeersButton"]
        XCTAssertTrue(scrollUntilExists(app, refresh), "settings form did not load")
        refresh.tap()
        let localPeer = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(BitcoinCLI.nodeHost):\(BitcoinCLI.p2pPort)")).firstMatch
        poll(timeout: 60, interval: 3, "connected local peer in settings") {
            if localPeer.exists { return true }
            if refresh.exists, refresh.isHittable { refresh.tap() }
            return localPeer.exists
        }

        let reset = app.buttons["resetPeersButton"]
        XCTAssertTrue(scrollUntilExists(app, reset, up: true), "no peer reset button")
        reset.tap()
        let confirm = app.buttons["confirmResetPeersButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no reset confirmation")
        Screenshots.capture(app, "42-peer-reset", testCase: self)
        confirm.tap()

        // The stack rebuilds from nothing; the manual fixture peer dials back.
        poll(timeout: 120, interval: 3, "peer back after the reset") {
            if localPeer.exists { return true }
            if refresh.exists, refresh.isHittable { refresh.tap() }
            return localPeer.exists
        }
        XCTAssertFalse(app.buttons["confirmResetPeersButton"].exists)
    }

    func test20PeerCatalogRefreshAndFailureRecovery() throws {
        let stub = StubExplorer()
        defer { stub.stop() }
        let today = String(Date().ISO8601Format().prefix(10))
        let catalog = CensusCatalog(date: today, tip: 900_000, networks: [
            "clearnet": [.init(host: "8.8.8.8", port: 8333, userAgent: "/Fixture/", startHeight: 900_000)],
            "tor": [], "i2p": []
        ])
        try stub.catalog(JSONEncoder().encode(catalog))
        let app = launchApp(advanced: true, environment: ["WINNOW_E2E_CENSUS_URL": stub.baseURL + "/peers.json"])
        app.navigationTab("Settings").tap()
        let refresh = app.buttons["refreshPeerCatalogButton"]
        XCTAssertTrue(scrollUntilExists(app, refresh, maxSwipes: 8))
        refresh.tap()
        let notice = app.staticTexts["peerCatalogNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(notice.label.contains(today))
        XCTAssertTrue(notice.label.contains("1 clearnet, 0 Tor"))
        Screenshots.capture(app, "46-peer-refresh", testCase: self)
        try stub.catalog(Data("{\"schemaVersion\":99}".utf8))
        refresh.tap()
        XCTAssertTrue(app.staticTexts["peerCatalogError"].waitForExistence(timeout: 15))
        XCTAssertTrue(notice.label.contains(today))
        Screenshots.capture(app, "47-peer-refresh-failed", testCase: self)
        app.terminate()
        let reopened = launchApp(advanced: true)
        reopened.navigationTab("Settings").tap()
        XCTAssertTrue(scrollUntilExists(reopened, reopened.staticTexts["peerCatalogNotice"], maxSwipes: 8))
        XCTAssertTrue(reopened.staticTexts["peerCatalogNotice"].label.contains(today))
        let reset = reopened.buttons["resetPeersButton"]
        XCTAssertTrue(scrollUntilExists(reopened, reset, maxSwipes: 12))
        reset.tap()
        reopened.buttons["confirmResetPeersButton"].firstMatch.tap()
        XCTAssertTrue(scrollUntilExists(reopened, reopened.staticTexts["peerCatalogNotice"], maxSwipes: 12, up: true))
        XCTAssertTrue(reopened.staticTexts["peerCatalogNotice"].label.contains(today))
    }

    func test21TorStatesFailClosed() throws {
        let app = launchApp(advanced: true, environment: ["WINNOW_E2E_TOR_FAILURE": "1"])
        app.navigationTab("Settings").tap()
        let toggle = app.switches["torEnabledToggle"]
        XCTAssertTrue(scrollUntilExists(app, toggle, maxSwipes: 8))
        // A fixed extra swipe put this row underneath the iPad's floating
        // tabs. Center the actual row, away from either platform's tab bar.
        for _ in 0..<3 {
            let position = (toggle.frame.midY - app.frame.minY) / app.frame.height
            if (0.3...0.6).contains(position) { break }
            let delta = max(-0.3, min(0.3, 0.45 - position))
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5 + delta))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(toggle.isHittable)
        XCTAssertEqual(app.staticTexts["torState"].label, "State, Stopped")
        Screenshots.capture(app, "48-tor-stopped", testCase: self)
        app.flipSwitch(toggle)
        XCTAssertTrue(poll(timeout: 30, interval: 0.1, "Tor bootstrapping") {
            app.staticTexts["torState"].label == "State, Bootstrapping"
        })
        Screenshots.capture(app, "49-tor-bootstrapping", testCase: self)
        XCTAssertTrue(poll(timeout: 30, interval: 0.1, "Tor failed closed") {
            app.staticTexts["torState"].label == "State, Failed"
        })
        XCTAssertTrue(scrollUntilExists(app, app.buttons["retryTorButton"], maxSwipes: 4))
        XCTAssertTrue(scrollUntilExists(app, app.buttons["refreshPeerCatalogButton"], maxSwipes: 4))
        XCTAssertFalse(app.buttons["refreshPeerCatalogButton"].isEnabled)
        XCTAssertTrue(scrollUntilExists(app, toggle, maxSwipes: 4, up: true))
        Screenshots.capture(app, "50-tor-failed", testCase: self)
        app.flipSwitch(toggle)
        XCTAssertTrue(poll(timeout: 30, interval: 0.1, "explicit Tor disable") {
            app.staticTexts["torState"].label == "State, Stopped"
        })
    }
}
