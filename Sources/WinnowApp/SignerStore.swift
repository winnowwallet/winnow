import WalletCore
import Foundation

enum SignerStorageOpenResult: Equatable, Sendable {
    case missing
    case loaded
    case damaged(String)
}

enum SignerStorageError: Error, Equatable, LocalizedError {
    case invalidState(String)
    case damaged
    case duplicate(existingName: String)
    case unknownSigner
    case tooMany

    var errorDescription: String? {
        switch self {
        case let .invalidState(reason):
            "Invalid signer storage: \(reason)"
        case .damaged:
            "Winnow could not safely read its signers, so they cannot be changed until the file is readable again."
        case let .duplicate(existingName):
            "That key is already saved as \(existingName)."
        case .unknownSigner:
            "That signer is no longer on this phone."
        case .tooMany:
            "Winnow keeps at most \(SignerStore.maximumSigners) signers."
        }
    }
}

/// The signers this phone knows (`SignerRecord`), from which the multisig
/// builder takes its members and the Join screen its member share: one
/// sealed JSON file per network, `signers.json`, read under the same seal
/// as the other stores, and carried in every backup, file and iCloud. Public
/// keys only, so the file is not a wallet's and survives deleting one, like
/// `people.json`. Damage is reported, the file left untouched and every
/// mutation refused until it reads again; the wallet itself carries on.
/// Exercised by AppTests/SignerRosterTests.
actor SignerStore {
    static let maximumSigners = SignerRecord.maximumSigners
    static let maximumKeysPerSigner = SignerRecord.maximumKeysPerSigner
    static let maximumFileBytes = 1_024 * 1_024

    typealias Backup = [SignerRecord]

    private var records: [SignerRecord] = []
    private var storageURL: URL?
    private var network: BitcoinNetwork = .signet
    private var isDamaged = false
    private let writeData: @Sendable (Data, URL) throws -> Void
    /// Reads verify and writes seal, under a key the app container cannot
    /// reach: a key substituted in the file would validate perfectly and put
    /// a stranger into every account built from it afterwards.
    private let seal: StoreSeal

    init(keys: any StoreKeyVault, writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }) {
        seal = StoreSeal(store: "signers", keys: keys)
        self.writeData = writeData
    }

    /// Points the store at its JSON file, loading any existing records.
    @discardableResult
    func configure(storageURL: URL?, network: BitcoinNetwork) -> SignerStorageOpenResult {
        self.storageURL = storageURL
        self.network = network
        isDamaged = false
        records = []
        guard let storageURL, FileManager.default.fileExists(atPath: storageURL.path) else { return .missing }
        do {
            let file = try seal.read(try Self.boundedRead(storageURL), network: network)
            // No Winnow wrote this file before sealing existed, so an
            // unsealed one was put here by something else.
            guard !file.predatesSealing else { throw SealedStoreFile.Failure.unsealed }
            let decoded = try JSONDecoder().decode([SignerRecord].self, from: file.payload)
            try Self.validate(decoded, network: network)
            records = decoded
            return .loaded
        } catch {
            isDamaged = true
            return .damaged(error is SealedStoreFile.Failure ? Self.unverifiedStorageMessage : Self.damagedStorageMessage)
        }
    }

    var all: [SignerRecord] { records }

    func record(id: String) -> SignerRecord? {
        records.first { $0.id == id }
    }

    /// Files a paired Ledger. Pairing the same Ledger again renames the
    /// record it has rather than adding a copy.
    @discardableResult
    func addLedger(name: String, key: String, fingerprint: UInt32) throws -> SignerRecord {
        guard !isDamaged else { throw SignerStorageError.damaged }
        let name = try Self.usableName(name)
        if let index = records.firstIndex(where: { $0.isLedger && $0.masterFingerprint == fingerprint && $0.keys == [key] }) {
            try mutate { $0[index].name = name }
            return records[index]
        }
        let record = SignerRecord(id: UUID().uuidString, kind: .ledger, name: name, keys: [key],
                                  masterFingerprint: fingerprint, addedAt: Date())
        try append(record)
        return record
    }

    /// Files keys someone sent as one signer.
    @discardableResult
    func addKeys(name: String, keys: [String]) throws -> SignerRecord {
        guard !isDamaged else { throw SignerStorageError.damaged }
        let record = SignerRecord(id: UUID().uuidString, kind: .keys, name: try Self.usableName(name), keys: keys,
                                  masterFingerprint: nil, addedAt: Date())
        try append(record)
        return record
    }

    func rename(id: String, name: String) throws {
        guard !isDamaged else { throw SignerStorageError.damaged }
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw SignerStorageError.unknownSigner }
        let name = try Self.usableName(name)
        try mutate { $0[index].name = name }
    }

    func remove(id: String) throws {
        guard !isDamaged else { throw SignerStorageError.damaged }
        guard records.contains(where: { $0.id == id }) else { throw SignerStorageError.unknownSigner }
        try mutate { $0.removeAll { $0.id == id } }
    }

    // MARK: - Backup

    /// The records for a backup, file or iCloud.
    func backup() throws -> Backup {
        guard !isDamaged else { throw SignerStorageError.damaged }
        return records
    }

    static func validateBackup(_ backup: Backup, network: BitcoinNetwork) throws {
        try validate(backup, network: network)
        guard try JSONEncoder().encode(backup).count <= maximumFileBytes else {
            throw SignerStorageError.invalidState("invalid cloud signer list")
        }
    }

    /// Keeps the signers already on this phone and adds the restored ones it
    /// does not have, by id or by key; the rest are dropped at the ceiling.
    func planRestore(_ incoming: Backup) throws -> Backup {
        guard !isDamaged else { throw SignerStorageError.damaged }
        try Self.validateBackup(incoming, network: network)
        var merged = records
        var held = Set(try merged.flatMap { try Self.identities(of: $0.keys, network: network) })
        for record in incoming where merged.count < Self.maximumSigners {
            let identities = try Self.identities(of: record.keys, network: network)
            guard !merged.contains(where: { $0.id == record.id }), identities.allSatisfy({ !held.contains($0) }) else { continue }
            merged.append(record)
            held.formUnion(identities)
        }
        try Self.validateBackup(merged, network: network)
        return merged
    }

    func restore(_ backup: Backup) throws {
        guard !isDamaged else { throw SignerStorageError.damaged }
        try Self.validateBackup(backup, network: network)
        try mutate { $0 = backup }
    }

    // MARK: - Validation

    /// A short single-line name, as the other stores take one.
    private static func usableName(_ name: String) throws -> String {
        guard let name = DisplayName.normalized(name) else {
            throw SignerStorageError.invalidState("a signer needs a short, single-line name")
        }
        return name
    }

    private func append(_ record: SignerRecord) throws {
        guard records.count < Self.maximumSigners else { throw SignerStorageError.tooMany }
        let identities = try Self.identities(of: record.keys, network: network)
        if let holder = try records.first(where: { holder in
            try !Set(Self.identities(of: holder.keys, network: network)).isDisjoint(with: identities)
        }) {
            throw SignerStorageError.duplicate(existingName: holder.name)
        }
        try mutate { $0.append(record) }
    }

    /// The compressed account public keys behind key expressions, which must
    /// all parse as signers on this network.
    static func identities(of keys: [String], network: BitcoinNetwork) throws -> [Data] {
        try keys.map { key in
            let single = try MultisigAccount.signerKey(key, network: network)
            guard case let .extended(xpub, _) = single.base else {
                throw SignerStorageError.invalidState("a signer key is not an extended key")
            }
            return xpub.publicKey
        }
    }

    /// Unique ids and names in shape, every key a signer on this network and
    /// held by one record, a Ledger's record carrying its one key at the
    /// Ledger's path under its own fingerprint.
    static func validate(_ records: [SignerRecord], network: BitcoinNetwork) throws {
        guard records.count <= maximumSigners else { throw SignerStorageError.invalidState("too many signers") }
        var ids: Set<String> = []
        var held: Set<Data> = []
        for record in records {
            guard !record.id.isEmpty, ids.insert(record.id).inserted else {
                throw SignerStorageError.invalidState("duplicate signer identifier")
            }
            guard DisplayName.normalized(record.name) == record.name, !record.name.isEmpty else {
                throw SignerStorageError.invalidState("a signer has no usable name")
            }
            guard (1 ... maximumKeysPerSigner).contains(record.keys.count) else {
                throw SignerStorageError.invalidState("a signer has no keys, or too many")
            }
            for identity in try identities(of: record.keys, network: network) {
                guard held.insert(identity).inserted else { throw SignerStorageError.invalidState("a key is held by two signers") }
            }
            try validateKind(record, network: network)
        }
    }

    private static func validateKind(_ record: SignerRecord, network: BitcoinNetwork) throws {
        switch record.kind {
        case .ledger:
            let key = try MultisigAccount.signerKey(record.keys[0], network: network)
            guard record.keys.count == 1, let fingerprint = record.masterFingerprint,
                  key.origin?.fingerprint == fingerprint, key.origin?.path == LedgerMultisig.keyPath(network: network) else {
                throw SignerStorageError.invalidState("a Ledger's record does not carry its own key")
            }
        case .keys:
            guard record.masterFingerprint == nil else {
                throw SignerStorageError.invalidState("saved keys carry no device fingerprint")
            }
        }
    }

    /// Measures before reading, so a planted file is refused rather than held.
    static func boundedRead(_ url: URL) throws -> Data {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? Int.max
        guard size <= maximumFileBytes else { throw SignerStorageError.invalidState("signer file too large") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumFileBytes else { throw SignerStorageError.invalidState("signer file too large") }
        return data
    }

    /// Applies a change and persists it, restoring the previous records if
    /// the write fails.
    private func mutate(_ change: (inout [SignerRecord]) throws -> Void) throws {
        let previous = records
        do {
            try change(&records)
            try persist()
        } catch {
            records = previous
            throw error
        }
    }

    private func persist() throws {
        guard let storageURL else { return }
        let data = try JSONEncoder().encode(records)
        try seal.write(data, network: network, to: storageURL, using: writeData)
    }

    private static let damagedStorageMessage =
        "Winnow found its signer list but could not safely read it. The file and protected keys were left untouched. Retry; if this continues, pair the Ledger and save the keys again, or ask for help before changing anything."

    private static let unverifiedStorageMessage =
        "Winnow found a signer list it could not verify: the file was not written by Winnow on this device, or its protected key is gone. The file and protected keys were left untouched. Pair the Ledger and save the keys again, or ask for help before changing anything."
}
