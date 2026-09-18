import CryptoKit
import Foundation
import TestSupport
import Testing
@testable import WalletCore

@Suite("Encrypted cloud wallet backup")
struct CloudWalletBackupTests {
    private func bundle() async throws -> ImportBundle {
        let wallet = try Wallet.create(network: .signet, keyStore: InMemoryKeyStore(),
                                       entropy: Data(repeating: 7, count: 16), creationHeight: 100)
        return try await wallet.exportBundle(includeMnemonic: true)
    }

    @Test func roundTripRestoresSigningAndAddressCounters() async throws {
        var original = try await bundle()
        original.nextReceiveIndex = 19
        original.nextChangeIndex = 8
        let key = SymmetricKey(size: .bits256)
        let encrypted = try CloudWalletBackup.create(bundle: original, key: key)
        let data = try encrypted.encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains(original.mnemonic!))
        let restored = try CloudWalletBackup.decode(data).restoredBundle(key: key)
        #expect(restored == original)
        let keys = InMemoryKeyStore()
        let wallet = try Wallet.importing(restored, keyStore: keys)
        let walletID = await wallet.id
        #expect(try keys.load(walletID: walletID) == .mnemonic(original.mnemonic!))
    }

    @Test func automaticUpdateKeepsTheSealedKeyAndNewHistoryFrontier() async throws {
        let original = try await bundle()
        let key = SymmetricKey(size: .bits256)
        let first = try CloudWalletBackup.create(bundle: original, key: key)
        var next = original
        next.mnemonic = nil
        next.lastKnownHeight = 123
        next.nextReceiveIndex = 5
        let updated = try first.updating(bundle: next, key: key)
        #expect(updated.sealedPhrase == first.sealedPhrase)
        let restored = try updated.restoredBundle(key: key)
        #expect(restored.mnemonic == original.mnemonic)
        #expect(restored.lastKnownHeight == 123)
        #expect(restored.nextReceiveIndex == 5)
    }

    @Test func wrongKeyAndModifiedMetadataAreRejected() async throws {
        let key = SymmetricKey(size: .bits256)
        let original = try await bundle()
        let backup = try CloudWalletBackup.create(bundle: original, key: key)
        #expect(throws: (any Error).self) { try backup.restoredBundle(key: SymmetricKey(size: .bits256)) }
        var json = try #require(JSONSerialization.jsonObject(with: backup.encoded()) as? [String: Any])
        for field in ["id", "network", "savedAt", "sealedWallet", "sealedPhrase"] {
            var changed = json
            switch field {
            case "id": changed[field] = UUID().uuidString
            case "network": changed[field] = "mainnet"
            case "savedAt": changed[field] = 1
            default: changed[field] = Data(repeating: 0, count: 40).base64EncodedString()
            }
            let data = try JSONSerialization.data(withJSONObject: changed)
            #expect(throws: (any Error).self) { try CloudWalletBackup.decode(data).restoredBundle(key: key) }
        }
        json["version"] = 2
        let future = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: (any Error).self) { try CloudWalletBackup.decode(future) }
    }

    @Test func mismatchedWalletAndMissingPhraseAreRefused() async throws {
        var original = try await bundle()
        let key = SymmetricKey(size: .bits256)
        let backup = try CloudWalletBackup.create(bundle: original, key: key)
        original.descriptor = "different wallet"
        #expect(throws: (any Error).self) { try backup.updating(bundle: original, key: key) }
        original.mnemonic = nil
        #expect(throws: (any Error).self) { try CloudWalletBackup.create(bundle: original, key: key) }
        #expect(throws: (any Error).self) {
            try CloudWalletBackup.decode(Data(repeating: 0, count: CloudWalletBackup.maximumBytes + 1))
        }
    }
}
