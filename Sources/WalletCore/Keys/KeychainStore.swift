import Foundation
import Security

/// Security.framework Keychain-backed KeyStore: `kSecClassGenericPassword`,
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (this device only — never
/// migrated via backup), `kSecAttrSynchronizable = false` (no iCloud sync).
///
/// SPM test runners have no keychain entitlements, so the package suite cannot
/// reach this. `AppTests/KeychainAttributeTests` can: it is hosted in the app,
/// stores a secret through this type and reads the attributes back out of the
/// Keychain, so the protection class is observed rather than reviewed. What
/// that still cannot show is that iOS *honours* it when the device locks —
/// the simulator has no data protection and no Secure Enclave.
public struct KeychainStore: KeyStore {
    /// kSecAttrService namespace for all entries; the wallet ID is the account.
    public let service: String

    public init(service: String = "org.btc-swift.wallet") {
        self.service = service
    }

    public func store(_ secret: WalletSecret, for walletID: String) throws {
        var query = baseQuery(walletID: walletID)
        query[kSecValueData] = secret.serialized
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw KeyStoreError.alreadyExists(walletID: walletID) }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
    }

    public func load(walletID: String) throws -> WalletSecret {
        var query = baseQuery(walletID: walletID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw KeyStoreError.notFound(walletID: walletID) }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeyStoreError.keychain(status)
        }
        return try WalletSecret(serialized: data)
    }

    /// The `kSecAttrAccessible` value the Keychain reports for this wallet's
    /// item, without returning the secret. `AppTests/KeychainAttributeTests`
    /// asks the same question of a test item; this asks it of the real one,
    /// so the on-device security check can show the configured class rather
    /// than restate the source.
    public func protectionAttribute(walletID: String) -> (status: OSStatus, accessible: String?) {
        var query = baseQuery(walletID: walletID)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, (item as? [CFString: Any])?[kSecAttrAccessible] as? String)
    }

    /// Attempts the read and reports only its OSStatus; the bytes, if the
    /// platform hands them over, are released with this scope and never
    /// surfaced. This exists for the on-device security check, whose whole
    /// question is "was the read allowed while the device was locked" —
    /// `errSecInteractionNotAllowed` is the answer it hopes to record.
    public func readStatus(walletID: String) -> OSStatus {
        var query = baseQuery(walletID: walletID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item)
    }

    public func delete(walletID: String) throws {
        let status = SecItemDelete(baseQuery(walletID: walletID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.keychain(status)
        }
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
