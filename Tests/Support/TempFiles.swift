import Foundation

/// The per-process root for scratch files, `<temporaryDirectory>/winnow-tests-<pid>`.
/// Every scratch directory below is a UUID child of it, so concurrent tests
/// never collide.
private let tempRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("winnow-tests-\(ProcessInfo.processInfo.processIdentifier)")

/// A file URL in a fresh UUID directory. The caller removes its parent
/// directory in teardown, including when the test fails.
public func tempFileURL(_ name: String) -> URL {
    let url = tempRoot
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    return url
}
