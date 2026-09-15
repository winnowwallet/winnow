import LocalAuthentication
import Security
import WalletCore
import XCTest

/// What the Keychain actually recorded, read back (invariant S1, IR-023).
///
/// The app test host supplies the iOS entitlements a command-line SwiftPM
/// runner lacks. This suite stores through the local KeychainStore and reads
/// back the recorded attributes: the protection class, the synchronizable
/// flag, and the access control with its user-presence constraint.
///
/// **What this cannot show.** That iOS *honours* the attributes. The
/// simulator's Keychain is file-backed with no data protection and no Secure
/// Enclave: it records the user-presence constraint and then releases the
/// secret to a read that forbids interaction, and locking the device is not
/// modelled at all. The claim earned is "we ask for the right protection
/// and the Keychain records it", not "the platform enforces it" — the
/// latter is Apple's contract and needs real hardware.
final class KeychainAttributeTests: XCTestCase {
    private let service = "org.btc-swift.tests.keychain-attributes"
    private var walletID = ""
    private let secret = WalletSecret.mnemonic("abandon abandon abandon")

    /// How the Keychain describes a user-presence constraint on the decrypt
    /// operation. The description is the only public view of a
    /// `SecAccessControl`'s constraints; the wording changing would fail
    /// the positive assertion below loudly, not pass it quietly.
    private let userPresenceConstraint = "DeviceOwnerAuthentication"

    override func setUp() {
        super.setUp()
        walletID = "attributes-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? store(.deviceOnly).delete(walletID: walletID)
        super.tearDown()
    }

    private func store(_ protection: KeychainStore.Protection) -> KeychainStore {
        KeychainStore(service: service, protection: protection)
    }

