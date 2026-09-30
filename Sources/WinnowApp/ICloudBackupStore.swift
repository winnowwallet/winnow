import CloudKit
import CryptoKit
import Foundation
import Security
import WalletCore

struct ICloudBackupSummary: Identifiable, Sendable {
    let id: UUID
    let network: String
    let savedAt: Date
}

protocol ICloudBackupStoring: Sendable {
    func account() async throws -> String
    func list(network: String) async throws -> [ICloudBackupSummary]
    func save(_ backup: CloudWalletBackup, account: String) async throws
    func load(_ id: UUID, account: String) async throws -> CloudWalletBackup
}

protocol ICloudBackupKeyStoring: Sendable {
    func load(_ id: UUID) throws -> SymmetricKey
    func create(_ id: UUID) throws -> SymmetricKey
}

enum ICloudBackupError: LocalizedError {
    case unavailable, keyUnavailable, accountChanged, invalidBackup, unsupportedWallet

    var errorDescription: String? {
        switch self {
        case .unavailable: "Sign in to iCloud and enable iCloud Drive and Passwords & Keychain in Settings."
        case .keyUnavailable: "The backup key hasn’t arrived from iCloud Keychain. Check Passwords & Keychain in Settings and try again. Keep your recovery words and manual backup."
        case .accountChanged: "Your Apple Account changed. Sign back into the original account, or turn automatic backup off and on in Advanced to use this account."
        case .unsupportedWallet: "Automatic iCloud recovery requires this wallet’s recovery words. This wallet needs a manual backup instead."
        case .invalidBackup: "This iCloud backup could not be read safely. Your existing wallet was not replaced."
        }
    }
}

/// Kept separate from KeychainStore: automatic cloud recovery must never
/// change the local signing key's ThisDeviceOnly/userPresence protection.
struct ICloudBackupKeys: ICloudBackupKeyStoring {
    let service = "com.btcswift.app.cloud-backup-key.v1"

    func load(_ id: UUID) throws -> SymmetricKey {
        var query = query(id)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { throw ICloudBackupError.keyUnavailable }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        guard let data = item as? Data, data.count == 32 else { throw ICloudBackupError.invalidBackup }
        return SymmetricKey(data: data)
    }

    func create(_ id: UUID) throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        var query = query(id)
        query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        query[kSecValueData] = key.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
        return key
    }

    private func query(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: id.uuidString, kSecAttrSynchronizable: true]
    }
}

/// One independent record per device's backup, so another device or a new
/// wallet cannot overwrite the only usable backup. No public database access.
actor ICloudBackupStore: ICloudBackupStoring {
    static let containerIdentifier = "iCloud.com.btcswift.app"
    private var container: CKContainer { CKContainer(identifier: Self.containerIdentifier) }

    func account() async throws -> String {
        guard try await container.accountStatus() == .available else { throw ICloudBackupError.unavailable }
        return try await container.userRecordID().recordName
    }

    func list(network: String) async throws -> [ICloudBackupSummary] {
        _ = try await account()
        let query = CKQuery(recordType: "WalletBackup", predicate: NSPredicate(format: "network == %@", network))
        query.sortDescriptors = [NSSortDescriptor(key: "savedAt", ascending: false)]
        var page = try await container.privateCloudDatabase.records(matching: query,
            desiredKeys: ["network", "savedAt"], resultsLimit: 100)
        var records = page.matchResults
        while let cursor = page.queryCursor, records.count < 500 {
            try Task.checkCancellation()
            page = try await container.privateCloudDatabase.records(continuingMatchFrom: cursor,
                desiredKeys: ["network", "savedAt"], resultsLimit: 100)
            records.append(contentsOf: page.matchResults)
        }
        return try records.compactMap { _, result in
            let record = try result.get()
            guard record["network"] as? String == network,
                  let id = UUID(uuidString: record.recordID.recordName),
                  let date = record["savedAt"] as? Date else { return nil }
            return ICloudBackupSummary(id: id, network: network, savedAt: date)
        }.sorted { $0.savedAt > $1.savedAt }
    }

    func save(_ backup: CloudWalletBackup, account expectedAccount: String) async throws {
        try await requireAccount(expectedAccount)
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-backup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "backup.encrypted")
        try backup.encoded().write(to: file, options: [.atomic, .completeFileProtection])
        let record = Self.record(for: backup, payload: file)
        let result = try await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [],
            savePolicy: .changedKeys, atomically: true)
        guard let saved = result.saveResults[record.recordID] else { throw ICloudBackupError.invalidBackup }
        _ = try saved.get()
        try await requireAccount(expectedAccount)
    }

    func load(_ id: UUID, account expectedAccount: String) async throws -> CloudWalletBackup {
        try await requireAccount(expectedAccount)
        let record = try await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: id.uuidString))
        let backup = try Self.backup(from: record, id: id)
        try await requireAccount(expectedAccount)
        return backup
    }

    /// Before and after every transfer: a backup is never saved to, or read
    /// from, an Apple Account other than the one it was made for.
    private func requireAccount(_ expected: String) async throws {
        guard try await account() == expected else { throw ICloudBackupError.accountChanged }
    }

    static func record(for backup: CloudWalletBackup, payload: URL) -> CKRecord {
        let record = CKRecord(recordType: "WalletBackup", recordID: CKRecord.ID(recordName: backup.id.uuidString))
        record["network"] = backup.network
        record["savedAt"] = backup.savedAt
        record["payload"] = CKAsset(fileURL: payload)
        return record
    }

    /// A fetched record's payload, read only within the size bound and only
    /// when it is the backup that was asked for.
    static func backup(from record: CKRecord, id: UUID) throws -> CloudWalletBackup {
        guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else {
            throw ICloudBackupError.invalidBackup
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= CloudWalletBackup.maximumBytes else { throw ICloudBackupError.invalidBackup }
        let backup = try CloudWalletBackup.decode(Data(contentsOf: url))
        guard backup.id == id else { throw ICloudBackupError.accountChanged }
        return backup
    }
}
