import CryptoKit
import Foundation
import TestSupport
import WalletCore
import XCTest
@testable import WinnowApp

private enum ImportMetadataFault: Error { case expected }
private struct UnavailableImportMetadataKeys: StoreKeyVault {
    func key(for account: String) throws -> SymmetricKey? { throw ImportMetadataFault.expected }
    func establishKey(for account: String) throws -> SymmetricKey { throw ImportMetadataFault.expected }
    func discardKey(for account: String) throws { throw ImportMetadataFault.expected }
}
private final class ImportMetadataSpendingKeys: KeyStore, @unchecked Sendable {
    private let backing = InMemoryKeyStore()
    private let lock = NSLock()
    private var writes = 0
    var stores: Int { lock.withLock { writes } }
    func store(_ secret: WalletSecret, for walletID: String) throws {
        lock.withLock { writes += 1 }
        try backing.store(secret, for: walletID)
    }
    func load(walletID: String) throws -> WalletSecret { try backing.load(walletID: walletID) }
    func delete(walletID: String) throws { try backing.delete(walletID: walletID) }
}

@MainActor
final class WalletImportMetadataTests: XCTestCase {
    private struct Fixture {
        let directory: URL
        let keys: InMemoryStoreKeyVault
        var bundle: ImportBundle
        var file: URL { directory.appending(path: WalletImportMetadata.fileName) }
        var descriptor: String { bundle.descriptor! }
        var nextScanHeight: UInt32 { bundle.lastKnownHeight + 1 }
    }
    private func fixture() async throws -> Fixture {
        let directory = tempFileURL("metadata.json").deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let wallet = try makeTestWallet()
        var bundle = try await wallet.exportBundle(includeMnemonic: true)
        let (vault, _) = try TestVaults.multiAVault()
        let text = vault.descriptor.serialized()
        let coin = try TestVaults.funding(vault: vault, amount: 80_000)
        bundle.vaults = [VaultRecord(id: String(text.split(separator: "#").last!), name: "Imported savings",
            descriptor: text, createdAtHeight: 90, nextReceiveIndex: 1, allUtxos: [coin])]
        return Fixture(directory: directory, keys: InMemoryStoreKeyVault(), bundle: bundle)
    }
    private func store(_ fixture: Fixture, failingWrites: Bool = false) async -> VaultStore {
        let store = VaultStore(keys: fixture.keys, writeData: { data, file in
            if failingWrites { throw ImportMetadataFault.expected }
            try data.write(to: file, options: .atomic)
        })
        await store.configure(storageURL: fixture.directory.appending(path: "vaults.json"), network: .signet)
        return store
    }
    private func assertEmpty(_ store: VaultStore) async {
        let records = await store.all
        XCTAssertTrue(records.isEmpty)
    }
    private func reseal(_ fixture: Fixture, changing: (inout [String: Any]) -> Void) throws {
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: unsealedPayload(of: fixture.file)) as? [String: Any])
        changing(&payload)
        let bytes = try JSONSerialization.data(withJSONObject: payload)
        try StoreSeal(store: "wallet-import-metadata", keys: fixture.keys).write(bytes, network: .signet, to: fixture.file) { data, file in
            try data.write(to: file, options: .atomic)
        }
    }

    func testInterruptedWalletInstallationCompletesMetadataBeforeItIsRemoved() async throws {
        let fixture = try await fixture(), helper = WalletImportMetadata(keys: fixture.keys)
        try helper.begin(bundle: fixture.bundle, network: .signet, directory: fixture.directory)
        let sealed = try Data(contentsOf: fixture.file)
        XCTAssertTrue(SealedStoreFile.isSealed(sealed))
        let payload = try unsealedPayload(of: fixture.file)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "network", "descriptor", "vaults", "maximumNextScanHeight"])
        XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains(try XCTUnwrap(fixture.bundle.mnemonic)))

        // The wallet file exists after the simulated crash, while the shared
        // accounts do not. A new helper uses the sealed marker from disk.
        let walletFile = fixture.directory.appending(path: "wallet.json")
        _ = try Wallet.importing(fixture.bundle, keyStore: InMemoryKeyStore(), storageURL: walletFile)
        let wallet = try Wallet.open(storageURL: walletFile, keyStore: InMemoryKeyStore())
        let frontier = await wallet.nextScanHeight
        let vaults = await store(fixture)
        await assertEmpty(vaults)
        try await WalletImportMetadata(keys: fixture.keys).complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight, network: .signet,
            directory: fixture.directory, vaultStore: vaults)
        let restored = await vaults.all
        XCTAssertEqual(restored, fixture.bundle.vaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        let unchangedFrontier = await wallet.nextScanHeight
        XCTAssertEqual(unchangedFrontier, frontier, "metadata completion must not rewind live wallet state")
        let reopened = VaultStore(keys: fixture.keys)
        let result = await reopened.configure(storageURL: fixture.directory.appending(path: "vaults.json"), network: .signet)
        XCTAssertEqual(result, .loaded)
        let persisted = await reopened.all
        XCTAssertEqual(persisted, restored)
    }

    func testBindingMismatchAndDifferentPendingImportFailBeforeAccountsChange() async throws {
        let fixture = try await fixture(), helper = WalletImportMetadata(keys: fixture.keys), vaults = await store(fixture)
        try helper.begin(bundle: fixture.bundle, network: .signet, directory: fixture.directory)
        let bytes = try Data(contentsOf: fixture.file)
        do {
            try await helper.complete(descriptor: "another descriptor", nextScanHeight: fixture.nextScanHeight, network: .signet, directory: fixture.directory, vaultStore: vaults)
            XCTFail("another wallet completed the marker")
        } catch { XCTAssertEqual(error as? WalletError, .descriptorMismatch) }
        do {
            try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight, network: .mainnet, directory: fixture.directory, vaultStore: vaults)
            XCTFail("another network completed the marker")
        } catch {}
        var changed = fixture.bundle; changed.vaults![0].name = "Different saved account"
        do { try helper.begin(bundle: changed, network: .signet, directory: fixture.directory); XCTFail("pending import was replaced") }
        catch WalletError.invalidBundle {}
        await assertEmpty(vaults)
        XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
        try helper.begin(bundle: fixture.bundle, network: .signet, directory: fixture.directory)
        XCTAssertEqual(try Data(contentsOf: fixture.file), bytes, "the exact import retry should not rewrite the marker")
    }

    func testUnavailableSealAndVaultWriteFailureKeepThePendingMarker() async throws {
        let fixture = try await fixture(), helper = WalletImportMetadata(keys: fixture.keys)
        try helper.begin(bundle: fixture.bundle, network: .signet, directory: fixture.directory)
        let bytes = try Data(contentsOf: fixture.file), normal = await store(fixture)
        do {
            try await WalletImportMetadata(keys: UnavailableImportMetadataKeys()).complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight,
                network: .signet, directory: fixture.directory, vaultStore: normal)
            XCTFail("unavailable protected seal was ignored")
        } catch ImportMetadataFault.expected {}
        await assertEmpty(normal)
        let failing = await store(fixture, failingWrites: true)
        do {
            try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight, network: .signet, directory: fixture.directory, vaultStore: failing)
            XCTFail("failed account persistence cleared the marker")
        } catch ImportMetadataFault.expected {}
        await assertEmpty(failing)
        XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
        try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight, network: .signet, directory: fixture.directory, vaultStore: normal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testFailedFirstMarkerWriteAndUnavailableKeyStopInstallation() async throws {
        let fixture = try await fixture()
        let failing = WalletImportMetadata(keys: fixture.keys, writeData: { _, _ in throw ImportMetadataFault.expected })
        do { try failing.begin(bundle: fixture.bundle, network: .signet, directory: fixture.directory); XCTFail("failed marker write succeeded") }
        catch ImportMetadataFault.expected {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertNil(try fixture.keys.key(for: "wallet-import-metadata.signet"), "failed first write must not strand a new seal key")
        do {
            try WalletImportMetadata(keys: UnavailableImportMetadataKeys()).begin(bundle: fixture.bundle, network: .signet, directory: fixture.directory)
            XCTFail("unavailable protected key was ignored")
        } catch ImportMetadataFault.expected {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testUnsealedTamperedOversizedAndInvalidSavedMetadataFailClosed() async throws {
        let fixture = try await fixture(), helper = WalletImportMetadata(keys: fixture.keys), vaults = await store(fixture)
        try helper.begin(bundle: fixture.bundle, network: .signet, directory: fixture.directory)
        let original = try Data(contentsOf: fixture.file)
        let raw = try unsealedPayload(of: fixture.file)
        for bad in [raw, original + Data([0xff])] {
            try bad.write(to: fixture.file, options: .atomic)
            do {
                try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight, network: .signet, directory: fixture.directory, vaultStore: vaults)
                XCTFail("unverified marker was installed")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: fixture.file), bad)
            await assertEmpty(vaults)
        }
        for change: (inout [String: Any]) -> Void in [
            { $0["version"] = 999 }, { $0["network"] = "mainnet" }, { $0["descriptor"] = "invalid" },
            { $0["maximumNextScanHeight"] = 0 }, { $0["maximumNextScanHeight"] = UInt64(UInt32.max) + 2 }
        ] {
            try original.write(to: fixture.file, options: .atomic)
            try reseal(fixture, changing: change)
            let bad = try Data(contentsOf: fixture.file)
            do {
                try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight, network: .signet, directory: fixture.directory, vaultStore: vaults)
                XCTFail("invalid authenticated metadata was installed")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: fixture.file), bad)
            await assertEmpty(vaults)
        }
        try original.write(to: fixture.file, options: .atomic)
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.truncate(atOffset: UInt64(WalletImportMetadata.maximumBytes + 1)); try handle.close()
        do {
            try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight, network: .signet, directory: fixture.directory, vaultStore: vaults)
            XCTFail("oversized marker was read")
        } catch WalletError.invalidBundle {}
        let size = try fixture.file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertEqual(size, WalletImportMetadata.maximumBytes + 1)
        await assertEmpty(vaults)
    }

    func testOnlyThePendingImportCanMergeAccountsAndExistingReservationsSurvive() async throws {
        var fixture = try await fixture()
        let saved = fixture.bundle.vaults![0]
        var current = saved
        current.allUtxos[0].spent = .init(spentBy: Data(repeating: 7, count: 32), height: nil)
        current.nextChangeIndex = 1
        let vault = try Vault(saved.descriptor, network: .signet)
        current.allUtxos.append(WalletUTXO(txid: Data(repeating: 8, count: 32), vout: 0, amount: 70_000,
            scriptPubKey: try vault.scriptPubKey(index: 0, choice: 1), chain: .change, index: 0, height: 0))
        let (other, _) = try TestVaults.multiAVault(threshold: 3)
        let text = other.descriptor.serialized()
        let added = VaultRecord(id: String(text.split(separator: "#").last!), name: "Other imported account", descriptor: text, createdAtHeight: 80)
        fixture.bundle.vaults!.append(added)
        let store = await store(fixture), helper = WalletImportMetadata(keys: fixture.keys)
        try await store.restore([current])
        try helper.begin(bundle: fixture.bundle, network: .signet, directory: fixture.directory)
        try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight, network: .signet, directory: fixture.directory, vaultStore: store)
        let merged = await store.all
        XCTAssertEqual(merged, [current, added])
        try await store.remove(id: saved.id); try await store.remove(id: added.id)
        try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight, network: .signet, directory: fixture.directory, vaultStore: store)
        await assertEmpty(store)
    }

    func testBeginRejectsSecretsMissingDescriptorWrongNetworkAndInvalidVaultBeforeWriting() async throws {
        let fixture = try await fixture(), helper = WalletImportMetadata(keys: fixture.keys)
        let parsed = try Descriptor(fixture.descriptor)
        guard case let .tr(.single(account), nil) = parsed.expression else { return XCTFail("fixture descriptor") }
        var privateAccount = account
        privateAccount.base = .extended(try BIP86.accountKey(from: testMaster(), coinType: 1, account: 0), network: .testnet)
        var missing = fixture.bundle; missing.descriptor = nil
        var secret = fixture.bundle; secret.descriptor = Descriptor(expression: .tr(.single(privateAccount), nil)).serialized()
        var wrong = fixture.bundle; wrong.network = "mainnet"
        var foreign = fixture.bundle; foreign.vaults![0].allUtxos[0].scriptPubKey = Data([0x51])
        for bad in [missing, secret, wrong, foreign] {
            do { try helper.begin(bundle: bad, network: .signet, directory: fixture.directory); XCTFail("unsafe metadata was written") }
            catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        }
    }

    func testMissingDirectoryAndMarkerAreNoOpsButEmptyAccountsStillRecordTheImport() async throws {
        let fixture = try await fixture(), helper = WalletImportMetadata(keys: fixture.keys), vaults = await store(fixture)
        try helper.begin(bundle: fixture.bundle, network: .signet, directory: nil)
        try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight, network: .signet, directory: nil, vaultStore: vaults)
        try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight, network: .signet, directory: fixture.directory, vaultStore: vaults)
        var empty = fixture.bundle; empty.vaults = nil
        try helper.begin(bundle: empty, network: .signet, directory: fixture.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: fixture.nextScanHeight, network: .signet, directory: fixture.directory, vaultStore: vaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        await assertEmpty(vaults)
    }

    func testNoAccountImportCannotOverwriteAnExistingDifferentMarker() async throws {
        let fixture = try await fixture(), helper = WalletImportMetadata(keys: fixture.keys)
        try helper.begin(bundle: fixture.bundle, network: .signet, directory: fixture.directory)
        let bytes = try Data(contentsOf: fixture.file)
        var empty = fixture.bundle; empty.vaults = nil
        do { try helper.begin(bundle: empty, network: .signet, directory: fixture.directory); XCTFail("empty import replaced pending accounts") }
        catch WalletError.invalidBundle {}
        empty.descriptor = nil
        do { try helper.begin(bundle: empty, network: .signet, directory: fixture.directory); XCTFail("unbound import replaced pending accounts") }
        catch WalletError.invalidBundle {}
        XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
    }

    func testOldSameDescriptorWalletCannotCompleteMetadataAfterItsScanAdvanced() async throws {
        let fixture = try await fixture(), helper = WalletImportMetadata(keys: fixture.keys), vaults = await store(fixture)
        let spendingKeys = InMemoryKeyStore(), walletFile = fixture.directory.appending(path: "wallet.json")
        let previous = try Wallet.importing(fixture.bundle, keyStore: spendingKeys, storageURL: walletFile)
        try await previous.recordScanHeight(501)
        try helper.begin(bundle: fixture.bundle, network: .signet, directory: fixture.directory)
        let bytes = try Data(contentsOf: fixture.file), advanced = await previous.nextScanHeight
        do {
            try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: advanced, network: .signet,
                directory: fixture.directory, vaultStore: vaults)
            XCTFail("same descriptor concealed an old wallet's advanced scan frontier")
        } catch WalletError.invalidBundle {}
        await assertEmpty(vaults)
        XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
        let stillAdvanced = await previous.nextScanHeight
        XCTAssertEqual(stillAdvanced, advanced, "guard must not rewind existing state")
        // Retry the intended wallet commit. The newly imported frontier is
        // still before every pass that must watch the missing account scripts.
        let imported = try Wallet.importing(fixture.bundle, keyStore: spendingKeys, storageURL: walletFile)
        let frontier = await imported.nextScanHeight
        XCTAssertEqual(frontier, fixture.nextScanHeight)
        try await helper.complete(descriptor: fixture.descriptor, nextScanHeight: frontier, network: .signet,
            directory: fixture.directory, vaultStore: vaults)
        let installed = await vaults.all
        XCTAssertEqual(installed, fixture.bundle.vaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testExplicitRetryRequiresTheExactExistingAuthenticatedMetadataWithoutWriting() async throws {
        let fixture = try await fixture(), helper = WalletImportMetadata(keys: fixture.keys)
        do { try helper.requireRetry(bundle: fixture.bundle, network: .signet, directory: fixture.directory); XCTFail("missing marker authorized retry") }
        catch WalletError.invalidBundle {}
        do { try helper.requireRetry(bundle: fixture.bundle, network: .signet, directory: nil); XCTFail("missing directory authorized retry") }
        catch WalletError.invalidBundle {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        try helper.begin(bundle: fixture.bundle, network: .signet, directory: fixture.directory)
        let bytes = try Data(contentsOf: fixture.file)
        try helper.requireRetry(bundle: fixture.bundle, network: .signet, directory: fixture.directory)
        var advanced = fixture.bundle; advanced.lastKnownHeight += 1
        var accounts = fixture.bundle; accounts.vaults![0].name = "Another proposed account"
        for changed in [advanced, accounts] {
            do { try helper.requireRetry(bundle: changed, network: .signet, directory: fixture.directory); XCTFail("different import authorized retry") }
            catch WalletError.invalidBundle {}
        }
        do { try helper.requireRetry(bundle: fixture.bundle, network: .mainnet, directory: fixture.directory); XCTFail("wrong network authorized retry") }
        catch WalletError.invalidBundle {}
        XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
        let corrupt = bytes + Data([0xff])
        try corrupt.write(to: fixture.file, options: .atomic)
        do { try helper.requireRetry(bundle: fixture.bundle, network: .signet, directory: fixture.directory); XCTFail("unverified marker authorized retry") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.file), corrupt)
    }

    private func isolatedBootModel(keys: InMemoryStoreKeyVault, spendingKeys: any KeyStore) throws -> AppModel {
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "import-metadata-\(UUID())",
            "WINNOW_E2E_NETWORK": "regtest", "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f"]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, value in value })
        else { throw ImportMetadataFault.expected }
        addTeardownBlock { cleanup.wipeIfRequested() }
        return AppModel(e2e: mode, storeKeys: keys, keyStore: spendingKeys)
    }

    func testAppModelBootInstallsInterruptedImportAccountsBeforeReadyWithoutStartingNetworking() async throws {
        var fixture = try await fixture()
        fixture.bundle.network = "regtest"
        let spendingKeys = InMemoryKeyStore(), model = try isolatedBootModel(keys: fixture.keys, spendingKeys: spendingKeys)
        let root = try XCTUnwrap(model.storageDirectory())
        try WalletImportMetadata(keys: fixture.keys).begin(bundle: fixture.bundle, network: .regtest, directory: root)
        let imported = try Wallet.importing(fixture.bundle, keyStore: spendingKeys, storageURL: root.appending(path: "wallet.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "vaults.json").path), "crash is before account installation")
        await model.boot()
        XCTAssertEqual(model.stage, .ready)
        let importedID = await imported.id
        XCTAssertEqual(model.walletID, importedID)
        XCTAssertEqual(model.vaults, fixture.bundle.vaults)
        XCTAssertNil(model.stack, "cold boot must finish metadata before networking can activate")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: WalletImportMetadata.fileName).path))
        let persisted = await model.vaultStore.all
        XCTAssertEqual(persisted, fixture.bundle.vaults)
    }

    func testAppModelBootRefusesMismatchedImportMarkerAndCannotActivate() async throws {
        var fixture = try await fixture()
        fixture.bundle.network = "regtest"
        let spendingKeys = InMemoryKeyStore(), model = try isolatedBootModel(keys: fixture.keys, spendingKeys: spendingKeys)
        let root = try XCTUnwrap(model.storageDirectory())
        try WalletImportMetadata(keys: fixture.keys).begin(bundle: fixture.bundle, network: .regtest, directory: root)
        _ = try Wallet.create(network: .regtest, keyStore: spendingKeys, storageURL: root.appending(path: "wallet.json"),
            entropy: Data(repeating: 0x77, count: 16))
        await model.boot()
        guard case .storageDamaged = model.stage else { return XCTFail("unrelated wallet bypassed pending import binding") }
        do { try await model.exclusively(.spending) { XCTFail("Damaged import allowed spending") } }
        catch AppModel.AppError.storageDamaged {}
        await model.scenePhaseChanged(.active)
        XCTAssertNil(model.stack)
        XCTAssertTrue(model.vaults.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: WalletImportMetadata.fileName).path))
        await model.scenePhaseChanged(.background)
    }

    func testAppModelBootRefusesOldSameDescriptorWalletWithAdvancedFrontier() async throws {
        var fixture = try await fixture()
        fixture.bundle.network = "regtest"
        let spendingKeys = InMemoryKeyStore(), model = try isolatedBootModel(keys: fixture.keys, spendingKeys: spendingKeys)
        let root = try XCTUnwrap(model.storageDirectory())
        let old = try Wallet.importing(fixture.bundle, keyStore: spendingKeys, storageURL: root.appending(path: "wallet.json"))
        try await old.recordScanHeight(501)
        try WalletImportMetadata(keys: fixture.keys).begin(bundle: fixture.bundle, network: .regtest, directory: root)
        await model.boot()
        guard case .storageDamaged = model.stage else { return XCTFail("old advanced wallet bypassed account installation gate") }
        await model.scenePhaseChanged(.active)
        XCTAssertNil(model.stack)
        XCTAssertTrue(model.vaults.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: WalletImportMetadata.fileName).path))
        await model.scenePhaseChanged(.background)
    }

    func testAppModelExplicitRetryRepairsMatchingInterruptedImportAndRejectsChangesBeforeKeys() async throws {
        var fixture = try await fixture()
        fixture.bundle.network = "regtest"
        let spendingKeys = ImportMetadataSpendingKeys(), model = try isolatedBootModel(keys: fixture.keys, spendingKeys: spendingKeys)
        let root = try XCTUnwrap(model.storageDirectory()), file = root.appending(path: "wallet.json")
        let old = try Wallet.importing(fixture.bundle, keyStore: spendingKeys, storageURL: file)
        try await old.recordScanHeight(501)
        let marker = root.appending(path: WalletImportMetadata.fileName)
        try WalletImportMetadata(keys: fixture.keys).begin(bundle: fixture.bundle, network: .regtest, directory: root)
        await model.boot()
        guard case .storageDamaged = model.stage else { return XCTFail("fixture did not stop the advanced import") }
        let markerBytes = try Data(contentsOf: marker), walletBytes = try Data(contentsOf: file), stores = spendingKeys.stores
        let other = try Wallet.create(network: .regtest, keyStore: InMemoryKeyStore(), entropy: Data(repeating: 0x77, count: 16))
        let wrongDescriptor = try await other.exportBundle(includeMnemonic: true)
        var wrongAccounts = fixture.bundle; wrongAccounts.vaults![0].name = "Different retry account"
        for changed in [wrongDescriptor, wrongAccounts] {
            do { _ = try await model.importWallet(bundleJSON: changed.serialized()); XCTFail("changed import bypassed the pending marker") }
            catch {}
            XCTAssertEqual(spendingKeys.stores, stores, "retry validation must precede real signing-key writes")
            XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
            XCTAssertEqual(try Data(contentsOf: file), walletBytes)
            XCTAssertTrue(model.vaults.isEmpty)
            XCTAssertNil(model.stack)
        }
        _ = try await model.importWallet(bundleJSON: fixture.bundle.serialized())
        XCTAssertEqual(model.stage, .ready)
        XCTAssertEqual(model.vaults, fixture.bundle.vaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(model.stack, "inactive repaired import waits for activation before syncing")
        let imported = try XCTUnwrap(model.wallet), frontier = await imported.nextScanHeight
        XCTAssertEqual(frontier, fixture.nextScanHeight)
    }

    func testAppModelRejectsMaximumImportHeightBeforeCoreOrRealSigningKeysAreTouched() async throws {
        var fixture = try await fixture()
        fixture.bundle.network = "regtest"
        fixture.bundle.lastKnownHeight = UInt32.max
        let spendingKeys = ImportMetadataSpendingKeys(), model = try isolatedBootModel(keys: fixture.keys, spendingKeys: spendingKeys)
        let root = try XCTUnwrap(model.storageDirectory())
        await model.boot()
        XCTAssertEqual(model.stage, .onboarding)
        do {
            _ = try await model.importWallet(bundleJSON: fixture.bundle.serialized())
            XCTFail("UInt32.max import entered Core's next-height arithmetic")
        } catch WalletError.invalidBundle {}
        XCTAssertEqual(spendingKeys.stores, 0)
        XCTAssertNil(model.wallet)
        XCTAssertNil(model.walletID)
        XCTAssertNil(model.stack)
        XCTAssertTrue(model.vaults.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "wallet.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: WalletImportMetadata.fileName).path))
        XCTAssertNil(try fixture.keys.key(for: "wallet-import-metadata.regtest"))
    }
}
