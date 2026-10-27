import Foundation

/// A signer a phone knows, as the app keeps it under Settings → Signers and
/// as a backup carries it: a Ledger the phone paired, or keys other people
/// sent. Public keys only: nothing here can spend, so the list is not a
/// wallet's and survives deleting one, and a restore merges it with the
/// phone's own rather than replacing it. One list per network, since a key
/// expression is for one. Exercised by `ImportBundleTests` and
/// AppTests/SignerRosterTests.
public struct SignerRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A Ledger paired over Bluetooth: its one key, at its BIP87 path.
        case ledger
        /// Keys someone sent: one, or a few that always sign together, such
        /// as a phone's with its Ledger's.
        case keys
    }

    /// A phone keeps at most this many signers.
    public static let maximumSigners = 100
    /// A whole account's keys as one signer, at most.
    public static let maximumKeysPerSigner = 10

    /// Opaque; a UUID string.
    public var id: String
    public var kind: Kind
    public var name: String
    /// `[fp/path]xpub…/<0;1>/*`, one or more.
    public var keys: [String]
    /// The Ledger's master fingerprint; nil for saved keys.
    public var masterFingerprint: UInt32?
    public var addedAt: Date

    public init(id: String, kind: Kind, name: String, keys: [String], masterFingerprint: UInt32?, addedAt: Date) {
        self.id = id
        self.kind = kind
        self.name = name
        self.keys = keys
        self.masterFingerprint = masterFingerprint
        self.addedAt = addedAt
    }

    public var isLedger: Bool { kind == .ledger }

    /// The bounds a backup gets at decode, before anything of it is kept: at
    /// most `maximumSigners` records, each with one to `maximumKeysPerSigner`
    /// keys that parse as signers on the network. The app checks the rest
    /// (unique ids, usable names, each key held once, a Ledger's record
    /// carrying its own key) before replacing local state.
    public static func checkShape(_ records: [SignerRecord], network: BitcoinNetwork) throws {
        guard records.count <= maximumSigners else {
            throw WalletError.invalidBundle("bundle declares \(records.count) signers, above the \(maximumSigners) limit")
        }
        for record in records {
            guard (1 ... maximumKeysPerSigner).contains(record.keys.count) else {
                throw WalletError.invalidBundle("a signer has no keys, or more than \(maximumKeysPerSigner)")
            }
            for key in record.keys where (try? MultisigAccount.signerKey(key, network: network)) == nil {
                throw WalletError.invalidBundle("a signer key does not parse for \(network.rawValue)")
            }
        }
    }
}
