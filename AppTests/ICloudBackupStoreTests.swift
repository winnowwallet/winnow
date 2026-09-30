@testable import WinnowApp
import CloudKit
import CryptoKit
import Foundation
import TestSupport
import WalletCore
import XCTest

/// The iCloud store's own rules, without CloudKit: what a saved record
/// carries, which fetched payloads are read, and the backup key it keeps in
/// the (simulator) Keychain. The CloudKit transfers themselves need a signed-in
/// device; see CloudKit/README.md.
final class ICloudBackupStoreTests: XCTestCase {
    private func backup() async throws -> CloudWalletBackup {
        let wallet = try Wallet.create(network: .signet, keyStore: InMemoryKeyStore(),
                                       entropy: Data(repeating: 7, count: 16), creationHeight: 100)
        let bundle = try await wallet.exportBundle(includeMnemonic: true)
        return try CloudWalletBackup.create(bundle: bundle, key: SymmetricKey(size: .bits256))
    }

    private func payload(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "icloud-store-\(UUID()).encrypted")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testARecordCarriesTheBackupUnderItsOwnID() async throws {
        let backup = try await backup()
        let file = try payload(try backup.encoded())
        let record = ICloudBackupStore.record(for: backup, payload: file)
        XCTAssertEqual(record.recordID.recordName, backup.id.uuidString)
        XCTAssertEqual(record["network"] as? String, "signet")
        XCTAssertEqual(record["savedAt"] as? Date, backup.savedAt)
        XCTAssertEqual((record["payload"] as? CKAsset)?.fileURL, file)
        let loaded = try ICloudBackupStore.backup(from: record, id: backup.id)
        XCTAssertEqual(loaded.id, backup.id)
        XCTAssertEqual(loaded.network, backup.network)
        XCTAssertEqual(loaded.savedAt, backup.savedAt)
    }

    func testAFetchedRecordIsReadOnlyWhenItIsTheRequestedBackup() async throws {
        let backup = try await backup()
        let record = ICloudBackupStore.record(for: backup, payload: try payload(try backup.encoded()))
        XCTAssertThrowsError(try ICloudBackupStore.backup(from: record, id: UUID())) {
            XCTAssertEqual($0 as? ICloudBackupError, .accountChanged)
        }
        let empty = CKRecord(recordType: "WalletBackup", recordID: CKRecord.ID(recordName: backup.id.uuidString))
        XCTAssertThrowsError(try ICloudBackupStore.backup(from: empty, id: backup.id)) {
            XCTAssertEqual($0 as? ICloudBackupError, .invalidBackup)
        }
        let garbage = ICloudBackupStore.record(for: backup, payload: try payload(Data("not a backup".utf8)))
        XCTAssertThrowsError(try ICloudBackupStore.backup(from: garbage, id: backup.id))
    }

    func testAnOversizedPayloadIsRefusedBeforeItIsRead() async throws {
        let backup = try await backup()
        let url = try payload(Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(CloudWalletBackup.maximumBytes + 1))
        try handle.close()
        let record = ICloudBackupStore.record(for: backup, payload: url)
        XCTAssertThrowsError(try ICloudBackupStore.backup(from: record, id: backup.id)) {
            XCTAssertEqual($0 as? ICloudBackupError, .invalidBackup)
        }
    }

    func testTheBackupKeyIsKeptPerBackupAndMissingKeysSaySo() throws {
        let keys = ICloudBackupKeys()
        let id = UUID(), missing = UUID(), truncated = UUID()
        addTeardownBlock {
            for account in [id, missing, truncated] {
                SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: keys.service,
                               kSecAttrAccount: account.uuidString,
                               kSecAttrSynchronizable: kSecAttrSynchronizableAny] as CFDictionary)
            }
        }
        let created = try keys.create(id)
        XCTAssertEqual(try keys.load(id).withUnsafeBytes { Data($0) }, created.withUnsafeBytes { Data($0) })
        XCTAssertThrowsError(try keys.load(missing)) { XCTAssertEqual($0 as? ICloudBackupError, .keyUnavailable) }
        let status = SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: keys.service,
                                 kSecAttrAccount: truncated.uuidString, kSecAttrSynchronizable: true,
                                 kSecValueData: Data(repeating: 1, count: 16)] as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertThrowsError(try keys.load(truncated)) { XCTAssertEqual($0 as? ICloudBackupError, .invalidBackup) }
    }
}
