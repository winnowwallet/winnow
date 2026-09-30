@testable import WinnowLightning
import Foundation
import TestSupport
import WalletCore
import XCTest

/// The Lightning-only behavior the shared model and stores take on under
/// `LIGHTNING` (AppModel+Lightning.swift and the hooks that call into it).
@MainActor
final class LightningHookTests: XCTestCase {
    func testLightningHonorsSavedSimpleAndAdvancedChoices() throws {
        guard case let .active(e2e) = E2EMode.resolve(environment: [
            "WINNOW_E2E": "1", "WINNOW_E2E_RUN": "lightning-mode-\(UUID())",
            "WINNOW_E2E_NETWORK": "regtest",
            "WINNOW_E2E_ENTROPY": String(repeating: "00", count: 16),
        ]) else { return XCTFail("E2E mode should resolve") }
        defer { e2e.defaults.removePersistentDomain(forName: e2e.defaultsSuiteName) }
        func reopen() -> AppModel {
            AppModel(deviceAuthenticator: SilentAuthenticator(), e2e: e2e,
                     storeKeys: InMemoryStoreKeyVault(), keyStore: InMemoryKeyStore())
        }
        let model = reopen()
        XCTAssertNotNil(model.lightning)
        XCTAssertTrue(model.advancedMode, "a fresh Lightning install shows its tab")
        model.setAdvancedMode(false)
        XCTAssertFalse(reopen().advancedMode, "Lightning must respect a persisted false")
        model.setAdvancedMode(true)
        XCTAssertTrue(reopen().advancedMode)
    }

    func testEveryNetworkHasItsOwnController() {
        let model = makeModel(network: .signet)
        XCTAssertEqual(model.lightning?.network, .signet)
        XCTAssertEqual(Set(model.lightningControllers.keys), Set(BitcoinNetwork.allCases))
        XCTAssertEqual(Set(model.lightningControllers.values.map(ObjectIdentifier.init)).count,
                       BitcoinNetwork.allCases.count)
    }

    func testLightningWalletCannotBeDeleted() async throws {
        let model = makeModel(network: .regtest)
        do { try await model.destroyWallet(); XCTFail("deleted a wallet whose channels may need it") }
        catch AppModel.AppError.storageDamaged {}
    }

    func testInterruptedRecoveryAddsMissingVaultAndPreservesCurrentPendingSpend() async throws {
        let fixture = try await spendFixture(), missing = try missingRecoveryRecord()
        _ = try await fixture.store.recordSpend(id: fixture.record.id, transaction: fixture.transaction,
                                               changeScriptPubKey: fixture.change, changeIndex: 0)
        let current = await fixture.store.all
        try await fixture.store.mergeMissingRecoveryRecords([fixture.record, missing])
        let merged = await fixture.store.all
        XCTAssertEqual(merged, current + [missing], "old backup must not release pending coins or rewind current indices")
        let bytes = try Data(contentsOf: fixture.url)
        try await fixture.store.mergeMissingRecoveryRecords([fixture.record, missing])
        XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
        let restarted = VaultStore(keys: fixture.keys)
        let opened = await restarted.configure(storageURL: fixture.url, network: .signet)
        XCTAssertEqual(opened, .loaded)
        let persisted = await restarted.all
        XCTAssertEqual(persisted, merged)
    }

    func testRecoveryVaultMergeRejectsInvalidOwnershipDuplicateOutpointsAndFailedWrite() async throws {
        let writer = VaultWriter(), fixture = try await spendFixture(writer: writer)
        let missing = try missingRecoveryRecord(), originalBytes = try Data(contentsOf: fixture.url)
        var invalid = missing
        invalid.allUtxos[0].scriptPubKey = fixture.record.allUtxos[0].scriptPubKey
        do { try await fixture.store.mergeMissingRecoveryRecords([invalid]); XCTFail("foreign recovered output accepted") }
        catch VaultStorageError.invalidState {}
        var conflict = missing
        conflict.allUtxos[0].txid = fixture.record.allUtxos[0].txid
        do { try await fixture.store.mergeMissingRecoveryRecords([conflict]); XCTFail("merged records repeated a funding outpoint") }
        catch VaultStorageError.invalidState {}
        writer.failWrites(true)
        do { try await fixture.store.mergeMissingRecoveryRecords([missing]); XCTFail("failed write installed recovered vault") }
        catch VaultWriteFailure.expected {}
        let unchanged = await fixture.store.all
        XCTAssertEqual(unchanged, [fixture.record])
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalBytes)
    }

    private struct SpendFixture {
        let keys: InMemoryStoreKeyVault
        let store: VaultStore
        let record: VaultRecord
        let transaction: Transaction
        let change: Data
        let url: URL
    }

    /// A shared account whose one coin a signed, still-pending spend reserves.
    private func spendFixture(writer: VaultWriter? = nil) async throws -> SpendFixture {
        let url = tempFileURL("vault-spend.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (vault, masters) = try TestVaults.multiAVault()
        let coin = try TestVaults.funding(vault: vault, amount: 80_000)
        let descriptor = vault.descriptor.serialized()
        let record = VaultRecord(id: String(descriptor.split(separator: "#").last!), name: "Shared savings",
                                 descriptor: descriptor, createdAtHeight: 90, nextReceiveIndex: 1, allUtxos: [coin])
        let change = try vault.scriptPubKey(index: 0, choice: AddressChain.change.rawValue)
        let coordinates = [Vault.OutputCoordinate(choice: AddressChain.change.rawValue, index: 0)]
        var proposal = try vault.createSpend(utxos: [coin],
                                             payments: [.init(amount: 10_000, scriptPubKey: Data([0x51, 32]) + Data(repeating: 3, count: 32))],
                                             changeIndex: 0, feeRateSatPerVByte: 1, chainTip: 200, randomness: { 0.5 })
        for master in masters.prefix(2) {
            try vault.partialSign(&proposal, master: master, knownUTXOs: [coin], ownedOutputCoordinates: coordinates, chainTip: 200)
        }
        let transaction = try vault.finalizeSpend(&proposal, knownUTXOs: [coin], ownedOutputCoordinates: coordinates, chainTip: 200)
        let keys = InMemoryStoreKeyVault()
        let store = VaultStore(keys: keys, writeData: { data, url in
            if let writer {
                try writer.write(data, to: url)
            } else {
                try data.write(to: url, options: .atomic)
            }
        })
        await store.configure(storageURL: url, network: .signet)
        try await store.restore([record])
        return SpendFixture(keys: keys, store: store, record: record, transaction: transaction, change: change, url: url)
    }

    /// An account the device lacks, as a recovery file would carry it.
    private func missingRecoveryRecord() throws -> VaultRecord {
        let (vault, _) = try TestVaults.multiAVault(threshold: 3)
        var coin = try TestVaults.funding(vault: vault, amount: 50_000)
        coin.txid = Data(repeating: 0x66, count: 32)
        let descriptor = vault.descriptor.serialized()
        return VaultRecord(id: String(descriptor.split(separator: "#").last!), name: "Recovered account",
                           descriptor: descriptor, createdAtHeight: 70, nextReceiveIndex: 1, allUtxos: [coin])
    }
}

private enum VaultWriteFailure: Error {
    case expected
}

private final class VaultWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false

    func failWrites(_ value: Bool) {
        lock.withLock { failing = value }
    }

    func write(_ data: Data, to url: URL) throws {
        if lock.withLock({ failing }) { throw VaultWriteFailure.expected }
        try data.write(to: url, options: .atomic)
    }
}
