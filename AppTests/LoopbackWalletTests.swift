@testable import WinnowApp
import Foundation
import TestSupport
import WalletCore
import XCTest

/// The app's real sync stack against a loopback node serving a synthetic chain
/// that pays this wallet: import verification and on-demand payment details run
/// end to end without a Bitcoin node or a UI journey.
@MainActor
final class LoopbackWalletTests: XCTestCase {
    private static let entropy = "000102030405060708090a0b0c0d0e0f"
    private static let fundedAmount: Int64 = 100_000
    private static let fundedHeight: UInt32 = 3

    private struct Fixture {
        let model: AppModel
        let chain: SyntheticChain
        let source: Wallet
    }

    /// A chain paying the pinned seed's first receive address, a node serving
    /// it, and a model in an isolated E2E run pointed at that node alone.
    private func fixture(length: Int = 10, cloudBackups: CloudBackupController? = nil) async throws -> Fixture {
        let entropy = try XCTUnwrap(Data(hex: Self.entropy))
        let source = try Wallet.create(network: .signet, keyStore: InMemoryKeyStore(), entropy: entropy)
        let script = try await source.scriptPubKey(chain: .receive, index: 0)
        let chain = makeSyntheticChain(length: length, watchHeight: Self.fundedHeight,
                                       watchScript: script, watchAmount: Self.fundedAmount)
        let node = LoopbackNode(params: chain.params, chain: chain.blocks)
        try await node.start()
        let port = await node.port
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "loopback-\(UUID().uuidString)",
                           "WINNOW_E2E_ENTROPY": Self.entropy, "WINNOW_E2E_PEER": "127.0.0.1:\(port)",
                           "WINNOW_E2E_PEER_COUNT": "1", "WINNOW_E2E_SYNC_INTERVAL": "1"]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { throw XCTSkip("unreachable: the environment above is complete") }
        let model = AppModel(deviceAuthenticator: SilentAuthenticator(), e2e: mode,
                             storeKeys: InMemoryStoreKeyVault(), keyStore: InMemoryKeyStore(),
                             cloudBackups: cloudBackups, networkParams: chain.params)
        addTeardownBlock { @MainActor in
            await model.scenePhaseChanged(.background)
            await node.stop()
            cleanup.wipeIfRequested()
        }
        return Fixture(model: model, chain: chain, source: source)
    }

    private func settle(_ what: String, timeout: TimeInterval = 30,
                        _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("timed out waiting: \(what)")
    }

    /// Importing a bundle verifies it against the chain before it is trusted:
    /// the scan reaches the tip and finds the coin the chain paid.
    func testImportVerifiesTheBundleAgainstTheChain() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        await model.boot()
        XCTAssertEqual(model.stage, .onboarding)
        await model.scenePhaseChanged(.active)
        let bundle = try await fixture.source.exportBundle(includeMnemonic: true)

        let result = try await model.importWallet(bundleJSON: bundle.serialized())
        let report = try XCTUnwrap(result, "a reachable peer must let the import verify")
        let sourceID = await fixture.source.id
        XCTAssertEqual(model.walletID, sourceID)
        XCTAssertEqual(report.scannedToHeight, UInt32(fixture.chain.blocks.count - 1))
        XCTAssertTrue(report.matchesBundle)
        XCTAssertEqual(report.discoveredUTXOs.map(\.amount), [Self.fundedAmount],
                       "the chain's payment is found even though the bundle predates it")
        XCTAssertEqual(report.discoveredUTXOs.first?.height, Self.fundedHeight)
        model.finishOnboarding()
        XCTAssertEqual(model.stage, .ready)
    }

    /// A payment is replaced at a higher rate: the replacement is signed from
    /// the same coins, relayed, and the history keeps the original beside it.
    func testFeeBumpReplacesAPendingPayment() async throws {
        let fixture = try await fixture(length: Int(Self.fundedHeight + Wallet.coinbaseMaturity) + 5)
        let model = fixture.model
        try await openFundedWallet(model)
        let destination = try await fixture.source.address(chain: .receive, index: 7)
        let preview = try await model.previewSend(destination: destination, amount: 20_000,
                                                  priority: .low, override: 1)
        let original = try await model.send(preview: preview)

        let bump = try await model.previewFeeBump(txid: original, feeRateSatPerVByte: 5)
        let replacement = try await model.bumpFee(preview: bump)
        XCTAssertNotEqual(replacement, original)
        let history = model.status.history
        XCTAssertEqual(history.first { $0.txid == original }?.replacedBy, replacement)
        let replacementFee = try XCTUnwrap(history.first { $0.txid == replacement }?.fee)
        XCTAssertGreaterThan(replacementFee, preview.fee, "the replacement pays more")
    }

    /// The pinned seed's wallet file in this run's storage, opened and synced
    /// until the chain's payment is in the balance.
    private func openFundedWallet(_ model: AppModel) async throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appending(path: try XCTUnwrap(model.e2e).storageDirectoryName)
        try FileManager.default.createDirectory(at: root.appending(path: "signet"), withIntermediateDirectories: true)
        _ = try Wallet.create(network: .signet, keyStore: model.keyStore,
                              storageURL: root.appending(path: "signet/wallet.json"),
                              entropy: try XCTUnwrap(Data(hex: Self.entropy)))
        await model.boot()
        await model.scenePhaseChanged(.active)
        try await settle("the scan finds the payment") { model.status.balance == Self.fundedAmount }
    }

    /// A received payment's outputs are fetched from its block when the
    /// details are first opened, and kept for the next time.
    func testPaymentDetailsLoadFromTheConfirmingBlock() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        try await openFundedWallet(model)
        let received = try XCTUnwrap(model.status.history.first { $0.height == Self.fundedHeight })

        try await model.loadPaymentDetails(received)
        let loaded = try XCTUnwrap(model.status.history.first { $0.txid == received.txid })
        let raw = try XCTUnwrap(loaded.rawTransaction, "the details were not kept")
        XCTAssertEqual(try WalletCore.Transaction.decode(raw).txid, received.txid)
        try await model.loadPaymentDetails(loaded) // already kept: nothing to fetch
    }

    /// Restoring from iCloud imports the saved wallet, verifies it against the
    /// chain like any import, and resumes automatic backup for it.
    func testCloudRestoreImportsVerifiesAndResumesBackup() async throws {
        // One iCloud database and one iCloud Keychain, seen from two devices.
        let store = MemoryCloudBackups()
        let keys = MemoryCloudKeys()
        let controller = CloudBackupController(store: store, keys: keys)
        let fixture = try await fixture(cloudBackups: controller)
        let sourceID = await fixture.source.id
        let saved = CloudBackupController(store: store, keys: keys)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        saved.configure(directory: directory, walletID: sourceID)
        try await saved.enable(bundle: try await fixture.source.exportBundle(includeMnemonic: true), walletID: sourceID)

        let model = fixture.model
        await model.boot()
        await model.scenePhaseChanged(.active)
        await controller.discover(network: "signet")
        let id = try XCTUnwrap(controller.available.first?.id)
        let report = try await model.restoreCloudBackup(id)

        XCTAssertEqual(model.walletID, sourceID)
        XCTAssertEqual(report?.discoveredUTXOs.map(\.amount), [Self.fundedAmount])
        XCTAssertNil(AppModel.cloudRestoreMessage(for: report), "the chain agreed with the backup")
        XCTAssertNotNil(AppModel.cloudRestoreMessage(for: nil), "an unverified restore says so")
        XCTAssertNotNil(model.cloudRestoreNotice, "a backup without app state says what it lacks")
        XCTAssertTrue(controller.enabled, "this device backs the restored wallet up again")
    }

    /// The bump-fee sheet's model: it proposes one sat/vB above the current
    /// rate, reviews it, re-reviews an edited rate and signs the replacement.
    func testFeeBumpReviewProposesReviewsAndReplaces() async throws {
        let fixture = try await fixture(length: Int(Self.fundedHeight + Wallet.coinbaseMaturity) + 5)
        let model = fixture.model
        try await openFundedWallet(model)
        let destination = try await fixture.source.address(chain: .receive, index: 7)
        let original = try await model.send(preview: try await model.previewSend(
            destination: destination, amount: 20_000, priority: .low, override: 1))

        let review = FeeBumpReview(txid: original)
        await review.load(using: model)
        XCTAssertNil(review.error)
        let current = try XCTUnwrap(review.currentRate)
        XCTAssertEqual(review.targetRateText, String(format: "%.0f", ceil(current + 1)))
        XCTAssertEqual(review.reviewed?.request, review.inputs)

        review.targetRateText = "6"
        review.inputsChanged()
        XCTAssertNil(review.reviewed, "an edited rate is not the reviewed one")
        await review.review(using: model)
        XCTAssertEqual(review.reviewed?.request.targetRateText, "6")
        await review.bump(using: model)
        XCTAssertNil(review.error)
        let replacement = try XCTUnwrap(review.replacementTxid)
        XCTAssertEqual(model.status.history.first { $0.txid == original }?.replacedBy, replacement)

        let settled = FeeBumpReview(txid: Data(repeating: 0xEE, count: 32))
        await settled.load(using: model)
        XCTAssertNotNil(settled.error, "a payment that is not pending cannot be bumped")
    }

    /// The payment screen's load turns a missing transaction into a message
    /// and a loaded one into none.
    func testPaymentDetailsErrorsAreMessages() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        try await openFundedWallet(model)
        let received = try XCTUnwrap(model.status.history.first)
        let loaded = await model.paymentDetailsError(received)
        XCTAssertNil(loaded)
        let unknown = HistoryEntry(txid: Data(repeating: 0xEE, count: 32), height: 0, received: 0, spent: 1)
        let failed = await model.paymentDetailsError(unknown)
        XCTAssertNotNil(failed)
    }

    /// "Reset and shuffle peers": with networking up, the pool forgets what it
    /// learned and reconnects; with it down, the saved peers file is removed.
    func testResettingPeersForgetsThemWithOrWithoutNetworking() async throws {
        let fixture = try await fixture()
        let model = fixture.model
        try await openFundedWallet(model)
        let peersFile = try XCTUnwrap(model.storageDirectory()).appending(path: "peers.json")
        await model.resetPeers()
        XCTAssertNil(model.status.lastSyncError)
        try await settle("networking comes back after the reset") { model.status.peerCount == 1 }

        await model.scenePhaseChanged(.background)
        try Data("[]".utf8).write(to: peersFile)
        await model.resetPeers()
        XCTAssertFalse(FileManager.default.fileExists(atPath: peersFile.path), "the saved peers are forgotten")
    }
}
