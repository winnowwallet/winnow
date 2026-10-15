import Darwin
import Foundation
import TestSupport

@main
enum WinnowFixture {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["prepare-bank"] || arguments == ["satochip-recovery"] else {
            print("usage: swift run winnow-fixture prepare-bank | satochip-recovery")
            exit(arguments == ["--help"] ? 0 : 2)
        }
        let started = Date()
        do {
            if arguments == ["satochip-recovery"] {
                return try await SatochipRecovery.run()
            }
            try await SignetFixture.prepareBank()
            print("SIGNET_BANK_PREPARATION_SECONDS=\(Date().timeIntervalSince(started))")
        } catch {
            FileHandle.standardError.write(Data("Fixture preparation failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
