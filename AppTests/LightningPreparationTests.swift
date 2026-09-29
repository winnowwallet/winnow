@testable import WinnowApp
import CryptoKit
import Foundation
import LightningCore
import TestSupport
import WalletCore
import XCTest

@MainActor
final class LightningPreparationTests: XCTestCase {
    private final class Journal: LightningJournal {
        var bytes: Data?
        func load() throws -> Data? { bytes }
        func store(_ snapshot: Data) throws { bytes = snapshot }
    }

    /// Controllers call this synchronous storage API on the main actor. The
    /// callback observes a real key commit, before preparation's actor awaits.
    private final class ObservedKeys: StoreKeyVault, @unchecked Sendable {
        let backing = InMemoryStoreKeyVault()
        var established: [String] = []
        var cancelSourcePreparation = false
        var sourceEstablished: (@MainActor () -> Void)?
        func key(for account: String) throws -> SymmetricKey? { try backing.key(for: account) }
        func discardKey(for account: String) throws { try backing.discardKey(for: account) }
        func establishKey(for account: String) throws -> SymmetricKey {
            let key = try backing.establishKey(for: account)
            established.append(account)
            if account == "lightning-journal-v2" {
                if cancelSourcePreparation { withUnsafeCurrentTask { $0?.cancel() } }
                MainActor.assumeIsolated { sourceEstablished?() }
            }
            return key
        }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "preparation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func backup() async throws -> LightningRecoveryBackup {
        let engine = try LightningEngine(chain: NetworkParams.regtest.genesisHash,
            nodeSecret: Data(repeating: 21, count: 32), journal: Journal())
        try await engine.persistIdentity()
        return try await engine.recoveryBackup()
    }

