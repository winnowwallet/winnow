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

    /// A wallet created but never backup-confirmed re-enters onboarding on
    /// the next launch, with the same words: the flag is set at creation and
    /// cleared only by the backup sheet's Done (#5).
    func testAPendingBackupSurvivesAReboot() async throws {
        let environment = [
            "WINNOW_E2E": "1",
            "WINNOW_E2E_RUN": "backup-\(UUID().uuidString)",
            "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f",
            "WINNOW_E2E_PEER": "127.0.0.1:1",
            "WINNOW_E2E_CHALLENGE": "51",
        ]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { return XCTFail("could not create isolated backup fixture") }
        // What a relaunch of one installation keeps: the run's defaults
        // suite, one seal-key vault and one key store, shared by every model.
        let storeKeys = InMemoryStoreKeyVault()
        let keyStore = InMemoryKeyStore()
        func launch() -> AppModel { AppModel(e2e: mode, storeKeys: storeKeys, keyStore: keyStore) }

        let creating = launch()
        addTeardownBlock {
            await creating.scenePhaseChanged(.background)
            cleanup.wipeIfRequested()
        }
        await creating.boot()
        XCTAssertEqual(creating.stage, .onboarding)
        await creating.scenePhaseChanged(.active)
        let words = try await creating.createWallet()
        XCTAssertTrue(creating.hasPendingBackup)
        XCTAssertEqual(creating.stage, .onboarding, "creation must not skip the backup")
        await creating.scenePhaseChanged(.background)

        // Killed before Done: the next boot resumes the backup, same words.
        let rebooted = launch()
        await rebooted.boot()
        XCTAssertEqual(rebooted.stage, .onboarding)
        XCTAssertTrue(rebooted.hasPendingBackup, "the pending backup did not survive the reboot")
        let resumed = try await rebooted.pendingBackupMnemonic()
        XCTAssertEqual(resumed, words)
        rebooted.finishOnboarding()
        XCTAssertEqual(rebooted.stage, .ready)
        XCTAssertFalse(rebooted.hasPendingBackup)
        await rebooted.scenePhaseChanged(.background)

        // Done is just as durable: a further boot lands on the wallet.
        let settled = launch()
        await settled.boot()
        XCTAssertEqual(settled.stage, .ready)
        XCTAssertFalse(settled.hasPendingBackup, "a confirmed backup was asked for again")
        let none = try await settled.pendingBackupMnemonic()
        XCTAssertNil(none)
        await settled.scenePhaseChanged(.background)
    }
}
