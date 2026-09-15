import CryptoKit
import Foundation
import Testing
@testable import WalletCore

struct CensusCatalogStoreTests {
    @Test func replacementRecoveryAndExpiration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CensusCatalogStore(url: directory.appendingPathComponent("catalog.json"), minimumEntries: 0)
        let fixture = CensusCatalogTests()
        let original = try JSONEncoder().encode(fixture.catalog())
        let download = try store.replace(with: original, now: fixture.now)
        #expect(download.sha256.count == 64)
        #expect(store.load(now: fixture.now)?.sha256 == download.sha256)
        #expect(throws: (any Error).self) { try store.replace(with: Data("{}".utf8), now: fixture.now) }
        #expect(try Data(contentsOf: store.url) == original)
        #expect(store.load(now: fixture.now.addingTimeInterval(8 * 86400)) == nil)
        #expect(try Data(contentsOf: store.url) == original)
        #expect(throws: (any Error).self) {
            try store.replace(with: Data(repeating: 0, count: CensusCatalog.maximumBytes + 1), now: fixture.now)
        }
        #expect(try Data(contentsOf: store.url) == original)
    }

    /// A list thinner than any real census is refused by default, and once a
    /// publisher key is trusted a download must carry that publisher's
    /// signature — which is kept beside the list and checked again on load.
    @Test func thinListsAndMissingOrForeignSignaturesAreRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = CensusCatalogTests()
        let original = try JSONEncoder().encode(fixture.catalog())

        let floored = CensusCatalogStore(url: directory.appendingPathComponent("floored.json"))
        #expect(floored.minimumEntries == CensusCatalog.minimumClearnetEntries)
        #expect(throws: CensusCatalog.Invalid.thin) { try floored.replace(with: original, now: fixture.now) }
        #expect(!FileManager.default.fileExists(atPath: floored.url.path))

        let key = Curve25519.Signing.PrivateKey()
        let store = CensusCatalogStore(url: directory.appendingPathComponent("signed.json"), minimumEntries: 0)
        #expect(throws: CensusSignature.Invalid.missing) {
            try store.replace(with: original, trusting: [key.publicKey], now: fixture.now)
        }
        let foreign = try CensusSignature.sign(original, with: Curve25519.Signing.PrivateKey()).encoded()
        #expect(throws: CensusSignature.Invalid.unknownKey) {
            try store.replace(with: original, signature: foreign, trusting: [key.publicKey], now: fixture.now)
        }
        let signature = try CensusSignature.sign(original, with: key).encoded()
        let download = try store.replace(with: original, signature: signature, trusting: [key.publicKey], now: fixture.now)
        #expect(try Data(contentsOf: store.signatureURL) == signature)
        #expect(store.load(now: fixture.now, trusting: [key.publicKey])?.sha256 == download.sha256)

        // The stored signature is part of the stored list: damaged, the list
        // no longer loads for a wallet that trusts the key, and still loads
        // for one that trusts none.
        try Data("{}".utf8).write(to: store.signatureURL)
        #expect(store.load(now: fixture.now, trusting: [key.publicKey]) == nil)
        #expect(store.load(now: fixture.now, trusting: []) != nil)
    }
}
