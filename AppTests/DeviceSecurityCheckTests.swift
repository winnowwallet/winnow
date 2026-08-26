@testable import WinnowApp
import Security
import WalletCore
import XCTest

/// The on-device security check, minus the device (invariant S1's hardware
/// half). What a simulator can evidence here is the pure verdict logic and
/// both probe primitives against a real (file-backed) Keychain: the
/// attribute read reports the configured class without the secret, and the
/// status-only read succeeds while "unlocked" — the control that makes a
/// locked refusal on hardware mean something. The locked refusal itself
/// still needs the phone; that is the check's whole reason to exist.
final class DeviceSecurityCheckTests: XCTestCase {
    private let service = "org.btc-swift.tests.device-security-check"
    private var walletID = ""

    override func setUp() {
        super.setUp()
        walletID = "security-check-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? KeychainStore(service: service).delete(walletID: walletID)
        super.tearDown()
    }

    private func sample(_ seconds: Double, locked: Bool, status: OSStatus)
        -> DeviceSecurityCheck.Sample {
        DeviceSecurityCheck.Sample(secondsAfterStart: seconds,
                                   protectedDataAvailable: !locked, status: status)
    }

    // MARK: - Verdict rules

    func testAllLockedRefusalsIsEnforced() {
        let samples = [sample(5, locked: false, status: errSecSuccess),
                       sample(10, locked: true, status: errSecInteractionNotAllowed),
                       sample(15, locked: true, status: errSecInteractionNotAllowed)]
        XCTAssertEqual(DeviceSecurityCheck.verdict(for: samples), .enforced)
    }

    func testALockedSuccessIsNotEnforced() {
        let samples = [sample(5, locked: true, status: errSecInteractionNotAllowed),
                       sample(10, locked: true, status: errSecSuccess)]
        XCTAssertEqual(DeviceSecurityCheck.verdict(for: samples), .notEnforced)
    }

    func testNoLockedSamplesMeansTheDeviceNeverLocked() {
        let samples = [sample(5, locked: false, status: errSecSuccess),
                       sample(10, locked: false, status: errSecSuccess)]
        XCTAssertEqual(DeviceSecurityCheck.verdict(for: samples), .deviceNeverLocked)
        XCTAssertEqual(DeviceSecurityCheck.verdict(for: []), .deviceNeverLocked)
    }

    /// The lock-edge notification contributes a sample at whatever moment
    /// the lock landed — fractional, off the 5-second grid. The verdict
    /// rules must treat it exactly like a scheduled one.
    func testANotificationSampleOffTheGridCountsLikeAnyOther() {
        let enforced = [sample(2.3, locked: true, status: errSecInteractionNotAllowed),
                        sample(5, locked: false, status: errSecSuccess)]
        XCTAssertEqual(DeviceSecurityCheck.verdict(for: enforced), .enforced)
        let leaked = [sample(2.3, locked: true, status: errSecSuccess),
                      sample(5, locked: true, status: errSecInteractionNotAllowed)]
        XCTAssertEqual(DeviceSecurityCheck.verdict(for: leaked), .notEnforced)
    }

    func testAnUnexpectedLockedStatusIsSurfacedNotSwallowed() {
        let samples = [sample(5, locked: true, status: errSecInteractionNotAllowed),
                       sample(10, locked: true, status: errSecItemNotFound)]
        XCTAssertEqual(DeviceSecurityCheck.verdict(for: samples),
                       .unexpected(errSecItemNotFound))
    }

    // MARK: - Probe primitives against the Keychain

    func testProtectionAttributeReportsTheConfiguredClassWithoutTheSecret() throws {
        let store = KeychainStore(service: service)
        try store.store(.mnemonic("abandon abandon abandon"), for: walletID)
        let attribute = store.protectionAttribute(walletID: walletID)
        XCTAssertEqual(attribute.status, errSecSuccess)
        XCTAssertEqual(attribute.accessible,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    func testReadStatusIsAllowedWhileUnlockedAndNotFoundWithoutAnItem() throws {
        let store = KeychainStore(service: service)
        XCTAssertEqual(store.readStatus(walletID: walletID), errSecItemNotFound)
        try store.store(.mnemonic("abandon abandon abandon"), for: walletID)
        XCTAssertEqual(store.readStatus(walletID: walletID), errSecSuccess)
    }
}
