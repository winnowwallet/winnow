import Foundation
import WalletCore

/// Local notes about our addresses, separate from contacts and sender identity.
/// A snapshot belongs to exactly one wallet on one network. It is not part of
/// an address, QR code, payment card, or wallet export.
@MainActor
final class ReceiveAddressLabelStore {
    static let maximumLabels = 10_000
    static let maximumLabelLength = 120
    static let maximumFileBytes = 4 * 1_024 * 1_024

    enum StorageError: LocalizedError {
        case unavailable, damaged, invalidLabel, full

        var errorDescription: String? {
            switch self {
            case .unavailable: "Receive address labels could not be saved on this device."
            case .damaged: "Receive address labels could not be read safely. The saved file was left untouched. You can still receive without a label."
            case .invalidLabel: "Use a single-line label of at most 120 characters."
            case .full: "This wallet has reached its limit of 10,000 receive address labels."
            }
        }
    }

    private struct Payload: Codable {
        var version = 1
        var walletID: String
        var network: String
        /// Canonical script hex → note. Scripts avoid address spelling aliases.
        var labels: [String: String]
    }

    let walletID: String
    let network: BitcoinNetwork
    let storageURL: URL?
    private(set) var labels: [Data: String] = [:]
    private(set) var notice: String?
    private let writeData: (Data, URL) throws -> Void

    init(storageURL: URL?, walletID: String, network: BitcoinNetwork,
         writeData: @escaping (Data, URL) throws -> Void = { data, url in
             try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
         }) {
        self.storageURL = storageURL
        self.walletID = walletID
        self.network = network
        self.writeData = writeData
        guard let storageURL else {
            notice = StorageError.unavailable.localizedDescription
            return
        }
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            labels = try Self.readLabels(at: storageURL, walletID: walletID, network: network)
        } catch {
            notice = StorageError.damaged.localizedDescription
        }
    }

    private static func readLabels(at storageURL: URL, walletID: String,
                                   network: BitcoinNetwork) throws -> [Data: String] {
        let size = try storageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= Self.maximumFileBytes else { throw StorageError.damaged }
        let data = try Data(contentsOf: storageURL)
        guard data.count <= Self.maximumFileBytes else { throw StorageError.damaged }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.version == 1, payload.walletID == walletID, payload.network == network.rawValue,
              payload.labels.count <= Self.maximumLabels else { throw StorageError.damaged }
        var decoded: [Data: String] = [:]
        for (key, label) in payload.labels {
            guard let script = Data(hex: key), script.hex == key,
                  AddressDecoder.address(for: script, network: network) != nil,
                  try Self.normalizedLabel(label) == label, !label.isEmpty
            else { throw StorageError.damaged }
            decoded[script] = label
        }
        return decoded
    }

    static func normalizedLabel(_ text: String) throws -> String {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.count <= maximumLabelLength, label.utf8.count <= maximumLabelLength * 4,
              !label.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
              }) else { throw StorageError.invalidLabel }
        return label
    }

    /// Empty text removes a label. Commit the live view only after the atomic
    /// write succeeds, so a failed edit cannot silently relabel a payment.
    func setLabel(_ text: String, address: String) throws {
        guard notice == nil else { throw StorageError.damaged }
        guard let storageURL else { throw StorageError.unavailable }
        let script = try AddressDecoder.scriptPubKey(for: address, network: network)
        let label = try Self.normalizedLabel(text)
        var updated = labels
        if label.isEmpty { updated.removeValue(forKey: script) }
        else { updated[script] = label }
        guard updated.count <= Self.maximumLabels else { throw StorageError.full }
        let payload = Payload(walletID: walletID, network: network.rawValue,
                              labels: Dictionary(uniqueKeysWithValues: updated.map { ($0.key.hex, $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= Self.maximumFileBytes else { throw StorageError.full }
        try writeData(data, storageURL)
        labels = updated
    }
}
