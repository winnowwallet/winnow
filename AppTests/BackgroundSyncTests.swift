@testable import WinnowApp
import CryptoKit
import Foundation
import LightningCore
import Security
import TestSupport
import WalletCore
import XCTest

@MainActor
final class BackgroundSyncTests: XCTestCase {
    func testCompletionOccursOnceAndCancelsDeadline() async {
        let done = expectation(description: "completed")
        var completions: [Bool] = [], cancellations = 0
        let run = BackgroundSyncRun(budget: .milliseconds(20), work: { true }, cancel: { cancellations += 1 }) {
            completions.append($0); done.fulfill()
        }
        run.start(); run.start()
        await fulfillment(of: [done], timeout: 1)
        run.expire()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(completions, [true]); XCTAssertEqual(cancellations, 0)
    }
    func testExpirationDrainsWorkAndCannotReportSuccess() async {
        let done = expectation(description: "completed"), started = expectation(description: "started")
        var completions: [Bool] = [], cancellations = 0, drained = false
        let run = BackgroundSyncRun(budget: .seconds(10), work: {
            started.fulfill()
            do { try await Task.sleep(for: .seconds(10)) } catch { }
            drained = true
            return true
        }, cancel: { cancellations += 1 }) {
            XCTAssertTrue(drained); completions.append($0); done.fulfill()
        }
        run.start()
        await fulfillment(of: [started], timeout: 1)
        run.expire(); run.expire()
        await fulfillment(of: [done], timeout: 1)
        await Task.yield()
        XCTAssertEqual(completions, [false]); XCTAssertEqual(cancellations, 1)
    }
    func testDeadlineCancelsHungWork() async {
        let done = expectation(description: "deadline")
        let run = BackgroundSyncRun(budget: .milliseconds(10), work: {
            do { try await Task.sleep(for: .seconds(10)) } catch { }
            return true
        }, cancel: { }) { XCTAssertFalse($0); done.fulfill() }
        run.start()
        await fulfillment(of: [done], timeout: 1)
    }
    func testRecoveryFileProtectionDoesNotRelaxFullJournal() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x31, count: 32)
        let fullURL = root.appending(path: "full"), backgroundURL = root.appending(path: "background")
        let full = try FileLightningJournal(directory: fullURL, key: key)
        let background = try FileLightningJournal(directory: backgroundURL, key: key, protection: .afterFirstUnlock)
        try full.store(Data("secret".utf8)); try background.store(Data("presigned".utf8))
        var missingProtectionAttribute = false
        for (url, protection) in [(fullURL, FileProtectionType.complete),
                                  (backgroundURL, FileProtectionType.completeUntilFirstUserAuthentication)] {
            let file = url.appending(path: "journal.v1")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if let actual = attributes[.protectionKey] as? String {
                XCTAssertEqual(actual, protection.rawValue)
            } else {
                missingProtectionAttribute = true
            }
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertFalse(try Data(contentsOf: file).contains(Data("secret".utf8)))
        }
        #if targetEnvironment(simulator)
        if missingProtectionAttribute {
            throw XCTSkip("This simulator does not expose Data Protection attributes; locked-device checks remain required on hardware.")
        }
        #else
        XCTAssertFalse(missingProtectionAttribute)
        #endif
    }
    func testBackgroundAndForegroundCannotOwnNetworkingTogether() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let model = AppModel(e2e: nil, defaults: defaults, storeKeys: InMemoryStoreKeyVault(), keyStore: InMemoryKeyStore())
        await model.scenePhaseChanged(.active)
        let completed = await model.runBackgroundSync()
        XCTAssertFalse(completed)
        XCTAssertFalse(model.backgroundRunning)
        XCTAssertNil(model.backgroundMonitor)
        await model.scenePhaseChanged(.background)
    }
    func testBackgroundIdentifiersAreDeclaredInBuiltApplication() throws {
        let permitted = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        XCTAssertEqual(Set(permitted), Set([BackgroundSyncScheduler.refreshID, BackgroundSyncScheduler.processingID]))
        let modes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        XCTAssertTrue(Set(["fetch", "processing"]).isSubset(of: Set(modes)))
    }
}

private struct LockedStoreKeys: StoreKeyVault {
    func key(for account: String) throws -> SymmetricKey? { throw LightningError.storageFailed }
    func establishKey(for account: String) throws -> SymmetricKey { throw LightningError.storageFailed }
    func discardKey(for account: String) throws { throw LightningError.storageFailed }
}

