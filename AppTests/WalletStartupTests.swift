@testable import WinnowApp
import WalletCore
import TestSupport
import XCTest

@MainActor
final class WalletStartupTests: XCTestCase {
    func testPersistedWalletGetsFiltersWhetherActivationPrecedesOrFollowsBoot() async throws {
        let environment = [
            "WINNOW_E2E": "1",
            "WINNOW_E2E_RUN": "startup-\(UUID().uuidString)",
            "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f",
            "WINNOW_E2E_PEER": "127.0.0.1:1",
            "WINNOW_E2E_CHALLENGE": "51",
        ]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { return XCTFail("could not create isolated startup fixture") }
        defer { cleanup.wipeIfRequested() }

        let early = AppModel(e2e: mode)
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: mode.storageDirectoryName).appending(path: "signet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try Wallet.create(network: .signet, keyStore: early.keyStore,
                              storageURL: directory.appending(path: "wallet.json"), entropy: mode.entropy)

        // SwiftUI can deliver .active while boot is still opening the wallet.
        await early.scenePhaseChanged(.active)
        await early.boot()
        XCTAssertEqual(early.stage, .ready)
        XCTAssertNotNil(early.stack?.filters, "early activation must not strand a wallet without filters")
        await early.scenePhaseChanged(.background)

        let late = AppModel(e2e: mode)
        await late.boot()
        XCTAssertEqual(late.stage, .ready)
        XCTAssertNil(late.stack, "inactive boot must not start networking")
        await late.scenePhaseChanged(.active)
        XCTAssertNotNil(late.stack?.filters, "activation after boot must attach the saved wallet's filters")
        await late.scenePhaseChanged(.background)
    }

    /// Each network keeps its own wallet: switching opens the other network's
    /// (here none, so onboarding), a damaged file there says so, and switching
    /// back reopens the first wallet unchanged.
    func testSwitchingNetworksOpensEachNetworksOwnWallet() async throws {
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "switch-\(UUID().uuidString)",
                           "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f",
                           "WINNOW_E2E_PEER": "127.0.0.1:1", "WINNOW_E2E_CHALLENGE": "51"]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { return XCTFail("could not create isolated network fixture") }
        defer { cleanup.wipeIfRequested() }
        let model = AppModel(e2e: mode, storeKeys: InMemoryStoreKeyVault(), keyStore: InMemoryKeyStore())
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appending(path: mode.storageDirectoryName)
        try FileManager.default.createDirectory(at: root.appending(path: "signet"), withIntermediateDirectories: true)
        _ = try Wallet.create(network: .signet, keyStore: model.keyStore,
                              storageURL: root.appending(path: "signet/wallet.json"), entropy: mode.entropy)
        await model.boot()
        XCTAssertEqual(model.network, .signet)
        XCTAssertEqual(model.stage, .ready)
        let signetWallet = try XCTUnwrap(model.walletID)

        await model.switchNetwork(to: .signet)
        XCTAssertEqual(model.walletID, signetWallet, "switching to the current network changes nothing")

        await model.switchNetwork(to: .mainnet)
        XCTAssertEqual(model.network, .mainnet)
        XCTAssertEqual(model.stage, .onboarding, "mainnet has no wallet of its own yet")
        XCTAssertNil(model.walletID)

        await model.switchNetwork(to: .signet)
        XCTAssertEqual(model.stage, .ready)
        XCTAssertEqual(model.walletID, signetWallet)

        try FileManager.default.createDirectory(at: root.appending(path: "mainnet"), withIntermediateDirectories: true)
        try Data("not a wallet".utf8).write(to: root.appending(path: "mainnet/wallet.json"))
        await model.switchNetwork(to: .mainnet)
        guard case .storageDamaged = model.stage else { return XCTFail("a damaged file must stop, not onboard over it") }
    }

    func testNewAndLegacyUnfinishedWalletsOpenWithoutPhraseChecklist() async throws {
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "backup-\(UUID().uuidString)",
                           "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f",
                           "WINNOW_E2E_PEER": "127.0.0.1:1", "WINNOW_E2E_CHALLENGE": "51"]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { return XCTFail("could not create isolated backup fixture") }
        let storeKeys = InMemoryStoreKeyVault()
        let keyStore = InMemoryKeyStore()
        let cloud = MemoryCloudBackups()
        await cloud.setFailing(true)
        let controller = CloudBackupController(store: cloud, keys: MemoryCloudKeys())
        let creating = AppModel(e2e: mode, storeKeys: storeKeys, keyStore: keyStore, cloudBackups: controller)
        defer { cleanup.wipeIfRequested() }
        await creating.boot()
        await creating.scenePhaseChanged(.active)
        try await creating.createWallet()
        XCTAssertEqual(creating.stage, .ready, "creation must not require a phrase or cloud acknowledgement")
        XCTAssertTrue(controller.enabled, "creation should prepare automatic backup without an Enable action")
        XCTAssertNil(controller.lastSaved, "local ciphertext is not cloud acknowledgement")
        let walletID = try XCTUnwrap(creating.walletID)
        let originalWords = try keyStore.load(walletID: walletID)
        mode.defaults.set(true, forKey: "backupPending.\(walletID)")
        let rebooted = AppModel(e2e: mode, storeKeys: storeKeys, keyStore: keyStore)
        await rebooted.boot()
        XCTAssertEqual(rebooted.stage, .ready)
        XCTAssertFalse(mode.defaults.bool(forKey: "backupPending.\(walletID)"))
        XCTAssertEqual(try keyStore.load(walletID: walletID).serialized, originalWords.serialized)
        await creating.scenePhaseChanged(.background)
        await rebooted.scenePhaseChanged(.background)
    }
}