    private func assertSelectedRecovery(_ controller: LightningAppController, backup: LightningRecoveryBackup,
                                        root: URL) async throws {
        XCTAssertEqual(controller.nodeID, backup.nodeID.hex)
        XCTAssertEqual(controller.recoveryStatus?.backupID, backup.id)
        let engine = try XCTUnwrap(controller.engine)
        let actual = await engine.recoveryStatus()
        XCTAssertEqual(actual?.backupID, backup.id)
        XCTAssertEqual(actual?.sourceRevision, backup.revision)
        XCTAssertNotNil(controller.driver)
        XCTAssertTrue(controller.ordinaryRequests.isEmpty)
        XCTAssertTrue(controller.offers.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "lightning-recovery-selection.json").path))
        let journal = root.appending(path: "lightning-recovery/\(backup.id.uuidString)/lightning/journal.v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }

    private func assertReopenedRecovery(backup: LightningRecoveryBackup, root: URL, keys: ObservedKeys) async throws {
        let reopened = LightningAppController(network: .regtest, keys: keys)
        do { try await reopened.prepare(directory: root, headers: HeaderChain(params: .regtest)) }
        catch { XCTFail("Reopening the selected recovery namespace failed: \(error)"); throw error }
        XCTAssertEqual(reopened.nodeID, backup.nodeID.hex)
        XCTAssertEqual(reopened.recoveryStatus?.backupID, backup.id)
        XCTAssertEqual(reopened.recoveryStatus?.sourceRevision, backup.revision)
    }

    func testAlreadyCancelledPreparationDoesNotEstablishKeysOrInstallEngine() async throws {
        let root = try directory(), keys = ObservedKeys()
        let controller = LightningAppController(network: .regtest, keys: keys)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await controller.prepare(directory: root, headers: HeaderChain(params: .regtest))
        }
        do { try await operation.value; XCTFail("Canceled preparation installed an engine") }
        catch is CancellationError {}
        XCTAssertTrue(keys.established.isEmpty)
        XCTAssertNil(controller.engine)
        XCTAssertNil(controller.driver)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testPreparationCancelledAtKeyCommitCannotInstallAndRecoveryCanRetry() async throws {
        let root = try directory(), keys = ObservedKeys(), saved = try await backup()
        keys.cancelSourcePreparation = true
        var controller: LightningAppController? = LightningAppController(network: .regtest, keys: keys)
        let operation = Task { try await controller!.prepare(directory: root, headers: HeaderChain(params: .regtest)) }
        do { try await operation.value; XCTFail("Canceled preparation installed an engine") }
        catch is CancellationError {}
        XCTAssertTrue(keys.established.contains("lightning-journal-v2"))
        XCTAssertNil(controller!.engine)
        XCTAssertNil(controller!.driver)
        keys.cancelSourcePreparation = false
        do { try await controller!.restoreRecovery(saved, root: root, headers: HeaderChain(params: .regtest)) }
        catch { XCTFail("Restoring after canceled key establishment failed: \(error)"); throw error }
        try await assertSelectedRecovery(controller!, backup: saved, root: root)
        await controller!.stop()
        // A stopped controller still owns its encrypted journal's exclusive
        // writer lock. Reopening means releasing that owner, as on relaunch.
        controller = nil
        try await assertReopenedRecovery(backup: saved, root: root, keys: keys)
    }

    func testRestoreInvalidatesEarlierPreparationAndKeepsSelectedNamespaceAfterBothFinish() async throws {
        let root = try directory(), keys = ObservedKeys(), saved = try await backup()
        let headers = try HeaderChain(params: .regtest)
        var controller: LightningAppController? = LightningAppController(network: .regtest, keys: keys)
        var restoration: Task<Void, Error>?
        keys.sourceEstablished = {
            restoration = Task { try await controller!.restoreRecovery(saved, root: root, headers: headers) }
        }
        let preparation = Task { try await controller!.prepare(directory: root, headers: headers) }
        // The restore is queued by the actual source-key commit. Preparation
        // may finish first or lose its generation at any following actor await;
        // either schedule must leave the selected engine and journal coherent.
        do { try await preparation.value }
        catch is CancellationError {}
        keys.sourceEstablished = nil
        do { try await XCTUnwrap(restoration).value }
        catch { XCTFail("Concurrent recovery selection failed: \(error)"); throw error }
        restoration = nil
        try await controller!.refresh()
        try await assertSelectedRecovery(controller!, backup: saved, root: root)
        await controller!.stop()
        controller = nil
        try await assertReopenedRecovery(backup: saved, root: root, keys: keys)
    }

    func testMismatchedRepairBackupCannotChangeSelectedLightningRecoveryOrPendingWallet() async throws {
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "repair-order-\(UUID())",
            "WINNOW_E2E_NETWORK": "regtest", "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f"]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { return XCTFail("isolated repair fixture unavailable") }
        addTeardownBlock { cleanup.wipeIfRequested() }
        let keys = InMemoryStoreKeyVault(), spendingKeys = InMemoryKeyStore()
        let model = AppModel(deviceAuthenticator: SilentAuthenticator(), e2e: mode, storeKeys: keys, keyStore: spendingKeys)
        let root = try XCTUnwrap(model.storageDirectory()), walletFile = root.appending(path: "wallet.json")
        let original = try Wallet.create(network: .regtest, keyStore: InMemoryKeyStore(), entropy: Data(repeating: 7, count: 16), creationHeight: 0)
        let matching = try await original.recoveryBundle(includeMnemonic: true)
        let old = try Wallet.importing(matching, keyStore: spendingKeys, storageURL: walletFile)
        try await old.recordScanHeight(501)
        try WalletImportMetadata(keys: keys).begin(bundle: matching, network: .regtest, directory: root)
        let selected = try await backup(), controller = try XCTUnwrap(model.lightning)
        try await controller.restoreRecovery(selected, root: root, headers: HeaderChain(params: .regtest), walletDescriptor: matching.descriptor)
        await model.boot()
        guard case .storageDamaged = model.stage else { return XCTFail("advanced pending import did not fail closed") }
        XCTAssertTrue(model.hasPendingWalletImport)

        let selectorFile = root.appending(path: "lightning-recovery-selection.json")
        let markerFile = root.appending(path: WalletImportMetadata.fileName)
        let selectorBytes = try Data(contentsOf: selectorFile), markerBytes = try Data(contentsOf: markerFile)
        let walletBytes = try Data(contentsOf: walletFile), walletID = model.walletID
        let selectedEngine = try XCTUnwrap(controller.engine)
        let differentWallet = try Wallet.create(network: .regtest, keyStore: InMemoryKeyStore(), entropy: Data(repeating: 9, count: 16), creationHeight: 0)
        let differentBundle = try await differentWallet.recoveryBundle(includeMnemonic: true)
        let differentEngine = try LightningEngine(chain: NetworkParams.regtest.genesisHash,
            nodeSecret: Data(repeating: 22, count: 32), journal: Journal())
        try await differentEngine.persistIdentity()
        let differentBackup = try await differentEngine.recoveryBackup()
        let context = CloudAppState(network: differentBundle.network, descriptor: differentBundle.descriptor,
            people: .init(people: []), receiveLabels: [:], ownDisplayName: "", advancedMode: false, lightning: differentBackup)
        let contents = try CloudBackupContents(bundle: differentBundle, appState: context.encoded())
        do { _ = try await model.restorePortableLightningBackup(contents); XCTFail("Unrelated backup changed the interrupted import") }
        catch WalletError.descriptorMismatch {}

        XCTAssertEqual(try Data(contentsOf: selectorFile), selectorBytes)
        XCTAssertEqual(try Data(contentsOf: markerFile), markerBytes)
        XCTAssertEqual(try Data(contentsOf: walletFile), walletBytes)
        XCTAssertEqual(model.walletID, walletID)
        XCTAssertTrue(controller.engine === selectedEngine)
        let identity = try await selectedEngine.nodeID(), status = await selectedEngine.recoveryStatus()
        XCTAssertEqual(identity, selected.nodeID)
        XCTAssertEqual(status?.backupID, selected.id)
        XCTAssertEqual(controller.recoveryStatus?.backupID, selected.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "lightning-recovery/\(differentBackup.id.uuidString)").path))
        XCTAssertFalse(model.keychainAuthentication.isGranted)
        XCTAssertNil(model.stack)
    }
}
