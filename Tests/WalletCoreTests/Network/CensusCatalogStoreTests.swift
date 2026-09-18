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
        let key = Curve25519.Signing.PrivateKey()
        let signature = try CensusSignature.sign(original, with: key).encoded()
        let download = try store.replace(with: original, signature: signature, trusting: [key.publicKey], now: fixture.now)
        #expect(download.sha256.count == 64)
        #expect(store.load(now: fixture.now, trusting: [key.publicKey])?.sha256 == download.sha256)
        let malformed = Data("{}".utf8)
        #expect(throws: (any Error).self) {
            try store.replace(with: malformed, signature: CensusSignature.sign(malformed, with: key).encoded(),
                              trusting: [key.publicKey], now: fixture.now)
        }
        #expect(try Data(contentsOf: store.url) == original)
        #expect(store.load(now: fixture.now.addingTimeInterval(8 * 86400), trusting: [key.publicKey]) == nil)
        #expect(try Data(contentsOf: store.url) == original)
        let oversized = Data(repeating: 0, count: CensusCatalog.maximumBytes + 1)
        #expect(throws: CensusCatalog.Invalid.size) {
            try store.replace(with: oversized, signature: CensusSignature.sign(oversized, with: key).encoded(),
                              trusting: [key.publicKey], now: fixture.now)
        }
        #expect(try Data(contentsOf: store.url) == original)
    }

    @Test func productionTrustRejectsAnUnsignedCachedCatalog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = CensusCatalogTests()
        let original = try JSONEncoder().encode(fixture.catalog())
        let store = CensusCatalogStore(url: directory.appendingPathComponent("catalog.json"), minimumEntries: 0)
        try original.write(to: store.url)
        #expect(store.load(now: fixture.now) == nil)
        #expect(throws: CensusSignature.Invalid.missing) {
            try store.replace(with: original, now: fixture.now)
        }
        #expect(try Data(contentsOf: store.url) == original)
    }

    /// A list thinner than any real census is refused by default. Every
    /// download must carry a trusted publisher's
    /// signature — which is kept beside the list and checked again on load.
    @Test func thinListsAndMissingOrForeignSignaturesAreRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = CensusCatalogTests()
        let original = try JSONEncoder().encode(fixture.catalog())
        let key = Curve25519.Signing.PrivateKey()
        let signature = try CensusSignature.sign(original, with: key).encoded()

        let floored = CensusCatalogStore(url: directory.appendingPathComponent("floored.json"))
        #expect(floored.minimumEntries == CensusCatalog.minimumClearnetEntries)
        #expect(throws: CensusCatalog.Invalid.thin) {
            try floored.replace(with: original, signature: signature, trusting: [key.publicKey], now: fixture.now)
        }
        #expect(!FileManager.default.fileExists(atPath: floored.url.path))

        let store = CensusCatalogStore(url: directory.appendingPathComponent("signed.json"), minimumEntries: 0)
        #expect(throws: CensusSignature.Invalid.missing) {
            try store.replace(with: original, trusting: [key.publicKey], now: fixture.now)
        }
        let foreign = try CensusSignature.sign(original, with: Curve25519.Signing.PrivateKey()).encoded()
        #expect(throws: CensusSignature.Invalid.unknownKey) {
            try store.replace(with: original, signature: foreign, trusting: [key.publicKey], now: fixture.now)
        }
        let download = try store.replace(with: original, signature: signature, trusting: [key.publicKey], now: fixture.now)
        #expect(try Data(contentsOf: store.signatureURL) == signature)
        #expect(store.load(now: fixture.now, trusting: [key.publicKey])?.sha256 == download.sha256)

        // The stored signature is part of the stored list: damaged, the list
        // no longer loads, including under an empty trust configuration.
        try Data("{}".utf8).write(to: store.signatureURL)
        #expect(store.load(now: fixture.now, trusting: [key.publicKey]) == nil)
        #expect(store.load(now: fixture.now, trusting: []) == nil)
    }
}
