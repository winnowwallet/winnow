@testable import WinnowApp
import Foundation
import TestSupport
import WalletCore
import XCTest

@MainActor
final class AutomaticCloudBackupTests: XCTestCase {
    private final class Authentication: DeviceAuthenticating {
        enum Denied: Error { case denied }
        var attempts = 0
        func authenticate(reason: String) async throws {
            attempts += 1
            throw Denied.denied
        }
    }

    private func fixture(auth: (any DeviceAuthenticating)? = nil, unavailable: Bool = false) async throws -> (AppModel, CloudBackupController) {
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "automatic-cloud-\(UUID())",
                           "WINNOW_E2E_PEER": "127.0.0.1:1", "WINNOW_E2E_CHALLENGE": "51",
                           "WINNOW_E2E_DEVICE_AUTH": "1",
                           "WINNOW_E2E_ENTROPY": String(repeating: "04", count: 16)]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { throw ICloudBackupError.unavailable }
        let store = MemoryCloudBackups()
        await store.setAccountUnavailable(unavailable)
        let cloud = CloudBackupController(store: store, keys: MemoryCloudKeys())
        let keys = InMemoryKeyStore()
        let model = AppModel(deviceAuthenticator: auth, e2e: mode, storeKeys: InMemoryStoreKeyVault(),
                             keyStore: keys, cloudBackups: cloud)
        let directory = try XCTUnwrap(model.storageDirectory())
        _ = try Wallet.create(network: .signet, keyStore: keys,
                              storageURL: directory.appending(path: "wallet.json"), entropy: Data(repeating: 4, count: 16))
        addTeardownBlock {
            await model.scenePhaseChanged(.background)
            cleanup.wipeIfRequested()
        }
        await model.boot()
        return (model, cloud)
    }

    func testDeclinedAuthenticationDoesNotRepeatWithinForegroundSession() async throws {
        let auth = Authentication()
        let (model, cloud) = try await fixture(auth: auth)
        await model.scenePhaseChanged(.active)
        let deadline = Date().addingTimeInterval(3)
        while cloud.message == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(auth.attempts, 1)
        XCTAssertEqual(model.stage, .ready)
        XCTAssertEqual(cloud.statusTitle, "Not backed up")
        await model.refresh()
        await model.scenePhaseChanged(.active)
        XCTAssertEqual(auth.attempts, 1)
        XCTAssertFalse(cloud.enabled)
    }

    func testUnavailableCloudLeavesExistingWalletUsableWithoutAuthenticationPrompt() async throws {
        let auth = Authentication()
        let (model, cloud) = try await fixture(auth: auth, unavailable: true)
        await model.scenePhaseChanged(.active)
        let deadline = Date().addingTimeInterval(3)
        while cloud.message == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(auth.attempts, 0)
        XCTAssertNotNil(cloud.message)
        XCTAssertEqual(cloud.statusTitle, "Not backed up")
        XCTAssertEqual(model.stage, .ready)
        XCTAssertTrue(cloud.automaticEnabled)
        let manual = try ImportBundle.decode(json: await model.exportWalletBundle(includeMnemonic: false))
        XCTAssertEqual(manual.network, "signet")
        XCTAssertNil(manual.mnemonic, "manual history export remains usable without cloud or authentication")
    }

    func testModeChangesDoNotUndoExplicitBackupOptOut() async throws {
        let auth = Authentication()
        let (model, cloud) = try await fixture(auth: auth)
        await model.setAutomaticCloudBackup(false)
        model.setAdvancedMode(true)
        model.setAdvancedMode(false)
        await model.scenePhaseChanged(.active)
        await model.refresh()
        XCTAssertFalse(cloud.automaticEnabled)
        XCTAssertEqual(auth.attempts, 0)
        XCTAssertEqual(model.stage, .ready)
    }
}
