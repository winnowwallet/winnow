import CryptoKit
import Darwin
import Foundation

/// Synchronous on purpose: a state transition cannot suspend between saving
/// channel/monitor/outbox state and making its actions visible to the caller.
public protocol LightningJournal: AnyObject {
    func load() throws -> Data?
    func store(_ snapshot: Data) throws
}

/// A single encrypted, versioned snapshot, replaced durably under an exclusive
/// process lock. The host supplies a device-protected key; no key is stored here.
/// This store detects torn/corrupt writes, not restoration of an entire older
/// wallet backup. Restored backups must remain recovery-only.
public final class FileLightningJournal: LightningJournal {
    public enum Protection { case whenUnlocked, afterFirstUnlock }
    private let directory: URL
    private let key: SymmetricKey
    private let protection: Protection
    private let lockFD: Int32
    private var failed = false
    private static let header = Data("WINNOW-SWIFT-LN\0\u{1}".utf8)
    private static let maximumBytes = 64 * 1024 * 1024

    public init(directory: URL, key: Data, protection: Protection = .whenUnlocked) throws {
        guard key.count == 32, directory.isFileURL else { throw LightningError.storageFailed }
        self.directory = directory; self.key = SymmetricKey(data: key); self.protection = protection
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw LightningError.storageFailed }
        var protected = directory
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try protected.setResourceValues(resources)
        #if os(iOS)
        if protection == .afterFirstUnlock {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: directory.path)
        }
        #endif
        let descriptor = Darwin.open(directory.appendingPathComponent("writer.lock").path,
                                     O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LightningError.storageFailed }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw LightningError.storageFailed }
        lockFD = descriptor
    }
    deinit { Darwin.close(lockFD) }

    public func load() throws -> Data? {
        guard !failed else { throw LightningError.storageFailed }
        do { return try readSnapshot() } catch { failed = true; throw LightningError.storageFailed }
    }
    private func readSnapshot() throws -> Data? {
        let file = directory.appendingPathComponent("journal.v1")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard attributes.isSymbolicLink != true, attributes.isRegularFile == true,
              let size = attributes.fileSize, size <= Self.maximumBytes else { throw LightningError.storageFailed }
        let bytes = try Data(contentsOf: file)
        guard bytes.starts(with: Self.header) else { throw LightningError.storageFailed }
        let box = try AES.GCM.SealedBox(combined: bytes.dropFirst(Self.header.count))
        return try AES.GCM.open(box, using: key, authenticating: Self.header)
    }
    public func store(_ snapshot: Data) throws {
        guard !failed, snapshot.count < Self.maximumBytes - 1024 else { throw LightningError.storageFailed }
        do {
            let box = try AES.GCM.seal(snapshot, using: key, authenticating: Self.header)
            guard let combined = box.combined else { throw LightningError.storageFailed }
            try replace(Self.header + combined)
        } catch { failed = true; throw LightningError.storageFailed }
    }
    private func replace(_ bytes: Data) throws {
        let temporary = directory.appendingPathComponent(".journal-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw LightningError.storageFailed }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: protection == .whenUnlocked
            ? FileProtectionType.complete : FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: temporary.path)
        #endif
        try writeAll(bytes, descriptor: descriptor)
        guard fsync(descriptor) == 0, fcntl(descriptor, F_FULLFSYNC) == 0 else { throw LightningError.storageFailed }
        let target = directory.appendingPathComponent("journal.v1")
        guard rename(temporary.path, target.path) == 0 else { throw LightningError.storageFailed }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw LightningError.storageFailed }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw LightningError.storageFailed }
    }
    private func writeAll(_ bytes: Data, descriptor: Int32) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { throw LightningError.storageFailed }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, start.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LightningError.storageFailed }
                written += count
            }
        }
    }
}
