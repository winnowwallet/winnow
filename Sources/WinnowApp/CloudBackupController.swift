import CryptoKit
import Foundation
import Observation
import WalletCore

@MainActor
@Observable
final class CloudBackupController {
    private struct Configuration: Codable {
        let walletID: String
        let account: String
        var backup: CloudWalletBackup
        var digest: Data
    }

    private let store: any ICloudBackupStoring
    private let keys: any ICloudBackupKeyStoring
    private var configuration: Configuration?
    private var configurationURL: URL?
    private var configuredWalletID: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var busy = false
    private(set) var message: String?
    private(set) var available: [ICloudBackupSummary] = []
    var enabled: Bool { configuration != nil }
    var lastSaved: Date? { configuration?.backup.savedAt }

    init(store: any ICloudBackupStoring = ICloudBackupStore(),
         keys: any ICloudBackupKeyStoring = ICloudBackupKeys()) {
        self.store = store
        self.keys = keys
    }

    func configure(directory: URL?, walletID: String?) {
        let url = directory?.appending(path: "cloud-backup.json")
        guard url != configurationURL || walletID != configuredWalletID else { return }
        suspend()
        configurationURL = url
        configuredWalletID = walletID
        configuration = nil
        message = nil
        guard let url, let walletID, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= CloudWalletBackup.maximumBytes + 4096 else { throw ICloudBackupError.invalidBackup }
            let saved = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
            guard saved.walletID == walletID else { return }
            configuration = saved
        } catch {
            message = "Automatic backup settings couldn’t be read. Your previous iCloud backup is unchanged."
        }
    }

    func enable(bundle: ImportBundle, walletID: String) async throws {
        guard !busy, let configurationURL else { throw ICloudBackupError.unavailable }
        let token = generation
        busy = true
        defer { if generation == token { busy = false } }
        let account = try await store.account()
        try check(token)
        let id = UUID()
        let key = try keys.create(id)
        let backup = try CloudWalletBackup.create(bundle: bundle, id: id, key: key)
        try await store.save(backup, account: account)
        try check(token)
        let saved = Configuration(walletID: walletID, account: account, backup: backup,
                                  digest: try Self.digest(bundle))
        try persist(saved, to: configurationURL)
        configuration = saved
        message = nil
    }

    /// Only runs after opt-in. No secret read or authentication prompt during
    /// an automatic update; the initial encrypted phrase is carried forward.
    func schedule(export: @escaping @MainActor () async throws -> ImportBundle) {
        guard configuration != nil, task == nil, !busy else { return }
        let token = generation
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
                guard let self else { return }
                try await self.update(token: token, export: export)
            } catch is CancellationError {
                // A closed presentation, backgrounded app or wallet switch.
            } catch {
                guard let self, self.generation == token else { return }
                self.message = "Backup needs attention: \(error.localizedDescription)"
            }
            guard let self, self.generation == token else { return }
            self.task = nil
        }
    }

    private func update(token: UUID, export: @MainActor () async throws -> ImportBundle) async throws {
        guard var saved = configuration, let url = configurationURL else { return }
        let bundle = try await export()
        try check(token)
        let digest = try Self.digest(bundle)
        guard digest != saved.digest else { message = nil; return }
        busy = true
        defer { if generation == token { busy = false } }
        let key = try keys.load(saved.backup.id)
        let backup = try saved.backup.updating(bundle: bundle, key: key)
        try await store.save(backup, account: saved.account)
        try check(token)
        saved.backup = backup
        saved.digest = digest
        try persist(saved, to: url)
        configuration = saved
        message = nil
    }

    func update(export: @MainActor () async throws -> ImportBundle) async throws {
        try await update(token: generation, export: export)
    }

    func discover(network: String) async {
        guard !busy else { return }
        busy = true
        message = nil
        available = []
        let token = generation
        defer { if generation == token { busy = false } }
        do {
            let found = try await store.list(network: network)
            try check(token)
            available = found
        } catch is CancellationError {
        } catch {
            guard generation == token else { return }
            message = error.localizedDescription
        }
    }

    /// Caller must authenticate before downloading/decrypting a signing key.
    func restore(_ id: UUID) async throws -> ImportBundle {
        let token = generation
        let account = try await store.account()
        let backup = try await store.load(id, account: account)
        try check(token)
        let key = try keys.load(id)
        return try backup.restoredBundle(key: key)
    }

    func stop() throws {
        suspend()
        if let configurationURL, FileManager.default.fileExists(atPath: configurationURL.path) {
            try FileManager.default.removeItem(at: configurationURL)
        }
        configuration = nil
        message = "Automatic updates are off. Your saved iCloud backup remains available to restore."
    }

    func suspend() {
        generation = UUID()
        task?.cancel()
        task = nil
        busy = false
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func persist(_ saved: Configuration, to url: URL) throws {
        // Parent is the existing backup-excluded application-support folder.
        // Only encrypted wallet material is persisted here.
        try JSONEncoder().encode(saved).write(to: url, options: [.atomic, .completeFileProtection])
    }

    private static func digest(_ bundle: ImportBundle) throws -> Data {
        var publicBundle = bundle
        publicBundle.mnemonic = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(publicBundle)))
    }
}
