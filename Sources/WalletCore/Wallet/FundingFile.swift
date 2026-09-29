import Foundation
import Darwin

/// Funding reservations must reach stable storage before their signed bytes
/// can enter the channel protocol. Keep ordinary wallet writes unchanged.
enum FundingFile {
    enum WriteError: Error { case replacementDurabilityUnknown }

    static func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".funding-\(UUID().uuidString)")
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard directoryFD >= 0 else { throw posixError() }
        defer { close(directoryFD) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        let file = try FileHandle(forWritingTo: temporary)
        do {
            try file.synchronize()
            guard fcntl(file.fileDescriptor, F_FULLFSYNC) == 0 else { throw posixError() }
            try file.close()
        } catch {
            try? file.close()
            throw error
        }
        guard rename(temporary.path, destination.path) == 0 else { throw posixError() }
        // A failed directory flush is uncertain: the new record is visible,
        // but may not survive power loss. The wallet must stop further writes
        // and spending until reopening, rather than overwriting it from stale RAM.
        guard fsync(directoryFD) == 0 else { throw WriteError.replacementDurabilityUnknown }
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
