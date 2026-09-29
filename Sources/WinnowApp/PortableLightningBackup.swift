import CryptoKit
import Foundation
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
        guard let state = try CloudAppState.decode(appState, for: bundle), state.lightning != nil else {
            throw WalletError.invalidBundle("Recovery file has no Lightning keys.")
        }
        return CloudBackupContents(bundle: bundle, appState: appState)
    }
    private static func wrappingKey(_ phrase: String, id: UUID, network: String) throws -> SymmetricKey {
        try BIP39.validate(mnemonic: phrase)
        guard phrase.split(whereSeparator: \.isWhitespace).count == 24 else { throw WalletError.invalidBundle("Use this file's separate 24-word recovery phrase.") }
        return try HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: BIP39.seed(mnemonic: phrase)),
            salt: Data(id.uuidString.utf8), info: Data("Winnow Lightning portable recovery v1|\(network)".utf8), outputByteCount: 32)
    }
}
