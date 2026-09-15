import Foundation
import LocalAuthentication
import Security

/// Security.framework Keychain-backed KeyStore: `kSecClassGenericPassword`,
/// this device only (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — never
/// migrated via backup), `kSecAttrSynchronizable = false` (no iCloud sync),
/// and, for a real wallet, a `kSecAttrAccessControl` of `.userPresence`: the
/// Keychain itself asks for the passcode, Face ID or Touch ID before it
/// releases the secret. The app's own device-owner check still runs first
/// (`AppModel.authenticateSensitiveAction`); the access control makes the
/// same rule hold for any code in the process, not only for the app's call
/// sites (IR-023, winnow#120).
///
/// One prompt, not two. The app hands the `LAContext` its own check
/// evaluated to `KeychainAuthentication`, and the read that follows presents
/// it through `kSecUseAuthenticationContext`, so the Keychain asks nothing
/// further. A read with no such check behind it gets the Keychain's own
/// prompt, worded by `KeychainStore.promptReason`.
///
/// A secret stored by 0.7.1 or earlier carries the protection class alone;
/// `upgradeProtection(walletID:)` adds the access control in place, without
/// reading the secret and without a prompt. The Keychain reports an access
/// control object for every item, constrained or not, so the item carries
/// `protectionMarker` in `kSecAttrGeneric` to say the user-presence
/// constraint is on it; a legacy item has no marker.
///
/// SPM test runners have no keychain entitlements, so the package suite cannot
/// reach this. `AppTests/KeychainAttributeTests` uses the app test host,
/// stores a secret through this type and reads the attributes back out of
/// the Keychain, so the protection is observed rather than reviewed. What
/// that still cannot show is that iOS *honours* it when the device locks —
/// the simulator has no data protection and no Secure Enclave.
public struct KeychainStore: KeyStore {
    /// How a stored secret is protected.
    public enum Protection: Sendable, Equatable {
        /// This device only, unlocked, and the user present: the Keychain
        /// runs its own passcode or biometric check on every read.
        case userPresence
        /// This device only, unlocked; no check by the Keychain. For
        /// automated runs on the simulator, where nobody is present to
        /// answer a prompt, and for tests that read attributes back.
        case deviceOnly
    }

    /// The service a real wallet's entries live under. E2E runs use their own.
    public static let defaultService = "org.btc-swift.wallet"

    /// What the Keychain's own prompt says when a read arrives without the
    /// app's check behind it.
    public static let promptReason = "Unlock this wallet's protected key"

    /// `kSecAttrGeneric` on an item whose access control carries the
    /// user-presence constraint. Not part of the item's identity.
    public static let protectionMarker = Data("user-presence".utf8)

    /// kSecAttrService namespace for all entries; the wallet ID is the account.
    public let service: String
    public let protection: Protection
    /// Where the app leaves the device-owner check it already passed.
    public let authentication: KeychainAuthentication

    public init(service: String = KeychainStore.defaultService,
                protection: Protection = .userPresence,
                authentication: KeychainAuthentication = KeychainAuthentication()) {
        self.service = service
        self.protection = protection
        self.authentication = authentication
    }

    public func store(_ secret: WalletSecret, for walletID: String) throws {
        var query = baseQuery(walletID: walletID)
        query[kSecValueData] = secret.serialized
        switch protection {
        case .userPresence:
            // The access control carries the protection class; the two
            // attributes are mutually exclusive in the query.
            query[kSecAttrAccessControl] = try Self.userPresenceAccessControl()
            query[kSecAttrGeneric] = Self.protectionMarker
        case .deviceOnly:
            query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw KeyStoreError.alreadyExists(walletID: walletID) }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
    }

