@testable import WinnowApp
import CryptoKit
import Foundation
import TestSupport
import WalletCore
import XCTest

@MainActor
final class CloudBackupTests: XCTestCase {
    private func fixture() async throws -> (CloudBackupController, MemoryCloudBackups, ImportBundle, URL) {
        let store = MemoryCloudBackups()
        let controller = CloudBackupController(store: store, keys: MemoryCloudKeys())
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let wallet = try Wallet.create(network: .signet, keyStore: InMemoryKeyStore(),
                                       entropy: Data(repeating: 9, count: 16), creationHeight: 100)
        controller.configure(directory: directory, walletID: "test-wallet")
        return (controller, store, try await wallet.exportBundle(includeMnemonic: true), directory)
    }

    func testNoUploadUntilPreparedAndStopKeepsCloudCopy() async throws {
        let (controller, store, bundle, _) = try await fixture()
        try await controller.update { XCTFail("disabled backup requested wallet data"); return bundle }
        let initialCount = await store.count
        XCTAssertEqual(initialCount, 0)
        try await controller.enable(bundle: bundle, walletID: "test-wallet")
        XCTAssertTrue(controller.enabled)
        try controller.stop()
        XCTAssertFalse(controller.enabled)
        let remaining = await store.count
        XCTAssertEqual(remaining, 1)
    }

    func testFailedUploadKeepsLastSuccessfulBackup() async throws {
        let (controller, store, bundle, _) = try await fixture()
        try await controller.enable(bundle: bundle, walletID: "test-wallet")
        let saved = controller.lastSaved
        await store.setFailing(true)
        var updated = bundle
        updated.mnemonic = nil
        updated.nextReceiveIndex = 7
        do {
            try await controller.update { updated }
            XCTFail("failed upload was treated as saved")
        } catch { }
        XCTAssertEqual(controller.lastSaved, saved)
        await store.setFailing(false)
        await controller.discover(network: "signet")
        let id = try XCTUnwrap(controller.available.first?.id)
        let restored = try await controller.restore(id)
        XCTAssertEqual(restored, bundle)
    }

    func testReconfigureSameWalletDoesNotCancelBackup() async throws {
        let (controller, _, bundle, directory) = try await fixture()
        controller.configure(directory: directory, walletID: "test-wallet")
        try await controller.enable(bundle: bundle, walletID: "test-wallet")
        controller.configure(directory: directory, walletID: "test-wallet")
        XCTAssertTrue(controller.enabled)
        controller.configure(directory: directory, walletID: "another-wallet")
        XCTAssertFalse(controller.enabled)
    }

    func testCancelledExportCannotUploadToAnotherWallet() async throws {
        let (controller, store, bundle, directory) = try await fixture()
        try await controller.enable(bundle: bundle, walletID: "test-wallet")
        do {
            try await controller.update {
                controller.configure(directory: directory, walletID: "another-wallet")
                var next = bundle
                next.nextReceiveIndex = 8
                return next
            }
            XCTFail("wallet change was ignored")
        } catch is CancellationError { }
        let saves = await store.saves
        XCTAssertEqual(saves, 1)
        XCTAssertFalse(controller.enabled)
    }

    func testChangedAccountCannotOverwriteExistingBackup() async throws {
        let (controller, store, bundle, _) = try await fixture()
        try await controller.enable(bundle: bundle, walletID: "test-wallet")
        await store.changeAccount()
        var next = bundle
        next.nextReceiveIndex = 6
        do {
            try await controller.update { next }
            XCTFail("account change was ignored")
        } catch ICloudBackupError.accountChanged { }
        let saves = await store.saves
        XCTAssertEqual(saves, 1)
    }

    func testLateUploadCannotEnableBackupAfterWalletChange() async throws {
        let (controller, store, bundle, directory) = try await fixture()
        await store.holdNextSave()
        let enable = Task { try await controller.enable(bundle: bundle, walletID: "test-wallet") }
        await store.waitUntilSaveIsHeld()
        controller.configure(directory: directory, walletID: "another-wallet")
        await store.releaseSave()
        do {
            try await enable.value
            XCTFail("late cloud acknowledgement enabled backup for another wallet")
        } catch is CancellationError { }
        XCTAssertFalse(controller.enabled)
        XCTAssertNil(controller.lastSaved)
        let reopened = CloudBackupController(store: store, keys: MemoryCloudKeys())
        reopened.configure(directory: directory, walletID: "another-wallet")
        XCTAssertFalse(reopened.enabled, "the encrypted retry must not configure a different wallet")
    }

