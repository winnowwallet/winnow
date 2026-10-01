@testable import WinnowApp
import CryptoKit
import Foundation
import LightningCore
import TestSupport
import WalletCore
import XCTest

@MainActor
final class LightningRoadmapTests: XCTestCase {
    private final class Journal: LightningJournal {
        var bytes: Data?
        func load() throws -> Data? { bytes }
        func store(_ snapshot: Data) throws { bytes = snapshot }
    }
    private final class Denied: DeviceAuthenticating {
        func authenticate(reason: String) async throws { throw CancellationError() }
    }
    private final class PausedAuthenticator: DeviceAuthenticating {
        var continuation: CheckedContinuation<Void, Error>?
        var started: (() -> Void)?
        func authenticate(reason: String) async throws {
            try await withCheckedThrowingContinuation { continuation = $0; started?() }
        }
    }
    private final class CancelOnRecoveryKey: StoreKeyVault, @unchecked Sendable {
        let backing = InMemoryStoreKeyVault()
        var cancel = true
        func key(for account: String) throws -> SymmetricKey? { try backing.key(for: account) }
        func discardKey(for account: String) throws { try backing.discardKey(for: account) }
        func establishKey(for account: String) throws -> SymmetricKey {
            let key = try backing.establishKey(for: account)
            if cancel, account.hasPrefix("lightning-recovery-v1.") { withUnsafeCurrentTask { $0?.cancel() } }
            return key
        }
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "roadmap-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func contents() async throws -> (CloudBackupContents, LightningRecoveryBackup) {
        let wallet = try Wallet.create(network: .regtest, keyStore: InMemoryKeyStore(), entropy: Data(repeating: 7, count: 16))
        let bundle = try await wallet.recoveryBundle(includeMnemonic: true)
        let engine = try LightningEngine(chain: NetworkParams.regtest.genesisHash,
            nodeSecret: Data(repeating: 21, count: 32), journal: Journal())
        try await engine.persistIdentity()
        let backup = try await engine.recoveryBackup()
        let context = CloudAppState(network: bundle.network, descriptor: bundle.descriptor,
            people: .init(people: []), receiveLabels: [:], ownDisplayName: "", advancedMode: false)
        let state = PortableLightningState(context: context, lightning: backup)
        return try (CloudBackupContents(bundle: bundle, appState: state.encoded()), backup)
    }
    func testPortableFileUsesSeparatePhraseAndRestoresIntoFreshDeviceNamespace() async throws {
        let (original, backup) = try await contents()
        let prepared = try PortableLightningBackup.prepare(original)
        XCTAssertEqual(prepared.phrase.split(separator: " ").count, 24)
        XCTAssertNotEqual(prepared.phrase, original.bundle.mnemonic)
        XCTAssertFalse(String(decoding: prepared.file, as: UTF8.self).contains(prepared.phrase))
        let restored = try PortableLightningBackup.restore(prepared.file, phrase: prepared.phrase, network: .regtest)
        XCTAssertEqual(try restored.bundle.serialized(), try original.bundle.serialized())
        let state = try PortableLightningState.decode(restored.appState, for: restored.bundle)
        XCTAssertEqual(state.lightning, backup)
        let root = try directory(), freshKeys = InMemoryStoreKeyVault()
        var controller: LightningAppController? = LightningAppController(network: .regtest, keys: freshKeys)
        try await controller!.restoreRecovery(state.lightning, root: root, headers: HeaderChain(params: .regtest), walletDescriptor: original.bundle.descriptor)
        XCTAssertThrowsError(try controller!.requireRecoveryWalletMatch(root: root, importing: nil))
        XCTAssertThrowsError(try controller!.requireRecoveryWalletMatch(root: root, importing: "unrelated-wallet"))
        XCTAssertNoThrow(try controller!.requireRecoveryWalletMatch(root: root, importing: original.bundle.descriptor))
        XCTAssertEqual(controller!.nodeID, backup.nodeID.hex)
        XCTAssertEqual(controller!.recoveryStatus?.backupID, backup.id)
        XCTAssertNil(controller!.profile)
        let journal = root.appending(path: "lightning-recovery/\(backup.id.uuidString)/lightning/journal.v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "lightning/journal.v1").path))
        await controller!.stop(); controller = nil
        let reopened = LightningAppController(network: .regtest, keys: freshKeys)
        try await reopened.prepare(directory: root, headers: HeaderChain(params: .regtest))
        XCTAssertEqual(reopened.recoveryStatus?.backupID, backup.id)
        XCTAssertEqual(reopened.nodeID, backup.nodeID.hex)
        try await reopened.restoreRecovery(backup, root: root, headers: HeaderChain(params: .regtest))
        XCTAssertEqual(reopened.recoveryStatus?.backupID, backup.id)
        XCTAssertTrue(reopened.ordinaryRequests.isEmpty)
        XCTAssertTrue(reopened.payments.isEmpty)
    }
    /// Files exported by earlier Winnow Lightning builds carry the iCloud
    /// context's fields flat, at version 2, beside `lightning`. A context
    /// without channel keys is not a Lightning recovery file.
    func testRecoveryContextKeepsTheFlatVersionTwoLayout() async throws {
        let (original, backup) = try await contents()
        let data = try XCTUnwrap(original.appState)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(object["network"] as? String, "regtest")
        XCTAssertEqual(object["descriptor"] as? String, original.bundle.descriptor)
        XCTAssertNotNil(object["lightning"])
        let state = try PortableLightningState.decode(data, for: original.bundle)
        XCTAssertEqual(state.lightning, backup)
        XCTAssertEqual(state.context.version, 1)
        XCTAssertEqual(try state.encoded(), data)
        let plain = try state.context.encoded()
        XCTAssertThrowsError(try PortableLightningState.decode(plain, for: original.bundle))
        XCTAssertThrowsError(try PortableLightningState.decode(nil, for: original.bundle))
    }
    func testWrongPhraseNetworkAndDamagedFileRejectBeforeCreatingRecoveryState() async throws {
        let (original, _) = try await contents()
        let prepared = try PortableLightningBackup.prepare(original)
        let otherPhrase = try BIP39.mnemonic(entropy: Data(repeating: 1, count: 32))
        XCTAssertThrowsError(try PortableLightningBackup.restore(prepared.file, phrase: otherPhrase, network: .regtest))
        XCTAssertThrowsError(try PortableLightningBackup.restore(prepared.file, phrase: prepared.phrase, network: .mainnet))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.file) as? [String: Any])
        // Damage authenticated content while retaining valid JSON/container metadata.
        object["sealedWallet"] = Data(repeating: 1, count: 48).base64EncodedString()
        let damaged = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try PortableLightningBackup.restore(damaged, phrase: prepared.phrase, network: .regtest))
        XCTAssertThrowsError(try PortableLightningBackup.restore(prepared.file, phrase: original.bundle.mnemonic ?? "", network: .regtest))
        let model = makeModel(network: .regtest, deviceAuthenticator: Denied())
        do { _ = try await model.restorePortableLightningBackup(original); XCTFail("Canceled authentication restored keys") }
        catch is CancellationError {}
        XCTAssertNil(model.walletID)
        XCTAssertFalse(model.keychainAuthentication.isGranted)
    }
    func testReceiveIntentSurvivesRestartAndProviderMinimumIsSeparateFromPayment() async throws {
        let root = try directory(), keys = InMemoryStoreKeyVault(), model = makeModel(network: .regtest)
        var controller: LightningAppController? = LightningAppController(network: .regtest, keys: keys)
        try await controller!.prepare(directory: root, headers: HeaderChain(params: .regtest))
        try controller!.setReceiveAmount(500, model: model)
        let intent = try XCTUnwrap(controller!.receiveIntent)
        let info = try LightningLiquidity.decode(LightningLiquidity.Info.self, from: Data("""
        {"min_required_channel_confirmations":3,"min_funding_confirms_within_blocks":6,"max_channel_expiry_blocks":13140,
         "min_initial_client_balance_sat":"0","max_initial_client_balance_sat":"0","min_initial_lsp_balance_sat":"100000",
         "max_initial_lsp_balance_sat":"1000000","min_channel_balance_sat":"100000","max_channel_balance_sat":"1000000"}
        """.utf8))
        XCTAssertEqual(try intent.capacity(using: info), 100_000)
        XCTAssertEqual(intent.amountSat, 500)
        XCTAssertThrowsError(try intent.validate(network: .mainnet))
        XCTAssertThrowsError(try controller!.setReceiveAmount(0, model: model))
        XCTAssertThrowsError(try controller!.setReceiveAmount(UInt64.max, model: model))
        await controller!.stop(); controller = nil
        let reopened = LightningAppController(network: .regtest, keys: keys)
        try await reopened.prepare(directory: root, headers: HeaderChain(params: .regtest))
        XCTAssertEqual(reopened.receiveIntent, intent)
        XCTAssertTrue(reopened.channels.isEmpty)
        XCTAssertTrue(reopened.payments.isEmpty)
    }
    func testCancelledRestoreDoesNotSelectPartiallyWrittenNamespaceAndCanRetry() async throws {
        let (_, backup) = try await contents(), root = try directory(), keys = CancelOnRecoveryKey()
        let controller = LightningAppController(network: .regtest, keys: keys)
        let interrupted = Task { try await controller.restoreRecovery(backup, root: root, headers: HeaderChain(params: .regtest)) }
        do { try await interrupted.value; XCTFail("Canceled restore selected recovery keys") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "lightning-recovery-selection.json").path))
        XCTAssertNil(controller.engine)
        keys.cancel = false
        try await controller.restoreRecovery(backup, root: root, headers: HeaderChain(params: .regtest))
        XCTAssertEqual(controller.recoveryStatus?.backupID, backup.id)
        XCTAssertEqual(controller.nodeID, backup.nodeID.hex)
    }
    func testRestoreExcludesNetworkSwitchAndSpendingAcrossAuthentication() async throws {
        let (original, _) = try await contents(), authentication = PausedAuthenticator()
        let started = expectation(description: "restore awaiting authentication")
        authentication.started = { started.fulfill() }
        let model = makeModel(network: .regtest, deviceAuthenticator: authentication)
        let operation = Task { try await model.restorePortableLightningBackup(original) }
        await fulfillment(of: [started], timeout: 5)
        do { try await model.exclusively(.spending) { XCTFail("Restore allowed another wallet mutation") } }
        catch AppModel.AppError.spendAlreadyInFlight {}
        await model.switchNetwork(to: .mainnet)
        XCTAssertEqual(model.network, .regtest)
        authentication.continuation?.resume(throwing: CancellationError())
        do { _ = try await operation.value; XCTFail("Denied restore installed keys") }
        catch is CancellationError {}
        XCTAssertNil(model.walletID)
        let released = try await model.exclusively(.spending) { true }
        XCTAssertTrue(released)
    }
    func testAppRestoreInstallsMatchingWalletAndRecoveryBeforeNetworking() async throws {
        let (original, backup) = try await contents()
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "restore-roadmap-\(UUID())",
            "WINNOW_E2E_NETWORK": "regtest", "WINNOW_E2E_PEER": "127.0.0.1:1",
            "WINNOW_E2E_ENTROPY": String(repeating: "03", count: 16)]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { return XCTFail("isolated restore fixture") }
        defer { cleanup.wipeIfRequested() }
        let keys = InMemoryKeyStore(), seals = InMemoryStoreKeyVault()
        let model = AppModel(deviceAuthenticator: SilentAuthenticator(), e2e: mode,
            storeKeys: seals, keyStore: keys)
        await model.boot()
        XCTAssertNil(model.walletID)
        XCTAssertNil(model.stack)
        do { _ = try await model.portableLightningBackupContents(); XCTFail("exported without a wallet") }
        catch AppModel.AppError.noWallet {}
        _ = try await model.restorePortableLightningBackup(original)
        let restoredDescriptor = await model.wallet?.descriptor
        XCTAssertEqual(restoredDescriptor?.serialized(), original.bundle.descriptor)
        XCTAssertEqual(model.lightning?.recoveryStatus?.backupID, backup.id)
        XCTAssertEqual(model.lightning?.nodeID, backup.nodeID.hex)
        XCTAssertEqual(model.stage, .ready)
        XCTAssertNil(model.stack, "recovery-only state must not depend on connecting to a peer")
        XCTAssertFalse(model.keychainAuthentication.isGranted)

        // The restored wallet exports a recovery file that restores the same
        // wallet and Lightning identity.
        let exported = try await model.portableLightningBackupContents()
        XCTAssertEqual(exported.bundle.descriptor, original.bundle.descriptor)
        XCTAssertEqual(exported.bundle.mnemonic, original.bundle.mnemonic)
        let exportedState = try PortableLightningState.decode(exported.appState, for: exported.bundle)
        XCTAssertEqual(exportedState.lightning.nodeID, backup.nodeID)
        XCTAssertFalse(model.keychainAuthentication.isGranted, "the export's authorization ends with it")
        _ = try await model.restorePortableLightningBackup(original)
        XCTAssertEqual(model.lightning?.recoveryStatus?.backupID, backup.id)
        do { try await model.createWallet(); XCTFail("fresh keys replaced a restored wallet") }
        catch AppModel.AppError.storageDamaged {}
    }
}
