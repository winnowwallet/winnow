import CryptoKit
import Foundation
import Observation
import WalletCore

@MainActor
@Observable
final class CloudBackupController {
    private struct Configuration: Codable {
        let walletID: String
        var account: String?
        var backup: CloudWalletBackup
        var digest: Data
        var pendingUpload: Bool?
    }

    private let store: any ICloudBackupStoring
    private let keys: any ICloudBackupKeyStoring
    private var configuration: Configuration?
    private var configurationURL: URL?
    private var configuredWalletID: String?
    private var preferenceURL: URL?
    private var disabledWallets: Set<String> = []
    private(set) var automaticEnabled = true
    private(set) var retryAfter = Date.distantPast
    private var failureCount = 0
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var busy = false
    private(set) var message: String?
    private(set) var available: [ICloudBackupSummary] = []
    var enabled: Bool { configuration != nil }
    var needsPreparation: Bool { automaticEnabled && configuration == nil }
    var statusTitle: String {
        if !automaticEnabled || message != nil { return "Not backed up" }
        if busy || configuration?.pendingUpload == true { return "Backing up" }
        return lastSaved == nil ? "Not backed up" : "Backed up"
    }
    var lastSaved: Date? {
        guard let configuration, configuration.pendingUpload != true else { return nil }
        return configuration.backup.savedAt
    }

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
        failureCount = 0
        retryAfter = .distantPast
        preferenceURL = directory?.appending(path: "cloud-backup-preferences.json")
        disabledWallets = []
        automaticEnabled = true
        if let preferenceURL, FileManager.default.fileExists(atPath: preferenceURL.path) {
            do { disabledWallets = Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: preferenceURL))) }
            catch {
                automaticEnabled = false
                message = "Backup preferences couldn’t be read. Review automatic backup in Advanced settings."
                return
            }
        }
        automaticEnabled = !disabledWallets.contains(walletID ?? "")
        guard automaticEnabled, let url, let walletID, FileManager.default.fileExists(atPath: url.path) else { return }
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

    /// Compatibility entry point for an explicit retry in Advanced settings.
    func enable(bundle: ImportBundle, appState: Data? = nil, walletID: String) async throws {
        try setAutomatic(true)
        let contents = CloudBackupContents(bundle: bundle, appState: appState)
        try prepare(contents: contents, walletID: walletID)
        try await updateContents { contents }
    }

    func setAutomatic(_ enabled: Bool) throws {
        guard let walletID = configuredWalletID, let preferenceURL else { throw ICloudBackupError.unavailable }
        var updated = disabledWallets
        if enabled { updated.remove(walletID) } else { updated.insert(walletID) }
        try JSONEncoder().encode(updated.sorted()).write(to: preferenceURL, options: [.atomic, .completeFileProtection])
        disabledWallets = updated
        automaticEnabled = enabled
        suspend()
        retryAfter = .distantPast
        failureCount = 0
        message = enabled ? nil : "Automatic backup is off. Existing iCloud copies remain available."
        if !enabled {
            configuration = nil
            if let configurationURL, FileManager.default.fileExists(atPath: configurationURL.path) {
                try FileManager.default.removeItem(at: configurationURL)
            }
        }
    }

    func accountForPreparation() async throws -> String { try await store.account() }

    func reportPreparationFailure(_ error: any Error) {
        message = "Not backed up: \(error.localizedDescription)"
    }

    /// Runs unless explicitly disabled. No secret read or authentication prompt during
    /// an automatic update; the initial encrypted phrase is carried forward.
    func schedule(export: @escaping @MainActor () async throws -> CloudBackupContents) {
        guard automaticEnabled, configuration != nil, task == nil, !busy, Date() >= retryAfter else { return }
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
                self.failureCount += 1
                self.retryAfter = Date().addingTimeInterval(min(300, 30 * pow(2, Double(min(self.failureCount, 4)))))
            }
            guard let self, self.generation == token else { return }
            self.task = nil
        }
    }

    private func update(token: UUID, export: @MainActor () async throws -> CloudBackupContents) async throws {
        guard automaticEnabled, var saved = configuration, let url = configurationURL else { return }
        let contents = try await export()
        try check(token)
        let digest = try Self.digest(contents)
        guard digest != saved.digest || saved.pendingUpload == true else { message = nil; return }
        busy = true
        defer { if generation == token { busy = false } }
        let key = try keys.load(saved.backup.id)
        let backup = try saved.backup.updating(bundle: contents.bundle, appState: contents.appState, key: key)
        if saved.account == nil {
            saved.account = try await store.account()
            try check(token)
            try persist(saved, to: url)
            configuration = saved
        }
        guard let account = saved.account else { throw ICloudBackupError.unavailable }
        try await store.save(backup, account: account)
        try check(token)
        saved.backup = backup
        saved.digest = digest
        saved.pendingUpload = false
        try persist(saved, to: url)
        configuration = saved
        failureCount = 0
        retryAfter = .distantPast
        message = nil
    }

    func update(export: @MainActor () async throws -> ImportBundle) async throws {
        try await update(token: generation) { CloudBackupContents(bundle: try await export()) }
    }

    func updateContents(export: @MainActor () async throws -> CloudBackupContents) async throws {
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
    struct Restoration {
        let contents: CloudBackupContents
        let account: String
    }

    func restore(_ id: UUID) async throws -> ImportBundle {
        try await restoreContents(id).contents.bundle
    }

    func restoreContents(_ id: UUID) async throws -> Restoration {
        let token = generation
        let account = try await store.account()
        let backup = try await store.load(id, account: account)
        try check(token)
        let key = try keys.load(id)
        return try Restoration(contents: CloudBackupContents(bundle: backup.restoredBundle(key: key),
                                                             appState: backup.restoredAppState(key: key)),
                               account: account)
    }

    /// A replacement device gets its own record. Persist the encrypted retry
    /// state before upload so an outage does not silently turn backups off.
    func resume(contents: CloudBackupContents, walletID: String, account: String) throws {
        try prepare(contents: contents, walletID: walletID, account: account)
    }

    func prepare(contents: CloudBackupContents, walletID: String, account: String? = nil) throws {
        guard automaticEnabled else { return }
        guard !busy, let configurationURL, configuredWalletID == walletID else { throw ICloudBackupError.unavailable }
        let id = UUID()
        let key = try keys.create(id)
        let backup = try CloudWalletBackup.create(bundle: contents.bundle, appState: contents.appState, id: id, key: key)
        let saved = Configuration(walletID: walletID, account: account, backup: backup,
                                  digest: try Self.digest(contents), pendingUpload: true)
        try persist(saved, to: configurationURL)
        configuration = saved
        message = nil
    }

    func reportResumeFailure(_ error: any Error) {
        message = "Wallet restored. Automatic backup needs attention: \(error.localizedDescription)"
    }

    func stop() throws { try setAutomatic(false) }

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

    private static func digest(_ contents: CloudBackupContents) throws -> Data {
        var publicContents = contents
        publicContents.bundle.mnemonic = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(publicContents)))
    }
}