extension BackgroundSyncTests {
    func testRecoveryAnnouncementsPersistParentChildAndSingleClaimsWithoutInventingServing() async throws {
        let pool = PeerPool(params: .regtest, peerCount: 0)
        let broadcaster = try TxBroadcaster(pool: pool)
        let parent = makeFakeSegwitTx()
        var child = makeFakeSegwitTx()
        child.inputs[0].previousOutput = .init(txid: parent.txid, vout: 0)
        let channel = Data(repeating: 1, count: 32)
        let events: [LightningEngine.Event] = [
            .broadcastClose(channelID: channel, transaction: parent.serialized(includeWitness: true)),
            .broadcastRecovery(channelID: channel, transaction: child.serialized(includeWitness: true))]
        let pending = try await announceRecoveryTransactions(events, broadcaster: broadcaster)
        XCTAssertEqual(pending, Set([parent.txid, child.txid]))
        let stored = Set(await broadcaster.pendingTxids)
        XCTAssertEqual(stored, pending)
        let served = await broadcaster.wasServed(child.txid)
        XCTAssertFalse(served, "registration alone cannot report a completed recovery relay")
        let again = try await announceRecoveryTransactions([events[1]], broadcaster: broadcaster)
        XCTAssertEqual(again, Set([child.txid]))
        do {
            _ = try await announceRecoveryTransactions([.channelReady(channel)], broadcaster: broadcaster)
            XCTFail("non-broadcast event mutated relay intentions")
        } catch LightningError.invalidState {}
        let unchanged = Set(await broadcaster.pendingTxids)
        XCTAssertEqual(unchanged, stored)
        await broadcaster.shutdown(); await pool.stop()
    }
    func testColdBackgroundMonitorNeverOpensFullJournalKey() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = InMemoryStoreKeyVault(), recoveryKeys = InMemoryStoreKeyVault()
        var foreground: LightningAppController? = LightningAppController(network: .regtest, keys: keys, backgroundKeys: recoveryKeys)
        try await foreground?.prepare(directory: root, headers: HeaderChain(params: .regtest))
        foreground = nil
        let cold = LightningAppController(network: .regtest, keys: LockedStoreKeys(), backgroundKeys: recoveryKeys)
        let monitor = try cold.prepareBackground(directory: root)
        XCTAssertNil(cold.engine, "locked wake must never instantiate the signing engine")
        await monitor.finish()
    }
    func testBackgroundRelayWaitsForPeerRequestAndFailsWhenSilent() async throws {
        for delay: Duration? in [.milliseconds(150), nil] {
            let params = NetworkParams.regtest
            let node = LoopbackNode(params: params, autoRequestDelay: delay)
            try await node.start()
            let pool = PeerPool(params: params, peerCount: 1, manualPeers: [await node.endpoint])
            await pool.start()
            let broadcaster = try TxBroadcaster(pool: pool)
            let deadline = ContinuousClock.now + .seconds(5)
            while await pool.connectedPeers().isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let tx = makeFakeSegwitTx()
            let event = LightningEngine.Event.broadcastRecovery(channelID: Data(repeating: 1, count: 32),
                                                               transaction: tx.serialized(includeWitness: true))
            do {
                try await relayBackgroundRecovery([event], broadcaster: broadcaster, timeout: .milliseconds(500))
                XCTAssertNotNil(delay, "silent peer cannot produce a successful recovery check")
                let served = await broadcaster.wasServed(tx.txid); XCTAssertTrue(served)
            } catch {
                XCTAssertNil(delay, "requesting peer should receive the recovery transaction: \(error)")
                let pending = await broadcaster.pendingTxids
                XCTAssertTrue(pending.contains(tx.txid), "retry intent must survive timeout")
            }
            await broadcaster.shutdown(); await pool.stop(); await node.stop()
        }
    }
}

extension BackgroundSyncTests {
    func testConcurrentColdBootOpensWatchOnlyWalletOnceWithoutReadingSpendingKey() async throws {
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "background-boot-\(UUID())",
                           "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f"]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, v in v })
        else { return XCTFail("fixture") }
        defer { cleanup.wipeIfRequested() }
        let model = AppModel(e2e: mode, storeKeys: InMemoryStoreKeyVault(), keyStore: UnavailableSpendingKey())
        let root = try XCTUnwrap(model.storageDirectory())
        let wallet = try Wallet.create(network: model.network, keyStore: InMemoryKeyStore(),
                                       storageURL: root.appending(path: "wallet.json"), entropy: mode.entropy)
        async let scene: Void = model.boot()
        async let wake: Void = model.boot()
        _ = await (scene, wake)
        XCTAssertEqual(model.stage, .ready)
        let id = await wallet.id
        XCTAssertEqual(model.walletID, id)
        XCTAssertNil(model.stack)
    }
}
private struct UnavailableSpendingKey: KeyStore {
    func store(_ secret: WalletSecret, for walletID: String) throws { throw KeyStoreError.notFound(walletID: walletID) }
    func load(walletID: String) throws -> WalletSecret { throw KeyStoreError.notFound(walletID: walletID) }
    func delete(walletID: String) throws { throw KeyStoreError.notFound(walletID: walletID) }
}


extension BackgroundSyncTests {
    func testForegroundAndRecoveryKeysKeepSeparateDeviceOnlyAccessibility() async throws {
        let service = "winnow-background-keys-\(UUID())"
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = LightningAppController(network: .regtest,
            keys: KeychainStoreKeyVault(service: service, protection: .whenUnlocked),
            backgroundKeys: KeychainStoreKeyVault(service: service, protection: .afterFirstUnlock))
        try await controller.prepare(directory: root, headers: HeaderChain(params: .regtest))
        for (account, expected) in [("lightning-journal-v2", kSecAttrAccessibleWhenUnlockedThisDeviceOnly),
                                    ("lightning-background-v1.regtest", kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)] {
            var result: CFTypeRef?
            let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                kSecAttrAccount: "store-key.\(account)", kSecReturnAttributes: true,
                kSecAttrSynchronizable: kSecAttrSynchronizableAny] as CFDictionary, &result)
            XCTAssertEqual(status, errSecSuccess)
            let attributes = try XCTUnwrap(result as? [String: Any])
            XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, expected as String)
            XCTAssertFalse(attributes[kSecAttrSynchronizable as String] as? Bool ?? false)
        }
    }
}
