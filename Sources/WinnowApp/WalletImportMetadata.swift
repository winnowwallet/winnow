import Foundation
import WalletCore

/// Public shared-account state committed before the wallet file is installed.
/// Startup completes this marker before any filter scan can advance without
/// the imported accounts' scripts. Signing secrets never enter this file.
struct WalletImportMetadata: Sendable {
    static let fileName = "wallet-import-metadata.json"
    static let maximumBytes = 16 * 1_024 * 1_024

    private struct Metadata: Codable, Equatable {
        var version = 1
        let network: String
        let descriptor: String
        let vaults: [VaultRecord]
        let maximumNextScanHeight: UInt64
    }
    private struct Pending {
        let metadata: Metadata
        let bytes: Data
    }
    private let seal: StoreSeal
    private let writeData: @Sendable (Data, URL) throws -> Void

    init(keys: any StoreKeyVault, writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }) {
        seal = StoreSeal(store: "wallet-import-metadata", keys: keys)
        self.writeData = writeData
    }

    func begin(bundle: ImportBundle, network: BitcoinNetwork, directory: URL?) throws {
        try Self.requireNetwork(bundle.network, network: network)
        let records = bundle.vaults ?? []
        guard let directory else { return }
        let metadata = try Self.metadata(bundle: bundle, records: records, network: network)
        let file = directory.appending(path: Self.fileName)
        if let pending = try read(file, network: network) {
            try Self.requireSameImport(pending.metadata, metadata)
            return
        }
        try seal.write(JSONEncoder().encode(metadata), network: network, to: file, using: boundedWriter)
    }

    func complete(descriptor: String, nextScanHeight: UInt32, network: BitcoinNetwork, directory: URL?, vaultStore: VaultStore) async throws {
        guard let directory else { return }
        let file = directory.appending(path: Self.fileName)
        guard let pending = try read(file, network: network) else { return }
        guard pending.metadata.descriptor == descriptor else { throw WalletError.descriptorMismatch }
        try Self.requireUnadvancedFrontier(nextScanHeight, metadata: pending.metadata)
        try await vaultStore.mergeMissingRecoveryRecords(pending.metadata.vaults)
        try removeCompleted(file, matching: pending.bytes)
    }

    /// A damaged import may bypass the normal replacement guard only for
    /// the exact authenticated public metadata that was committed earlier.
    func requireRetry(bundle: ImportBundle, network: BitcoinNetwork, directory: URL?) throws {
        try Self.requireNetwork(bundle.network, network: network)
        let proposed = try Self.metadata(bundle: bundle, records: bundle.vaults ?? [], network: network)
        guard let directory else { throw WalletError.invalidBundle("No interrupted wallet import is available.") }
        guard let pending = try read(directory.appending(path: Self.fileName), network: network) else {
            throw WalletError.invalidBundle("No interrupted wallet import is available.")
        }
        try Self.requireSameImport(pending.metadata, proposed)
    }

    private static func metadata(bundle: ImportBundle, records: [VaultRecord], network: BitcoinNetwork) throws -> Metadata {
        guard let text = bundle.descriptor else {
            throw WalletError.invalidBundle("Wallet import requires its public wallet descriptor.")
        }
        let descriptor = try publicDescriptor(text, network: network)
        let metadata = Metadata(network: network.rawValue, descriptor: descriptor, vaults: records,
            maximumNextScanHeight: UInt64(bundle.lastKnownHeight) + 1)
        try validate(metadata, network: network)
        return metadata
    }

    private static func validate(_ metadata: Metadata, network: BitcoinNetwork) throws {
        guard metadata.version == 1 else { throw WalletError.invalidBundle("Unsupported interrupted import metadata.") }
        try requireNetwork(metadata.network, network: network)
        guard try publicDescriptor(metadata.descriptor, network: network) == metadata.descriptor else {
            throw WalletError.invalidBundle("Interrupted import descriptor is not canonical.")
        }
        try requireFrontierBound(metadata.maximumNextScanHeight)
        try requireRecordBounds(metadata.vaults)
        try VaultStore.validate(metadata.vaults, network: network)
    }

    private static func requireRecordBounds(_ records: [VaultRecord]) throws {
        guard records.count <= ImportBundle.maximumVaults else {
            throw WalletError.invalidBundle("Too many interrupted import accounts.")
        }
        guard records.reduce(0, { $0 + $1.allUtxos.count }) <= ImportBundle.maximumEntries else {
            throw WalletError.invalidBundle("Too many interrupted import account coins.")
        }
    }

    private static func requireFrontierBound(_ height: UInt64) throws {
        guard height >= 1, height <= UInt64(UInt32.max) + 1 else {
            throw WalletError.invalidBundle("Interrupted import scan frontier is invalid.")
        }
    }

    private static func requireUnadvancedFrontier(_ height: UInt32, metadata: Metadata) throws {
        guard UInt64(height) <= metadata.maximumNextScanHeight else {
            throw WalletError.invalidBundle("Retry the wallet import before syncing: its shared accounts were not installed before this wallet advanced.")
        }
    }

    private static func publicDescriptor(_ text: String, network: BitcoinNetwork) throws -> String {
        guard text.utf8.count <= maximumBytes else { throw WalletError.invalidBundle("Interrupted import descriptor is too large.") }
        let descriptor = try Descriptor(text)
        guard case let .tr(.single(key), nil) = descriptor.expression else {
            throw WalletError.invalidBundle("Interrupted import requires a public wallet descriptor.")
        }
        try requirePublicAccount(key, network: network)
        return descriptor.serialized()
    }

    private static func requirePublicAccount(_ key: Descriptor.SingleKey, network: BitcoinNetwork) throws {
        guard case let .extended(account, keyNetwork) = key.base else {
            throw WalletError.invalidBundle("Interrupted import requires an extended public account key.")
        }
        guard account.privateKey == nil else { throw WalletError.invalidBundle("Signing secrets cannot enter interrupted import metadata.") }
        try requireAccountNetwork(keyNetwork, network: network)
    }

    private static func requireAccountNetwork(_ keyNetwork: HDKey.Network, network: BitcoinNetwork) throws {
        let expected: HDKey.Network = network == .mainnet ? .mainnet : .testnet
        guard keyNetwork == expected else { throw WalletError.invalidBundle("Interrupted import account belongs to another network.") }
    }

    private static func requireNetwork(_ saved: String, network: BitcoinNetwork) throws {
        guard saved == network.rawValue else { throw WalletError.invalidBundle("Interrupted import belongs to another network.") }
    }

    private static func requireSameImport(_ existing: Metadata, _ proposed: Metadata) throws {
        guard existing == proposed else { throw WalletError.invalidBundle("Finish the pending wallet import before importing other account metadata.") }
    }

    private func read(_ file: URL, network: BitcoinNetwork) throws -> Pending? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let bytes = try Self.boundedRead(file)
        let opened = try seal.read(bytes, network: network)
        guard !opened.predatesSealing else { throw SealedStoreFile.Failure.unsealed }
        let metadata = try JSONDecoder().decode(Metadata.self, from: opened.payload)
        try Self.validate(metadata, network: network)
        return Pending(metadata: metadata, bytes: bytes)
    }

    private static func boundedRead(_ file: URL) throws -> Data {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        try requireBound(size)
        let bytes = try Data(contentsOf: file)
        try requireBound(bytes.count)
        return bytes
    }

    private var boundedWriter: @Sendable (Data, URL) throws -> Void {
        let write = writeData
        return { data, file in
            try Self.requireBound(data.count)
            try write(data, file)
        }
    }

    private static func requireBound(_ size: Int) throws {
        guard size <= maximumBytes else { throw WalletError.invalidBundle("Interrupted import metadata is too large.") }
    }

    private func removeCompleted(_ file: URL, matching bytes: Data) throws {
        guard try Self.boundedRead(file) == bytes else { throw WalletError.invalidBundle("Interrupted import metadata changed during completion.") }
        try FileManager.default.removeItem(at: file)
    }
}
