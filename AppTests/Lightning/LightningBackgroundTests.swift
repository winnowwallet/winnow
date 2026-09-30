@testable import WinnowLightning
import CryptoKit
import Foundation
import LightningCore
import Security
import TestSupport
import WalletCore
import XCTest

/// The Lightning side of background chain checks (BackgroundSyncTests covers
/// the scheduler and the wallet scan they share).
@MainActor
final class LightningBackgroundTests: XCTestCase {
    func testRecoveryFileProtectionDoesNotRelaxFullJournal() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x31, count: 32)
        let fullURL = root.appending(path: "full"), backgroundURL = root.appending(path: "background")
        let full = try FileLightningJournal(directory: fullURL, key: key)
        let background = try FileLightningJournal(directory: backgroundURL, key: key, protection: .afterFirstUnlock)
        try full.store(Data("secret".utf8)); try background.store(Data("presigned".utf8))
        for (url, protection) in [(fullURL, FileProtectionType.complete),
                                  (backgroundURL, FileProtectionType.completeUntilFirstUserAuthentication)] {
            let file = url.appending(path: "journal.v1")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            // Some simulators record no Data Protection class at all; where one
            // is recorded it must be this one, and hardware must record it.
            let actual = attributes[.protectionKey] as? String
            #if targetEnvironment(simulator)
            if let actual { XCTAssertEqual(actual, protection.rawValue) }
            #else
            XCTAssertEqual(actual, protection.rawValue)
            #endif
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertFalse(try Data(contentsOf: file).contains(Data("secret".utf8)))
        }
    }

    func testForegroundModelOpensNoBackgroundMonitor() async throws {
        let model = makeModel()
        await model.scenePhaseChanged(.active)
        let completed = await model.runBackgroundSync()
        XCTAssertFalse(completed)
        XCTAssertFalse(model.backgroundRunning)
        XCTAssertNil(model.backgroundMonitor)
        await model.scenePhaseChanged(.background)
    }

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

private struct LockedStoreKeys: StoreKeyVault {
    func key(for account: String) throws -> SymmetricKey? { throw LightningError.storageFailed }
    func establishKey(for account: String) throws -> SymmetricKey { throw LightningError.storageFailed }
    func discardKey(for account: String) throws { throw LightningError.storageFailed }
}