    func testOnlyChangingAppContextStillUpdatesBackup() async throws {
        let (controller, store, bundle, _) = try await fixture()
        try await controller.enable(bundle: bundle, appState: Data("before".utf8), walletID: "test-wallet")
        var watchOnly = bundle
        watchOnly.mnemonic = nil
        try await controller.updateContents { CloudBackupContents(bundle: watchOnly, appState: Data("after".utf8)) }
        let saves = await store.saves
        XCTAssertEqual(saves, 2)
        await controller.discover(network: "signet")
        let id = try XCTUnwrap(controller.available.first?.id)
        let restored = try await controller.restoreContents(id)
        XCTAssertEqual(restored.contents.appState, Data("after".utf8))
        XCTAssertEqual(restored.contents.bundle, bundle)
    }

    func testRestoredDeviceResumesBackupsAcrossOfflineRelaunchWithoutOverwritingOriginal() async throws {
        let (original, store, bundle, directory) = try await fixture()
        try await original.enable(bundle: bundle, walletID: "test-wallet")
        await original.discover(network: "signet")
        let sourceID = try XCTUnwrap(original.available.first?.id)
        let restored = try await original.restoreContents(sourceID)
        let keys = MemoryCloudKeys()
        let replacement = directory.appending(path: "replacement")
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let controller = CloudBackupController(store: store, keys: keys)
        controller.configure(directory: replacement, walletID: "test-wallet")
        try controller.resume(contents: restored.contents, walletID: "test-wallet", account: restored.account)
        XCTAssertTrue(controller.enabled)
        XCTAssertNil(controller.lastSaved, "an encrypted local retry is not an acknowledged cloud save")
        await store.setFailing(true)
        do {
            try await controller.update { bundle }
            XCTFail("offline save should fail")
        } catch { }
        XCTAssertTrue(controller.enabled)
        XCTAssertNil(controller.lastSaved)
        let reopened = CloudBackupController(store: store, keys: keys)
        reopened.configure(directory: replacement, walletID: "test-wallet")
        XCTAssertTrue(reopened.enabled)
        XCTAssertNil(reopened.lastSaved)
        await store.setFailing(false)
        try await reopened.update { bundle }
        XCTAssertNotNil(reopened.lastSaved)
        let copies = await store.count
        XCTAssertEqual(copies, 2, "the replacement phone must get its own record")
        let previous = try await original.restore(sourceID)
        XCTAssertEqual(previous, bundle)
    }

    func testAutomaticDefaultAndOptOutSurviveRestartAndWalletChanges() async throws {
        let (controller, store, bundle, directory) = try await fixture()
        XCTAssertTrue(controller.automaticEnabled)
        XCTAssertEqual(controller.statusTitle, "Not backed up")
        try controller.prepare(contents: CloudBackupContents(bundle: bundle), walletID: "test-wallet")
        XCTAssertEqual(controller.statusTitle, "Backing up")
        try controller.stop()
        let reopened = CloudBackupController(store: store, keys: MemoryCloudKeys())
        reopened.configure(directory: directory, walletID: "test-wallet")
        XCTAssertFalse(reopened.automaticEnabled)
        try reopened.prepare(contents: CloudBackupContents(bundle: bundle), walletID: "test-wallet")
        XCTAssertFalse(reopened.enabled)
        reopened.configure(directory: directory, walletID: "new-wallet")
        XCTAssertTrue(reopened.automaticEnabled)
        reopened.configure(directory: directory, walletID: "test-wallet")
        XCTAssertFalse(reopened.automaticEnabled)
        try reopened.setAutomatic(true)
        XCTAssertTrue(reopened.needsPreparation)
    }

    func testOfflineInitialPreparationDoesNotRequireAnAccountOrClaimSuccess() async throws {
        let (controller, store, bundle, _) = try await fixture()
        await store.setFailing(true)
        try controller.prepare(contents: CloudBackupContents(bundle: bundle), walletID: "test-wallet")
        XCTAssertTrue(controller.enabled)
        XCTAssertNil(controller.lastSaved)
        do { try await controller.update { bundle }; XCTFail("offline upload succeeded") } catch { }
        XCTAssertNil(controller.lastSaved)
        await store.setFailing(false)
        try await controller.update { bundle }
        XCTAssertEqual(controller.statusTitle, "Backed up")
    }