    public func load(walletID: String) throws -> WalletSecret {
        var query = baseQuery(walletID: walletID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var context: LAContext?
        if protection == .userPresence {
            let granted = authentication.take()
            context = granted ?? Self.promptContext()
            query[kSecUseAuthenticationContext] = context
        }
        defer { context?.invalidate() }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw KeyStoreError.notFound(walletID: walletID) }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeyStoreError.keychain(status)
        }
        return try WalletSecret(serialized: data)
    }

    public func delete(walletID: String) throws {
        let status = SecItemDelete(baseQuery(walletID: walletID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.keychain(status)
        }
    }

    /// Adds the user-presence access control to a secret an earlier version
    /// stored under the protection class alone. Reads the item's attributes,
    /// never its data, so there is no prompt; an item already marked as
    /// carrying the constraint, or a store without one, is left as it is.
    /// Returns whether the item was changed. The secret is never deleted or
    /// re-added: `SecItemUpdate` rewraps it in place, and a failure leaves
    /// the only copy exactly where it was.
    @discardableResult
    public func upgradeProtection(walletID: String) throws -> Bool {
        guard protection == .userPresence else { return false }
        var query = baseQuery(walletID: walletID)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw KeyStoreError.notFound(walletID: walletID) }
        guard status == errSecSuccess, let attributes = item as? [CFString: Any] else {
            throw KeyStoreError.keychain(status)
        }
        guard attributes[kSecAttrGeneric] as? Data != Self.protectionMarker else { return false }
        let update: [CFString: Any] = [
            kSecAttrAccessControl: try Self.userPresenceAccessControl(),
            kSecAttrGeneric: Self.protectionMarker,
        ]
        let updated = SecItemUpdate(baseQuery(walletID: walletID) as CFDictionary, update as CFDictionary)
        guard updated == errSecSuccess else { throw KeyStoreError.keychain(updated) }
        return true
    }

    /// `.userPresence` over `WhenUnlockedThisDeviceOnly`: any enrolled
    /// biometry or the passcode, checked by the Keychain at read time.
    static func userPresenceAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error)
        else {
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? Int(errSecParam)
            throw KeyStoreError.keychain(OSStatus(code))
        }
        return control
    }

    /// The context a read presents when the app ran no check of its own:
    /// the Keychain shows its prompt with `promptReason`.
    private static func promptContext() -> LAContext {
        let context = LAContext()
        context.localizedReason = promptReason
        return context
    }

    private func baseQuery(walletID: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: walletID,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }
}

/// The device-owner check the app has already passed, held for the one
/// Keychain read that follows it. `grant` after `LAContext.evaluatePolicy`
/// succeeds; the next `KeychainStore.load` takes it, once, and presents it
/// to the Keychain, which then asks nothing further. Ungranted, expired,
/// revoked or already used, a read gets the Keychain's own prompt instead —
/// never the secret without a check.
public final class KeychainAuthentication: @unchecked Sendable {
    /// How long a granted check stays usable. Long enough for the operation
    /// that asked for it to build what it signs or reveals and reach its
    /// read; short enough that a check left unused does not linger.
    public static let lifetime: TimeInterval = 60

    private let lock = NSLock()
    private var context: LAContext?
    private var expires = Date.distantPast

    public init() {}

    /// Holds `context` for the next read, for `lifetime`. A check already
    /// held is invalidated: one check, one read.
    public func grant(_ context: LAContext, lifetime: TimeInterval = KeychainAuthentication.lifetime) {
        lock.withLock {
            self.context?.invalidate()
            self.context = context
            expires = Date().addingTimeInterval(lifetime)
        }
    }

    /// Drops any held check, invalidating it. The app calls this when it
    /// leaves the screen.
    public func revoke() {
        lock.withLock {
            context?.invalidate()
            context = nil
        }
    }

    /// Whether a usable check is held right now.
    public var isGranted: Bool {
        lock.withLock { context != nil && Date() < expires }
    }

    /// The held check, removed: a second read after the same check prompts.
    /// An expired check is invalidated and not returned.
    public func take() -> LAContext? {
        lock.withLock {
            defer { context = nil }
            guard let context else { return nil }
            guard Date() < expires else {
                context.invalidate()
                return nil
            }
            return context
        }
    }
}