    /// The attributes the Keychain reports for the secret under `walletID`.
    private func storedAttributes() throws -> [CFString: Any] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: walletID,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
            // Match whatever was stored, synchronizable or not. Without this
            // the query defaults to non-synchronizable only, and a secret
            // wrongly marked for iCloud would simply not be found — the test
            // would fail, but with "not found" rather than by observing the
            // attribute, which proves the item changed and not which way.
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        XCTAssertEqual(status, errSecSuccess, "the secret we just stored was not found")
        return try XCTUnwrap(item as? [CFString: Any], "keychain returned no attributes")
    }

    /// The recorded access control, as the Keychain describes it. Every
    /// item has one — an unconstrained one names only the protection class.
    private func recordedAccessControl() throws -> String {
        let control = try XCTUnwrap(try storedAttributes()[kSecAttrAccessControl],
                                    "no access control was recorded at all")
        return String(describing: control)
    }

    private func assertStoredAccessibleOnlyWhenUnlockedOnThisDevice(
        _ protection: KeychainStore.Protection, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let attributes = try storedAttributes()
        let accessible = try XCTUnwrap(attributes[kSecAttrAccessible] as? String,
                                       "\(protection): no accessibility attribute was recorded at all",
                                       file: file, line: line)
        XCTAssertEqual(accessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                       "\(protection): stored with \(accessible): a weaker class survives a backup "
                       + "or an unattended device, which is the whole point of the stricter one",
                       file: file, line: line)
    }

    func testStoredSecretIsAccessibleOnlyWhenUnlockedOnThisDevice() throws {
        for protection in [KeychainStore.Protection.userPresence, .deviceOnly] {
            try store(protection).store(secret, for: walletID)
            try assertStoredAccessibleOnlyWhenUnlockedOnThisDevice(protection)
            try store(protection).delete(walletID: walletID)
        }
    }

    func testStoredSecretIsNotSynchronizedToICloud() throws {
        for protection in [KeychainStore.Protection.userPresence, .deviceOnly] {
            try store(protection).store(secret, for: walletID)
            let attributes = try storedAttributes()
            // Absent counts as false — Keychain omits the attribute when it is
            // not set — so the assertion is "never true" rather than "equals
            // false".
            let synchronizable = attributes[kSecAttrSynchronizable] as? Bool ?? false
            XCTAssertFalse(synchronizable,
                           "\(protection): the secret is marked synchronizable and would leave the device")
            try store(protection).delete(walletID: walletID)
        }
    }

    /// The user-presence constraint is recorded on the item, not merely
    /// asked for, and marked so a later launch knows it is there. The
    /// device-only store is the control: an access control with no
    /// constraint, and no marker.
    func testARealWalletSecretCarriesTheUserPresenceConstraintAndAnAutomatedRunsDoesNot() throws {
        try store(.userPresence).store(secret, for: walletID)
        let constrained = try recordedAccessControl()
        XCTAssertTrue(constrained.contains(userPresenceConstraint),
                      "recorded as \(constrained): the Keychain would hand the secret to any code "
                      + "in the process without the user")
        XCTAssertEqual(try storedAttributes()[kSecAttrGeneric] as? Data, KeychainStore.protectionMarker)
        try store(.userPresence).delete(walletID: walletID)

        try store(.deviceOnly).store(secret, for: walletID)
        let unconstrained = try recordedAccessControl()
        XCTAssertFalse(unconstrained.contains(userPresenceConstraint),
                       "recorded as \(unconstrained): an automated run's secret must not need a user "
                       + "nobody can supply")
        XCTAssertNil(try storedAttributes()[kSecAttrGeneric])
    }

    /// Round trip through the store's own `load`, on the protection the
    /// simulator can satisfy. The user-presence one needs a person.
    func testAnAutomatedRunsSecretIsActuallyReadableBack() throws {
        let store = store(.deviceOnly)
        try store.store(.mnemonic("abandon abandon about"), for: walletID)
        let loaded = try store.load(walletID: walletID)
        guard case let .mnemonic(text) = loaded else {
            return XCTFail("stored a mnemonic and loaded something else")
        }
        XCTAssertEqual(text, "abandon abandon about")
    }

    /// A secret stored by 0.7.1 or earlier — the protection class alone, which
    /// is exactly what the device-only store writes — gets the constraint in
    /// place: same item, same class, same bytes. Done once; a second pass
    /// finds the marker and nothing to do.
    func testASecretFromAnEarlierVersionGetsTheUserPresenceConstraintInPlace() throws {
        try store(.deviceOnly).store(secret, for: walletID)
        XCTAssertFalse(try recordedAccessControl().contains(userPresenceConstraint),
                       "the fixture is not an earlier version's item")

        XCTAssertTrue(try store(.userPresence).upgradeProtection(walletID: walletID))
        let upgraded = try recordedAccessControl()
        XCTAssertTrue(upgraded.contains(userPresenceConstraint), "recorded as \(upgraded) after the upgrade")
        XCTAssertEqual(try storedAttributes()[kSecAttrGeneric] as? Data, KeychainStore.protectionMarker)
        try assertStoredAccessibleOnlyWhenUnlockedOnThisDevice(.userPresence)
        XCTAssertEqual(try store(.deviceOnly).load(walletID: walletID), secret,
                       "the upgrade changed the secret itself")

        XCTAssertFalse(try store(.userPresence).upgradeProtection(walletID: walletID),
                       "an item that already carries the constraint was rewritten")
        XCTAssertFalse(try store(.deviceOnly).upgradeProtection(walletID: walletID),
                       "a store with no user-presence check has nothing to upgrade to")
    }

    func testUpgradingAMissingSecretSaysSo() {
        XCTAssertThrowsError(try store(.userPresence).upgradeProtection(walletID: walletID)) { error in
            XCTAssertEqual(error as? KeyStoreError, .notFound(walletID: walletID))
        }
    }

    /// A read is never silently refused: the statuses the Keychain's own
    /// check produces have words a person can act on.
    func testTheKeychainsOwnRefusalsHavePlainWords() {
        XCTAssertEqual(KeyStoreError.keychain(errSecUserCanceled).errorDescription,
                       "Unlocking the wallet key was cancelled.")
        XCTAssertEqual(KeyStoreError.keychain(errSecAuthFailed).errorDescription,
                       "The device did not confirm it was you, so the wallet key stays locked.")
        XCTAssertEqual(KeyStoreError.keychain(errSecInteractionNotAllowed).errorDescription,
                       "The wallet key can only be unlocked while Winnow is on screen and the device is unlocked.")
        XCTAssertEqual(KeyStoreError.keychain(errSecItemNotFound).errorDescription,
                       "The device could not reach the protected wallet key (The specified item could not be found in the keychain.).")
    }
}

/// The device-owner check the app passes is handed to the Keychain read that
/// follows it, once, so the user is asked one time and not two — and never
/// less than once.
final class KeychainAuthenticationTests: XCTestCase {
    func testAGrantedCheckIsTakenOnce() {
        let authentication = KeychainAuthentication()
        XCTAssertNil(authentication.take(), "nothing was granted")
        let context = LAContext()
        authentication.grant(context)
        XCTAssertTrue(authentication.isGranted)
        XCTAssertTrue(authentication.take() === context)
        XCTAssertFalse(authentication.isGranted)
        XCTAssertNil(authentication.take(), "a second read after one check must prompt again")
    }

    func testRevokingDropsTheCheck() {
        let authentication = KeychainAuthentication()
        authentication.grant(LAContext())
        authentication.revoke()
        XCTAssertFalse(authentication.isGranted)
        XCTAssertNil(authentication.take())
    }

    func testAnExpiredCheckIsNotTaken() {
        let authentication = KeychainAuthentication()
        authentication.grant(LAContext(), lifetime: 0)
        XCTAssertFalse(authentication.isGranted)
        XCTAssertNil(authentication.take())
    }

    func testANewerCheckReplacesTheOlder() {
        let authentication = KeychainAuthentication()
        let older = LAContext()
        let newer = LAContext()
        authentication.grant(older)
        authentication.grant(newer)
        XCTAssertTrue(authentication.take() === newer)
        XCTAssertNil(authentication.take())
    }
}