    func testScheduledFailuresBackOffWithoutDroppingAutomaticPreference() async throws {
        let (controller, store, bundle, _) = try await fixture()
        try controller.prepare(contents: CloudBackupContents(bundle: bundle), walletID: "test-wallet")
        await store.setFailing(true)
        controller.schedule { CloudBackupContents(bundle: bundle) }
        let deadline = Date().addingTimeInterval(8)
        while controller.message == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(controller.message)
        XCTAssertTrue(controller.automaticEnabled)
        XCTAssertEqual(controller.statusTitle, "Not backed up")
        XCTAssertGreaterThan(controller.retryAfter.timeIntervalSinceNow, 50)
        controller.schedule { XCTFail("retry ignored backoff"); return CloudBackupContents(bundle: bundle) }
        let attempts = await store.saveAttempts
        XCTAssertEqual(attempts, 1)
        controller.suspend()
    }

    func testNewInstallationFindsBackupButWaitsForItsKey() async throws {
        let (_, store, bundle, directory) = try await fixture()
        let sharedKeys = MemoryCloudKeys()
        let original = CloudBackupController(store: store, keys: sharedKeys)
        original.configure(directory: directory, walletID: "test-wallet")
        try await original.enable(bundle: bundle, walletID: "test-wallet")

        let waiting = CloudBackupController(store: store, keys: MemoryCloudKeys())
        await waiting.discover(network: "signet")
        let id = try XCTUnwrap(waiting.available.first?.id)
        do {
            _ = try await waiting.restore(id)
            XCTFail("restore succeeded before its key arrived")
        } catch ICloudBackupError.keyUnavailable { }

        let restoredInstallation = CloudBackupController(store: store, keys: sharedKeys)
        await restoredInstallation.discover(network: "signet")
        let recovered = try await restoredInstallation.restore(id)
        XCTAssertEqual(recovered, bundle)
        let saves = await store.saves
        XCTAssertEqual(saves, 1, "restore must not replace the existing backup or key")
    }
}

actor MemoryCloudBackups: ICloudBackupStoring {
    private var records: [UUID: CloudWalletBackup] = [:]
    private var failing = false
    private var accountName = "first-account"
    private var accountUnavailable = false
    private(set) var saveAttempts = 0
    private var holdSave = false
    private var saveGate: CheckedContinuation<Void, Never>?
    private var saveStarted: CheckedContinuation<Void, Never>?
    private(set) var saves = 0
    var count: Int { records.count }
    func setFailing(_ value: Bool) { failing = value }
    func changeAccount() { accountName = "second-account" }
    func setAccountUnavailable(_ value: Bool) { accountUnavailable = value }
    func holdNextSave() { holdSave = true }
    func waitUntilSaveIsHeld() async {
        if saveGate != nil { return }
        await withCheckedContinuation { saveStarted = $0 }
    }
    func releaseSave() { saveGate?.resume(); saveGate = nil }
    func account() async throws -> String {
        guard !accountUnavailable else { throw ICloudBackupError.unavailable }
        return accountName
    }
    func list(network: String) async throws -> [ICloudBackupSummary] {
        records.values.filter { $0.network == network }.map {
            ICloudBackupSummary(id: $0.id, network: $0.network, savedAt: $0.savedAt)
        }
    }
    func save(_ backup: CloudWalletBackup, account: String) async throws {
        saveAttempts += 1
        guard account == accountName else { throw ICloudBackupError.accountChanged }
        guard !failing else { throw ICloudBackupError.unavailable }
        records[backup.id] = backup
        saves += 1
        if holdSave {
            holdSave = false
            await withCheckedContinuation { continuation in
                saveGate = continuation
                saveStarted?.resume()
                saveStarted = nil
            }
        }
    }
    func load(_ id: UUID, account: String) async throws -> CloudWalletBackup {
        guard let result = records[id] else { throw ICloudBackupError.invalidBackup }
        return result
    }
}

final class MemoryCloudKeys: ICloudBackupKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: SymmetricKey] = [:]
    func create(_ id: UUID) throws -> SymmetricKey {
        lock.withLock {
            let key = SymmetricKey(size: .bits256)
            keys[id] = key
            return key
        }
    }
    func load(_ id: UUID) throws -> SymmetricKey {
        try lock.withLock {
            guard let key = keys[id] else { throw ICloudBackupError.keyUnavailable }
            return key
        }
    }
}
