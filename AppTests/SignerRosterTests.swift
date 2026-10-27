@testable import WinnowApp
import TestSupport
import WalletCore
import XCTest

/// The signer list under Settings → Signers, through the app model: a paired
/// Ledger and saved keys, what the list refuses, the sealed file it keeps,
/// and the builder taking its members from it, a whole account among them.
/// Advanced mode only.
@MainActor
final class SignerRosterTests: XCTestCase {
    func testPairedLedgerAndSavedKeysPersistAndRefuseDuplicates() async throws {
        let model = try await readyMultisigModel(advanced: true)
        let masters = try TestKeys.masters()
        model.ledgerConnector = LedgerPairingTests.SimulatorConnector(simulator: LedgerSimulator(master: masters[1]))
        let ledger = try await model.pairLedger(name: "Nano X")
        XCTAssertTrue(ledger.isLedger)
        XCTAssertEqual(ledger.keys.count, 1)
        XCTAssertEqual(SignerLabel.keysText(ledger, network: .signet), String(format: "%08x", try masters[1].fingerprint))

        // Bob's phone and Ledger, sent together, are one signer.
        let bobPhone = try TestKeys.keyExpression(master: masters[2])
        let bobLedger = try TestKeys.keyExpression(master: TestKeys.master(entropyByte: 0xD4))
        let bob = try await model.addSignerKeys(name: "Bob", text: " \(bobPhone)\n\(bobLedger) ")
        XCTAssertEqual(bob.keys, [bobPhone, bobLedger])
        XCTAssertFalse(bob.isLedger)
        XCTAssertEqual(model.signers.map(\.name), ["Nano X", "Bob"])

        // A key already held, this phone's own key, a mainnet key and text
        // that is no key are refused; the Ledger's key cannot be saved twice.
        do {
            _ = try await model.addSignerKeys(name: "Bob again", text: bobLedger)
            XCTFail("saved a key twice")
        } catch {
            XCTAssertEqual(error as? SignerStorageError, .duplicate(existingName: "Bob"))
        }
        do {
            _ = try await model.addSignerKeys(name: "Me", text: ledger.keys[0])
            XCTFail("saved the Ledger's key again")
        } catch {
            XCTAssertEqual(error as? SignerStorageError, .duplicate(existingName: "Nano X"))
        }
        for text in ["tpubnonsense", bobPhone.replacingOccurrences(of: "tpub", with: "xpub"), "sortedmulti_a(2,\(bobPhone))"] {
            do {
                _ = try await model.addSignerKeys(name: "Nobody", text: text)
                XCTFail("saved \(text.prefix(20)) as a signer")
            } catch {
                guard case MultisigAccountError.invalidDescriptor = error else { return XCTFail("unexpected \(error)") }
            }
        }
        XCTAssertEqual(model.signers.count, 2)

        // Renamed, written sealed, and read back from disk.
        try await model.renameSigner(id: bob.id, name: "Bob and his Ledger")
        await model.configureSigners()
        XCTAssertNil(model.signerStorageNotice)
        XCTAssertEqual(model.signers.map(\.name), ["Nano X", "Bob and his Ledger"])
        XCTAssertEqual(model.signers.last?.keys, [bobPhone, bobLedger])

        // An unsealed file put there by something else is refused, and the
        // list stays empty rather than trusting it.
        let url = try XCTUnwrap(model.storageDirectory()).appending(path: "signers.json")
        let planted = try JSONEncoder().encode(model.signers)
        try planted.write(to: url)
        await model.configureSigners()
        XCTAssertNotNil(model.signerStorageNotice)
        XCTAssertTrue(model.signers.isEmpty)
        do {
            _ = try await model.addSignerKeys(name: "Carol", text: bobPhone)
            XCTFail("changed a damaged list")
        } catch {
            XCTAssertEqual(error as? SignerStorageError, .damaged)
        }
    }

