import CryptoKit
import Foundation
import LightningCore
import WalletCore

/// Reuses Winnow's authenticated recovery container, keyed by the wallet's
/// own recovery phrase. The file adds channel keys to the wallet those words
/// already restore, so there is no second phrase to keep. Files saved by
/// Winnow 0.8.0 still open with the separate 24-word phrase they were made with.
@MainActor enum PortableLightningBackup {
    static func prepare(_ contents: CloudBackupContents) throws -> Data {
        guard let words = contents.bundle.mnemonic else { throw WalletError.mnemonicUnavailable }
        let id = UUID()
        let key = try walletKey(normalized(words), id: id, network: contents.bundle.network)
        return try CloudWalletBackup.create(bundle: contents.bundle, appState: contents.appState, id: id, key: key).encoded()
    }
    /// `words` is the recovery phrase of the wallet that saved the file, or
    /// the separate phrase of a file saved by Winnow 0.8.0.
    static func restore(_ file: Data, words: String, network: BitcoinNetwork) throws -> CloudBackupContents {
        let backup = try CloudWalletBackup.decode(file)
        guard backup.network == network.rawValue else { throw WalletError.invalidBundle("Recovery file belongs to another network.") }
        let phrase = normalized(words)
        try BIP39.validate(mnemonic: phrase)
        for key in try keys(phrase, id: backup.id, network: backup.network) {
            guard let bundle = try? backup.restoredBundle(key: key) else { continue }
            let appState = try backup.restoredAppState(key: key)
            _ = try PortableLightningState.decode(appState, for: bundle)
            return CloudBackupContents(bundle: bundle, appState: appState)
        }
        throw WalletError.invalidBundle("That phrase does not open this file. Use the recovery phrase of the wallet that saved it.")
    }
    private static func keys(_ phrase: String, id: UUID, network: String) throws -> [SymmetricKey] {
        let wallet = try walletKey(phrase, id: id, network: network)
        guard phrase.split(separator: " ").count == 24 else { return [wallet] }
        return [wallet, try legacyKey(phrase, id: id, network: network)]
    }
    private static func normalized(_ words: String) -> String {
        words.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func walletKey(_ phrase: String, id: UUID, network: String) throws -> SymmetricKey {
        try derive(phrase, id: id, info: "Winnow Lightning recovery file v2 wallet phrase|\(network)")
    }
    /// Winnow 0.8.0 wrapped each file with its own random 24-word phrase.
    static func legacyKey(_ phrase: String, id: UUID, network: String) throws -> SymmetricKey {
        try derive(phrase, id: id, info: "Winnow Lightning portable recovery v1|\(network)")
    }
    private static func derive(_ phrase: String, id: UUID, info: String) throws -> SymmetricKey {
        let seed = try BIP39.seed(mnemonic: phrase)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: seed), salt: Data(id.uuidString.utf8),
            info: Data(info.utf8), outputByteCount: 32)
    }
}

/// What the recovery file carries beside the wallet bundle: the private
/// wallet context iCloud recovery carries, and the channels' recovery keys.
/// Encoded flat, as version 2 of that context, so the files earlier Winnow
/// Lightning builds exported still open.
struct PortableLightningState: Equatable {
    static let version = 2
    var context: CloudAppState
    var lightning: LightningRecoveryBackup

    @MainActor
    func validate(for bundle: ImportBundle) throws {
        try context.validate(for: bundle)
        guard let network = BitcoinNetwork(rawValue: context.network) else {
            throw WalletError.invalidBundle("cloud wallet context does not match")
        }
        _ = try LightningRecoveryBackup.decode(lightning.encoded(), chain: NetworkParams.params(for: network).genesisHash)
        guard try encoded().count <= CloudWalletBackup.maximumAppStateBytes else {
            throw WalletError.invalidBundle("Lightning recovery context is too large")
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    @MainActor
    static func decode(_ data: Data?, for bundle: ImportBundle) throws -> Self {
        guard let data else { throw WalletError.invalidBundle("This file has no Lightning recovery keys.") }
        guard data.count <= CloudWalletBackup.maximumAppStateBytes else {
            throw WalletError.invalidBundle("Lightning recovery context is too large")
        }
        let state = try JSONDecoder().decode(Self.self, from: data)
        try state.validate(for: bundle)
        return state
    }
}

extension PortableLightningState: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, lightning
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decodeIfPresent(Int.self, forKey: .version) == Self.version,
              let lightning = try container.decodeIfPresent(LightningRecoveryBackup.self, forKey: .lightning) else {
            throw WalletError.invalidBundle("This file has no Lightning recovery keys.")
        }
        // The context's own fields are iCloud's version 1 shape.
        var context = try CloudAppState(from: decoder)
        context.version = 1
        self.context = context
        self.lightning = lightning
    }

    func encode(to encoder: any Encoder) throws {
        var context = context
        context.version = Self.version
        try context.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lightning, forKey: .lightning)
    }
}
