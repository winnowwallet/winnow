import Foundation
import UIKit
import WalletCore

/// The existing TestFlight identity gets a separate Swift wallet namespace.
/// Legacy PQLN keys and files are preserved and never opened by this engine.
enum LightningResearch {
    static let storageName = "Winnow-Lightning-SwiftV2"
    static let keychainService = "com.btcswift.lightning.swift-v2"

    /// Preferences live beside that namespace, not in the app's standard
    /// defaults, which the legacy engine also used.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: keychainService + ".preferences") ?? .standard
    }

    /// Application Support/Winnow-Lightning-SwiftV2, without creating it.
    static var storageRoot: URL? {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: false))?.appending(path: storageName)
    }

    /// Old releases did not save their forced network preference. Retain a
    /// pre-existing research wallet on upgrade; fresh installs use mainnet.
    static func initialNetwork(root: URL?) -> BitcoinNetwork {
        guard let root else { return .mainnet }
        let old = root.appending(path: "regtest")
        return ["wallet.json", "lightning/journal.v1"].contains {
            FileManager.default.fileExists(atPath: old.appending(path: $0).path)
        } ? .regtest : .mainnet
    }

    /// The app's one model, in this app's own preferences namespace.
    @MainActor
    static func makeModel() -> AppModel {
        #if DEBUG
        if E2EMode.current != nil,
           UIDevice.current.userInterfaceIdiom == .phone {
            // Use still UIKit transitions for phone UI fixtures.
            UIView.setAnimationsEnabled(false)
        }
        #endif
        let model = AppModel(defaults: defaults)
        #if DEBUG
        model.e2e?.journal("ui.animationPolicy", fields: ["uikitEnabled": String(UIView.areAnimationsEnabled)])
        #endif
        return model
    }
}
