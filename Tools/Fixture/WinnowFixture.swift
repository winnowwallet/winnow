import Darwin
import Foundation
import TestSupport

@main
enum WinnowFixture {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["prepare-bank"] else {
            print("usage: swift run winnow-fixture prepare-bank")
            exit(arguments == ["--help"] ? 0 : 2)
        }
        let started = Date()
        do {
            try await SignetFixture.prepareBank()
            print("SIGNET_BANK_PREPARATION_SECONDS=\(Date().timeIntervalSince(started))")
        } catch {
            FileHandle.standardError.write(Data("Fixture preparation failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
