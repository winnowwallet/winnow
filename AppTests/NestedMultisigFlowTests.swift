@testable import WinnowApp
import TestSupport
import WalletCore
import XCTest

/// A nested account through two phones, each with its own Ledger (the device
/// simulator), and a third member with one key: phone A builds it counting
/// its Ledger as one signer, phone B joins with the descriptor and registers
/// its Ledger, both fund it, and the spend finishes only once two whole
/// members have signed. Advanced mode only.
@MainActor
final class NestedMultisigFlowTests: XCTestCase {
    func testTwoPhonesWithLedgersAndAThirdMember() async throws {
        let phoneA = try await readyMultisigModel(advanced: true)
        let phoneB = try await readyMultisigModel(advanced: true, entropyByte: 0xC3)
        let ledgerA = LedgerSimulator(master: try TestKeys.master(entropyByte: 0xB2))
        let ledgerB = LedgerSimulator(master: try TestKeys.master(entropyByte: 0xD5))
        phoneA.ledgerConnector = LedgerPairingTests.SimulatorConnector(simulator: ledgerA)
        phoneB.ledgerConnector = LedgerPairingTests.SimulatorConnector(simulator: ledgerB)
        let third = try TestKeys.master(entropyByte: 0xD4)

        // Phone B's share is its key and its Ledger's, together.
        let shareB = [try phoneB.multisigKeyExpression(), try await phoneB.ledgerKeyExpression()]
        let created = try await phoneA.createMultisigAccount(
            name: "Three households", threshold: 2,
            otherMembers: [shareB, [try TestKeys.keyExpression(master: third)]],
            includeLedger: true, ledgerWithPhone: true, recovery: nil)
        let account = try phoneA.multisigAccount(for: created)
        XCTAssertTrue(account.isNested)
        XCTAssertEqual(account.policySummary, "2 of 3 members")
        XCTAssertEqual(account.members?.groups.map(\.count).sorted(), [1, 2, 2])
        XCTAssertNotNil(created.ledger)
        let namesA = await ledgerA.registeredNames
        XCTAssertEqual(namesA, ["Three households"])
        let members = try XCTUnwrap(account.members)
        let own = try XCTUnwrap(members.groups.first { group in
            group.contains { key in
                if case let .extended(xpub, _) = key.base { return xpub.publicKey == phoneA.multisigOwnAccountKey }
                return false
            }
        })
        XCTAssertTrue(MultisigAccountView.groupText(own, ownKey: phoneA.multisigOwnAccountKey,
                                                    ledger: created.ledger?.masterFingerprint)
            .contains("(this phone)"))
        XCTAssertTrue(MultisigAccountView.groupText(own, ownKey: phoneA.multisigOwnAccountKey,
                                                    ledger: created.ledger?.masterFingerprint)
            .contains("(Ledger)"))

        // Phone B joins with the descriptor and registers its own Ledger.
        var joined = try await phoneB.addMultisigAccount(name: "Three households", descriptor: created.descriptor)
        XCTAssertNil(joined.ledger)
        XCTAssertTrue(LedgerMultisig.namesALedgerKey(account))
        joined = try await phoneB.registerLedger(record: joined)
        XCTAssertEqual(joined.ledger?.masterFingerprint, try TestKeys.master(entropyByte: 0xD5).fingerprint)
        let namesB = await ledgerB.registeredNames
        XCTAssertEqual(namesB, ["Three households"])
        XCTAssertEqual(try phoneB.multisigAccount(for: joined).address(index: 0), try account.address(index: 0))

        // The same coin reaches both phones.
        let height = created.createdAtHeight + 1
        let coinbase = Transaction(version: 1, inputs: [coinbaseInput()],
                                   outputs: [.init(value: 50, scriptPubKey: Data([0x51]))], locktime: height)
        let funding = Transaction(
            version: 2,
            inputs: [.init(previousOutput: Transaction.Outpoint(txid: Data(repeating: 0x36, count: 32), vout: 0),
                           scriptSig: Data(), sequence: 0xFFFF_FFFD)],
            outputs: [.init(value: 80_000, scriptPubKey: try account.scriptPubKey(index: 0))], locktime: 0)
        for model in [phoneA, phoneB] {
            try await model.multisigStore.apply(match: fakeMatch(height: height, transactions: [coinbase, funding]),
                                                network: .signet)
            await model.refresh()
        }
        let recordA = try XCTUnwrap(phoneA.multisigAccounts.first { $0.id == created.id })
        let recordB = try XCTUnwrap(phoneB.multisigAccounts.first { $0.id == created.id })
        XCTAssertEqual(recordA.balance, 80_000)

        // Phone A creates the spend: three groups could finish it, none has.
        let destination = try Descriptor("tr(\(try TestKeys.keyExpression(master: third)))")
            .derived(index: 1, bitcoinNetwork: .signet)[0].address
        var psbt = try await phoneA.createMultisigSpend(record: recordA, address: destination, amount: 50_000,
                                                        feeRateSatPerVByte: 2)
        var screen = try phoneA.multisigSigningScreen(psbt, record: recordA)
        XCTAssertEqual(screen.paths.count, 3)
        XCTAssertEqual(screen.paths, account.signersPaths)
        XCTAssertEqual(screen.progress, MultisigSigningProgress(phoneHolds: true, phoneUnsigned: true, ledgerHolds: true,
                                                                ledgerUnsigned: true))
        // Household A signs with both devices: one member, nothing finishes.
        psbt = try await phoneA.signMultisigSpend(psbt, record: recordA)
        psbt = try await phoneA.signMultisigSpendWithLedger(psbt, record: recordA)
        screen = try phoneA.multisigSigningScreen(psbt, record: recordA)
        XCTAssertFalse(screen.progress.complete || screen.progress.phoneUnsigned || screen.progress.ledgerUnsigned)
        XCTAssertTrue(screen.progress.nextStep.hasPrefix("Share the PSBT"))
        // Household B signs its copy with both devices; A combines it.
        var copy = try await phoneB.signMultisigSpend(psbt, record: recordB)
        copy = try await phoneB.signMultisigSpendWithLedger(copy, record: recordB)
        let combined = try phoneA.combineMultisigSpend(psbt, with: copy, record: recordA)
        screen = try phoneA.multisigSigningScreen(combined, record: recordA)
        XCTAssertTrue(screen.progress.complete)
        let complete = screen.paths.filter { screen.approvals[$0, default: []].count >= account.threshold(on: $0) }
        XCTAssertEqual(complete.count, 1)
        XCTAssertEqual(account.keys(on: try XCTUnwrap(complete.first)).count, 4)
        XCTAssertEqual(MultisigSigningScreen.signaturesTitle(try XCTUnwrap(complete.first), account: account).suffix(10),
                       "signatures")
        var finalized = combined
        let transaction = try account.finalizeSpend(&finalized, knownUTXOs: recordA.utxos,
                                                    ownedOutputCoordinates: phoneA.multisigOwnedCoordinates(for: recordA),
                                                    chainTip: height)
        XCTAssertEqual(transaction.inputs[0].witness.count, 6, "four signatures, the leaf and its control block")
    }

    func testRegisteringAndTheLedgerKeyAreAdvancedModeOnly() async throws {
        let model = try await readyMultisigModel(advanced: false)
        model.ledgerConnector = LedgerPairingTests.SimulatorConnector(
            simulator: LedgerSimulator(master: try TestKeys.master(entropyByte: 0xB2)))
        do {
            _ = try await model.ledgerKeyExpression()
            XCTFail("read a Ledger key in Simple mode")
        } catch {
            XCTAssertEqual(error as? AppModel.LedgerActionError, .advancedModeOnly)
        }
        let record = MultisigAccountRecord(id: "x", name: "Any", descriptor: "", createdAtHeight: 0)
        do {
            _ = try await model.registerLedger(record: record)
            XCTFail("registered in Simple mode")
        } catch {
            XCTAssertEqual(error as? AppModel.LedgerActionError, .advancedModeOnly)
        }
    }
}
