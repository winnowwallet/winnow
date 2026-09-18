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

    func testNoUploadUntilEnabledAndStopKeepsCloudCopy() async throws {
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

    func testReconfigureSameWalletDoesNotCancelOptIn() async throws {
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "cloud-backup.json").path))
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

private actor MemoryCloudBackups: ICloudBackupStoring {
    private var records: [UUID: CloudWalletBackup] = [:]
    private var failing = false
    private var accountName = "first-account"
    private var holdSave = false
    private var saveGate: CheckedContinuation<Void, Never>?
    private var saveStarted: CheckedContinuation<Void, Never>?
    private(set) var saves = 0
    var count: Int { records.count }
    func setFailing(_ value: Bool) { failing = value }
    func changeAccount() { accountName = "second-account" }
    func holdNextSave() { holdSave = true }
    func waitUntilSaveIsHeld() async {
        if saveGate != nil { return }
        await withCheckedContinuation { saveStarted = $0 }
    }
    func releaseSave() { saveGate?.resume(); saveGate = nil }
    func account() async throws -> String { accountName }
    func list(network: String) async throws -> [ICloudBackupSummary] {
        records.values.filter { $0.network == network }.map {
            ICloudBackupSummary(id: $0.id, network: $0.network, savedAt: $0.savedAt)
        }
    }
    func save(_ backup: CloudWalletBackup, account: String) async throws {
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

private final class MemoryCloudKeys: ICloudBackupKeyStoring, @unchecked Sendable {
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
