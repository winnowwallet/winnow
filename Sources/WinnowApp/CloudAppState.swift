import Foundation
import WalletCore

/// Private wallet context carried only inside encrypted iCloud recovery.
/// Connection settings remain device-local; a restored phone uses normal
/// discovery instead of inheriting an old phone's private-network endpoints.
struct CloudAppState: Codable, Equatable, Sendable {
    var version = 1
    let network: String
    let descriptor: String?
    var people: PeopleStore.Backup
    let receiveLabels: [String: String]
    let ownDisplayName: String
    let advancedMode: Bool

    @MainActor
    func validate(for bundle: ImportBundle) throws {
        guard version == 1, network == bundle.network, descriptor == bundle.descriptor,
              let network = BitcoinNetwork(rawValue: network),
              ownDisplayName.utf8.count <= 1024 else {
            throw WalletError.invalidBundle("cloud wallet context does not match")
        }
        try PeopleStore.validateBackup(people, network: network)
        _ = try ReceiveAddressLabelStore.validatedBackup(receiveLabels, network: network)
        guard try encoded().count <= CloudWalletBackup.maximumAppStateBytes else {
            throw WalletError.invalidBundle("cloud wallet context is too large")
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    @MainActor
    static func decode(_ data: Data?, for bundle: ImportBundle) throws -> Self? {
        guard let data else { return nil }
        guard data.count <= CloudWalletBackup.maximumAppStateBytes else {
            throw WalletError.invalidBundle("cloud wallet context is too large")
        }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate(for: bundle)
        return result
    }
}

struct CloudBackupContents: Codable, Sendable {
    var bundle: ImportBundle
    var appState: Data? = nil
}
