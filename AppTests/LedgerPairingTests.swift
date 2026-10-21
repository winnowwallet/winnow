@testable import WinnowApp
import TestSupport
import WalletCore
import XCTest

/// A Ledger as the second signer, through the app model and the device
/// simulator: Advanced mode only, the stored registration, the address check
/// on the device, a spend both sign, and a refusal on the device.
@MainActor
final class LedgerPairingTests: XCTestCase {
    struct SimulatorConnector: LedgerConnector {
        let simulator: LedgerSimulator
        func connect() async throws -> any LedgerSession { SimulatorSession(simulator: simulator) }
    }

    struct SimulatorSession: LedgerSession {
        let simulator: LedgerSimulator
        func exchange(_ apdu: Data) async throws -> Data { try await simulator.exchange(apdu) }
        func close() async {}
    }

    private func readyModel(advanced: Bool) async throws -> AppModel {
        let environment = [
            "WINNOW_E2E": "1",
            "WINNOW_E2E_RUN": "ledger-\(UUID().uuidString)",
            "WINNOW_E2E_ENTROPY": String(repeating: "a1", count: 16),
            "WINNOW_E2E_PEER": "127.0.0.1:1",
            "WINNOW_E2E_CHALLENGE": "51",
            "WINNOW_E2E_ADVANCED": advanced ? "1" : "0",
        ]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else {
            XCTFail("could not create an isolated wallet fixture")
            throw CancellationError()
        }
        let model = AppModel(deviceAuthenticator: SilentAuthenticator(), e2e: mode, storeKeys: InMemoryStoreKeyVault(),
                             keyStore: InMemoryKeyStore())
        addTeardownBlock {
            await model.scenePhaseChanged(.background)
            cleanup.wipeIfRequested()
        }
        let directory = try XCTUnwrap(model.storageDirectory())
        _ = try Wallet.create(network: .signet, keyStore: model.keyStore,
                              storageURL: directory.appending(path: "wallet.json"), entropy: mode.entropy)
        await model.boot()
        XCTAssertEqual(model.stage, .ready)
        XCTAssertEqual(model.advancedMode, advanced)
        return model
    }

    func testLedgerSigningIsAdvancedModeOnly() async throws {
        let model = try await readyModel(advanced: false)
        model.ledgerConnector = SimulatorConnector(simulator: LedgerSimulator(master: try TestKeys.masters()[1]))
        do {
            try await model.pairLedger(name: "Phone and Ledger")
            XCTFail("paired a Ledger in Simple mode")
        } catch {
            XCTAssertEqual(error as? AppModel.LedgerActionError, .advancedModeOnly)
        }
        XCTAssertTrue(model.multisigAccounts.isEmpty)
    }

    func testPairVerifyAndSpendWithBothSigners() async throws {
        let model = try await readyModel(advanced: true)
        let simulator = LedgerSimulator(master: try TestKeys.masters()[1])
        model.ledgerConnector = SimulatorConnector(simulator: simulator)

        var record = try await model.pairLedger(name: "Phone and Ledger")
        let account = try model.multisigAccount(for: record)
        XCTAssertEqual(account.threshold, 2)
        XCTAssertEqual(account.signers.count, 2)
        let registration = try XCTUnwrap(record.ledger)
        XCTAssertEqual(registration.masterFingerprint, try TestKeys.masters()[1].fingerprint)
        XCTAssertEqual(registration.keyPath, LedgerMultisig.keyPath(network: .signet))
        let names = await simulator.registeredNames
        XCTAssertEqual(names, ["Phone and Ledger"])

        // Pairing again refiles the same account rather than adding a copy.
        let again = try await model.pairLedger(name: "Phone and Ledger")
        XCTAssertEqual(again.id, record.id)
        XCTAssertEqual(model.multisigAccounts.count, 1)

        let shown = try await model.verifyLedgerAddress(record: record, index: 0)
        XCTAssertEqual(shown, try account.address(index: 0))
        let displayed = await simulator.displayedAddresses
        XCTAssertEqual(displayed, [shown])

        // Fund the account, then spend: the phone and the Ledger each sign.
        let height = record.createdAtHeight + 1
        let coinbase = Transaction(version: 1, inputs: [coinbaseInput()],
                                   outputs: [.init(value: 50, scriptPubKey: Data([0x51]))], locktime: height)
        let funding = Transaction(
            version: 2,
            inputs: [.init(previousOutput: Transaction.Outpoint(txid: Data(repeating: 0x33, count: 32), vout: 0),
                           scriptSig: Data(), sequence: 0xFFFF_FFFD)],
            outputs: [.init(value: 60_000, scriptPubKey: try account.scriptPubKey(index: 0))], locktime: 0)
        try await model.multisigStore.apply(match: fakeMatch(height: height, transactions: [coinbase, funding]),
                                            network: .signet)
        await model.refresh()
        record = try XCTUnwrap(model.multisigAccounts.first { $0.id == record.id })
        XCTAssertEqual(record.balance, 60_000)

        let destination = try Descriptor("tr(\(try TestKeys.keyExpression(master: TestKeys.masters()[2])))")
            .derived(index: 0, bitcoinNetwork: .signet)[0].address
        var psbt = try await model.createMultisigSpend(record: record, address: destination, amount: 40_000,
                                                       feeRateSatPerVByte: 2)
        psbt = try await model.signMultisigSpendWithLedger(psbt, record: record)
        XCTAssertEqual(model.multisigApprovals(psbt, record: record).count, 1)
        psbt = try await model.signMultisigSpend(psbt, record: record)
        XCTAssertEqual(model.multisigApprovals(psbt, record: record).count, 2)
        var finalized = psbt
        let transaction = try account.finalizeSpend(&finalized, knownUTXOs: record.utxos,
                                                    ownedOutputCoordinates: model.multisigOwnedCoordinates(for: record),
                                                    chainTip: height)
        XCTAssertEqual(transaction.inputs.count, 1)

        // A refusal on the Ledger reaches the user as that, and signs nothing.
        await simulator.setDecision(.reject)
        let unsigned = try await model.createMultisigSpend(record: record, address: destination, amount: 40_000,
                                                           feeRateSatPerVByte: 2)
        do {
            _ = try await model.signMultisigSpendWithLedger(unsigned, record: record)
            XCTFail("a refused signature was accepted")
        } catch {
            XCTAssertEqual(error as? LedgerError, .rejectedOnDevice)
        }
    }

    func testStoreRefusesARegistrationForAnotherAccount() async throws {
        let model = try await readyModel(advanced: true)
        model.ledgerConnector = SimulatorConnector(simulator: LedgerSimulator(master: try TestKeys.masters()[1]))
        let record = try await model.pairLedger(name: "Phone and Ledger")
        var forged = try XCTUnwrap(record.ledger)
        forged.policyID = Data(repeating: 0x11, count: 32)
        do {
            try await model.multisigStore.setLedger(id: record.id, registration: forged)
            XCTFail("a registration for another policy was filed")
        } catch {}
        var tampered = record
        tampered.ledger = forged
        XCTAssertThrowsError(try MultisigStore.validate([tampered], network: .signet))
        XCTAssertNoThrow(try MultisigStore.validate([record], network: .signet))
    }
}
