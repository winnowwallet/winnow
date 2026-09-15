@testable import WinnowApp
import Security
import WalletCore
import XCTest

/// Opening a wallet whose secret an earlier version stored puts the
/// Keychain's user-presence check on it (IR-023): the boot path, not only
/// the store method.
@MainActor
final class KeychainProtectionUpgradeTests: XCTestCase {
    private let service = "org.btc-swift.tests.keychain-upgrade"

    func testBootUpgradesAnEarlierVersionsSecretInPlace() async throws {
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "keychain-upgrade-\(UUID().uuidString)",
                           "WINNOW_E2E_ENTROPY": String(repeating: "a1", count: 16)]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { return XCTFail("could not create an isolated upgrade fixture") }
        defer { cleanup.wipeIfRequested() }
        // What 0.7.1 wrote: the protection class alone. A real wallet's store
        // then opens it; the E2E namespace only keeps this test's item apart.
        let earlier = KeychainStore(service: service, protection: .deviceOnly)
        let current = KeychainStore(service: service, protection: .userPresence)
        let model = AppModel(deviceAuthenticator: SilentAuthenticator(), e2e: mode,
                             defaults: makeDefaults(), keyStore: current)
        let directory = try XCTUnwrap(model.storageDirectory())
        let wallet = try Wallet.create(network: .signet, keyStore: earlier,
                                       storageURL: directory.appending(path: "wallet.json"),
                                       entropy: mode.entropy)
        let walletID = await wallet.id
        defer { try? earlier.delete(walletID: walletID) }
        XCTAssertFalse(try constraint(of: walletID), "the fixture is not an earlier item")

        await model.boot()

        XCTAssertEqual(model.stage, .ready)
        XCTAssertTrue(try constraint(of: walletID),
                      "opening the wallet left its secret without the user-presence constraint")
        XCTAssertFalse(try current.upgradeProtection(walletID: walletID), "boot did not finish the upgrade")
    }

    /// Whether the recorded access control carries the user-presence
    /// constraint, read the way `KeychainAttributeTests` reads it.
    private func constraint(of walletID: String) throws -> Bool {
        let control = try XCTUnwrap(try attributes(of: walletID)[kSecAttrAccessControl])
        return String(describing: control).contains("DeviceOwnerAuthentication")
    }

    private func attributes(of walletID: String) throws -> [CFString: Any] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: walletID,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        return try XCTUnwrap(item as? [CFString: Any])
    }
}
