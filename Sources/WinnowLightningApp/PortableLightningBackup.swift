import CryptoKit
import Foundation
import LightningCore
import WalletCore

/// Reuses Winnow's authenticated recovery container. A separate random
/// 24-word phrase unwraps the file without an Apple Account or device key.
@MainActor enum PortableLightningBackup {
    struct Prepared {
        let file: Data
        let phrase: String
    }
    static func prepare(_ contents: CloudBackupContents) throws -> Prepared {
        let entropy = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let phrase = try BIP39.mnemonic(entropy: entropy), id = UUID()
        let key = try wrappingKey(phrase, id: id, network: contents.bundle.network)
        let backup = try CloudWalletBackup.create(bundle: contents.bundle, appState: contents.appState, id: id, key: key)
        return try Prepared(file: backup.encoded(), phrase: phrase)
    }
    static func restore(_ file: Data, phrase: String, network: BitcoinNetwork) throws -> CloudBackupContents {
        let backup = try CloudWalletBackup.decode(file)
        guard backup.network == network.rawValue else { throw WalletError.invalidBundle("Recovery file belongs to another network.") }
        let key = try wrappingKey(phrase, id: backup.id, network: backup.network)
        let bundle = try backup.restoredBundle(key: key), appState = try backup.restoredAppState(key: key)
        _ = try PortableLightningState.decode(appState, for: bundle)
        return CloudBackupContents(bundle: bundle, appState: appState)
    }
    private static func wrappingKey(_ phrase: String, id: UUID, network: String) throws -> SymmetricKey {
        try BIP39.validate(mnemonic: phrase)
        guard phrase.split(whereSeparator: \.isWhitespace).count == 24 else { throw WalletError.invalidBundle("Use this file's separate 24-word recovery phrase.") }
        return try HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: BIP39.seed(mnemonic: phrase)),
            salt: Data(id.uuidString.utf8), info: Data("Winnow Lightning portable recovery v1|\(network)".utf8), outputByteCount: 32)
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
