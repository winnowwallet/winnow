import CryptoKit
import Foundation

/// An opt-in cloud copy, separate from the device-only signing Keychain.
/// The random wrapping key travels through iCloud Keychain; the cloud file
/// contains only authenticated ciphertext. Automatic updates reuse the sealed
/// phrase without reading the local signing key again.
public struct CloudWalletBackup: Codable, Sendable {
    public static let maximumBytes = 12 * 1024 * 1024
    public let version: Int
    public let id: UUID
    public let network: String
    public let savedAt: Date
    public let sealedPhrase: Data
    public let sealedWallet: Data

    public static func create(bundle: ImportBundle, id: UUID = UUID(), key: SymmetricKey,
                              savedAt: Date = Date()) throws -> Self {
        guard let words = bundle.mnemonic else { throw WalletError.mnemonicUnavailable }
        try BIP39.validate(mnemonic: words)
        _ = try Wallet.importing(bundle, keyStore: ValidationKeys())
        let phrase = try AES.GCM.seal(Data(words.utf8), using: key,
                                     authenticating: context(id, bundle.network, "phrase")).combined!
        return try make(bundle: bundle, id: id, key: key, savedAt: savedAt, phrase: phrase)
    }

    public func updating(bundle: ImportBundle, key: SymmetricKey, savedAt: Date = Date()) throws -> Self {
        let previous = try watchOnlyBundle(key: key)
        guard bundle.network == network, bundle.descriptor == previous.descriptor else {
            throw WalletError.descriptorMismatch
        }
        return try Self.make(bundle: bundle, id: id, key: key, savedAt: savedAt, phrase: sealedPhrase)
    }

    public func restoredBundle(key: SymmetricKey) throws -> ImportBundle {
        var bundle = try watchOnlyBundle(key: key)
        let words = try AES.GCM.open(AES.GCM.SealedBox(combined: sealedPhrase), using: key,
                                     authenticating: Self.context(id, network, "phrase"))
        guard let mnemonic = String(data: words, encoding: .utf8) else {
            throw WalletError.invalidBundle("invalid cloud recovery words")
        }
        try BIP39.validate(mnemonic: mnemonic)
        bundle.mnemonic = mnemonic
        // Validate descriptor, coins, history and key agreement before the
        // caller touches the real Keychain or wallet files.
        _ = try Wallet.importing(bundle, keyStore: ValidationKeys())
        return bundle
    }

    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else {
            throw WalletError.invalidBundle("cloud backup is too large")
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw WalletError.invalidBundle("cloud backup is too large") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.version == 1, BitcoinNetwork(rawValue: result.network) != nil,
              result.sealedPhrase.count <= 1024 else {
            throw WalletError.invalidBundle("unsupported cloud backup")
        }
        return result
    }

    private func watchOnlyBundle(key: SymmetricKey) throws -> ImportBundle {
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealedWallet), using: key,
                                   authenticating: Self.context(id, network, "wallet-\(savedAt.timeIntervalSince1970)"))
        let bundle = try ImportBundle.decode(data)
        guard bundle.network == network, bundle.mnemonic == nil else {
            throw WalletError.invalidBundle("cloud backup identity does not match")
        }
        return bundle
    }

    private static func make(bundle: ImportBundle, id: UUID, key: SymmetricKey,
                             savedAt: Date, phrase: Data) throws -> Self {
        var publicBundle = bundle
        publicBundle.mnemonic = nil
        let data = Data(try publicBundle.serialized().utf8)
        _ = try ImportBundle.decode(data)
        let sealed = try AES.GCM.seal(data, using: key,
                                     authenticating: context(id, bundle.network, "wallet-\(savedAt.timeIntervalSince1970)"))
        return Self(version: 1, id: id, network: bundle.network, savedAt: savedAt,
                    sealedPhrase: phrase, sealedWallet: sealed.combined!)
    }

    private static func context(_ id: UUID, _ network: String, _ purpose: String) -> Data {
        Data("Winnow cloud backup v1|\(id.uuidString)|\(network)|\(purpose)".utf8)
    }

    /// Runs the normal importer as a validation pass without persisting keys.
    private struct ValidationKeys: KeyStore {
        func store(_ secret: WalletSecret, for walletID: String) throws {}
        func load(walletID: String) throws -> WalletSecret { throw KeyStoreError.notFound(walletID: walletID) }
        func delete(walletID: String) throws {}
    }
}