    func testBuilderTakesMembersFromTheListAndAWholeAccountAsOne() async throws {
        let model = try await readyMultisigModel(advanced: true)
        let masters = try TestKeys.masters()
        let nanoX = LedgerSimulator(master: masters[1])
        model.ledgerConnector = LedgerPairingTests.SimulatorConnector(simulator: nanoX)
        let ledger = try await model.pairLedger(name: "Nano X")
        let phone = try model.multisigKeyExpression()
        let bob = try await model.addSignerKeys(
            name: "Bob", text: try TestKeys.keyExpression(master: masters[2]) + " "
                + TestKeys.keyExpression(master: TestKeys.master(entropyByte: 0xD4)))
        let carolMaster = try TestKeys.master(entropyByte: 0xE5)
        let carol = try await model.addSignerKeys(name: "Carol", text: try TestKeys.keyExpression(master: carolMaster))

        // The household: this phone and its Ledger, 2-of-2, which the Ledger approves.
        var household = try await model.createMultisigAccount(name: "Household", threshold: 2,
                                                              members: [[phone], ledger.keys], recovery: nil)
        let approvedHousehold = try await model.registerPairedLedger(record: household)
        household = try XCTUnwrap(approvedHousehold)
        let householdAccount = try model.multisigAccount(for: household)
        XCTAssertEqual(MultisigBuildView.previewText(householdAccount), "2 of 2: any 2 of the 2 keys sign a spend.")
        XCTAssertEqual(Set(householdAccount.signerExpressions), Set([phone] + ledger.keys))

        // The household's keys as one member of a 2-of-3 with Bob and Carol,
        // as the picker offers an account whose keys all sign.
        let nested = try await model.createMultisigAccount(
            name: "Three households", threshold: 2,
            members: [householdAccount.signerExpressions, bob.keys, carol.keys], recovery: nil)
        let account = try model.multisigAccount(for: nested)
        XCTAssertEqual(account.policySummary, "2 of 3 members")
        XCTAssertEqual(account.members?.groups.map(\.count).sorted(), [1, 2, 2])
        XCTAssertEqual(MultisigBuildView.previewText(account),
                       "2 of 3 members: 3 ways to spend, each needing every key it lists, up to 4 keys. A member short of the keys it needs cannot help.")
        let approvedNested = try await model.registerPairedLedger(record: nested)
        let registered = try XCTUnwrap(approvedNested)
        XCTAssertEqual(registered.ledger?.masterFingerprint, try masters[1].fingerprint)
        let names = await nanoX.registeredNames
        XCTAssertEqual(names, ["Household", "Three households"])
        let labels = model.signerNames(for: registered)
        XCTAssertEqual(labels[try masters[1].fingerprint], "Nano X")
        XCTAssertEqual(labels[try masters[2].fingerprint], "Bob")
        XCTAssertEqual(labels[try carolMaster.fingerprint], "Carol")

        // A second Ledger of this phone in the same account is refused: one registration per account.
        model.ledgerConnector = LedgerPairingTests.SimulatorConnector(
            simulator: LedgerSimulator(master: try TestKeys.master(entropyByte: 0xE6)))
        let nanoS = try await model.pairLedger(name: "Nano S")
        XCTAssertEqual(model.signers.filter(\.isLedger).map(\.name), ["Nano X", "Nano S"])
        do {
            _ = try await model.createMultisigAccount(name: "Two Ledgers", threshold: 2,
                                                      members: [[phone], ledger.keys, nanoS.keys], recovery: nil)
            XCTFail("built an account with two of this phone's Ledgers")
        } catch {
            XCTAssertEqual(error as? AppModel.LedgerActionError, .oneLedgerPerAccount)
        }
        // A Ledger in the account wants a name it can show.
        do {
            _ = try await model.createMultisigAccount(name: "Ménage à trois", threshold: 2,
                                                      members: [[phone], ledger.keys, carol.keys], recovery: nil)
            XCTFail("built a Ledger account under a name the Ledger cannot show")
        } catch {
            XCTAssertEqual(error as? AppModel.LedgerActionError, .invalidName)
        }
        XCTAssertEqual(model.multisigAccounts.count, 2)
    }

    func testCloudContextCarriesTheListAndMergesOnRestore() async throws {
        let masters = try TestKeys.masters()
        let store = SignerStore(keys: InMemoryStoreKeyVault())
        _ = await store.configure(storageURL: nil, network: .signet)
        let local = try await store.addKeys(name: "Bob", keys: [try TestKeys.keyExpression(master: masters[2])])
        let incoming: SignerStore.Backup = [
            SignerRecord(id: "other-bob", kind: .keys, name: "Bob elsewhere",
                         keys: [try TestKeys.keyExpression(master: masters[2])], masterFingerprint: nil, addedAt: Date()),
            SignerRecord(id: "carol", kind: .keys, name: "Carol",
                         keys: [try TestKeys.keyExpression(master: TestKeys.master(entropyByte: 0xE5))],
                         masterFingerprint: nil, addedAt: Date()),
        ]
        // The record already here stays; a restored record holding the same
        // key under another id is dropped; a new one is added.
        let merged = try await store.planRestore(incoming)
        XCTAssertEqual(merged.map(\.name), ["Bob", "Carol"])
        try await store.restore(merged)
        let all = await store.all
        XCTAssertEqual(all.map(\.id), [local.id, "carol"])

        // A Ledger record must carry its own key at the Ledger's path.
        let fake = SignerRecord(id: "fake", kind: .ledger, name: "Not a Ledger",
                                keys: [try TestKeys.keyExpression(master: masters[1])],
                                masterFingerprint: try masters[1].fingerprint, addedAt: Date())
        XCTAssertThrowsError(try SignerStore.validateBackup([fake], network: .signet))
    }
}
