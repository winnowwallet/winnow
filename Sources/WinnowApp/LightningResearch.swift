import Foundation
import WalletCore

/// The existing TestFlight identity gets a separate Swift wallet namespace.
/// Legacy PQLN keys and files are preserved and never opened by this engine.
enum LightningResearch {
    static let bundleID = "com.btcswift.lightning"
    static let storageName = "Winnow-Lightning-SwiftV2"
    static let keychainService = "com.btcswift.lightning.swift-v2"
    static var isResearchApp: Bool { Bundle.main.bundleIdentifier == bundleID }
    static func enabled(e2e: E2EMode?) -> Bool { isResearchApp || e2e?.forcedNetwork == .regtest }

    /// Old releases did not save their forced network preference. Retain a
    /// pre-existing research wallet on upgrade; fresh installs use mainnet.
    static func initialNetwork(root: URL?) -> BitcoinNetwork {
        guard let root else { return .mainnet }
        let old = root.appending(path: "regtest")
        return ["wallet.json", "lightning/journal.v1"].contains {
            FileManager.default.fileExists(atPath: old.appending(path: $0).path)
        } ? .regtest : .mainnet
    }
}
