@testable import WinnowApp
import TestSupport
import WalletCore
import XCTest

/// A nested account through two phones, each with its own Ledger (the device
/// simulator) paired under Settings → Signers, and a third member with one
/// key: phone A builds it from its signers counting its Ledger with itself,
/// phone B joins with the descriptor and its paired Ledger registers it, both
/// fund it, and the spend finishes only once two whole members have signed.
/// Advanced mode only.
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

        // Each phone pairs its Ledger. Phone B's share is its key and its
        // Ledger's, together, which phone A saves under B's name.
        let pairedA = try await phoneA.pairLedger(name: "Ledger A")
        let pairedB = try await phoneB.pairLedger(name: "Ledger B")
        let shareB = try phoneB.multisigKeyExpression() + "\n" + pairedB.keys[0]
        let savedB = try await phoneA.addSignerKeys(name: "Household B", text: shareB)
        XCTAssertEqual(savedB.keys.count, 2)
        let savedThird = try await phoneA.addSignerKeys(name: "Carol", text: try TestKeys.keyExpression(master: third))

        var created = try await phoneA.createMultisigAccount(
            name: "Three households", threshold: 2,
            members: [[try phoneA.multisigKeyExpression()] + pairedA.keys, savedB.keys, savedThird.keys], recovery: nil)
        let account = try phoneA.multisigAccount(for: created)
        XCTAssertTrue(account.isNested)
        XCTAssertEqual(account.policySummary, "2 of 3 members")
        XCTAssertEqual(account.members?.groups.map(\.count).sorted(), [1, 2, 2])
        XCTAssertEqual(phoneA.pairedLedgers(in: account).map(\.name), ["Ledger A"])
        XCTAssertNil(created.ledger)
        let approvedA = try await phoneA.registerPairedLedger(record: created)
        created = try XCTUnwrap(approvedA)
        XCTAssertNotNil(created.ledger)
        let namesA = await ledgerA.registeredNames
        XCTAssertEqual(namesA, ["Three households"])
        // The account screen names every key it knows.
        let members = try XCTUnwrap(account.members)
        let names = phoneA.signerNames(for: created)
        let texts = members.groups.map { MultisigAccountView.groupText($0, ownKey: phoneA.multisigOwnAccountKey, names: names) }
        XCTAssertTrue(texts.contains { $0.contains("(this phone)") && $0.contains("(Ledger A)") }, "\(texts)")
        XCTAssertTrue(texts.contains { $0.contains("(Household B)") }, "\(texts)")
        XCTAssertTrue(texts.contains { $0.contains("(Carol)") }, "\(texts)")

        // Phone B joins with the descriptor; its own paired Ledger registers it.
        var joined = try await phoneB.addMultisigAccount(name: "Three households", descriptor: created.descriptor)
        XCTAssertNil(joined.ledger)
        XCTAssertTrue(LedgerMultisig.namesALedgerKey(account))
        let approvedB = try await phoneB.registerPairedLedger(record: joined)
        joined = try XCTUnwrap(approvedB)
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

    /// A 2-of-3 account already on this phone (with Bob's and Carol's saved
    /// keys) is one member of a new account with the phone's paired Ledger
    /// and Dave: the picker offers it with its threshold, the Ledger
    /// registers the seven-leaf policy, and a spend finishes only with two
    /// of the family's three keys plus a whole other member.
    func testAThresholdAccountAsOneMember() async throws {
        let phone = try await readyMultisigModel(advanced: true)
        let masters = try TestKeys.masters()
        let ledger = LedgerSimulator(master: try TestKeys.master(entropyByte: 0xD5))
        phone.ledgerConnector = LedgerPairingTests.SimulatorConnector(simulator: ledger)
        let nanoX = try await phone.pairLedger(name: "Nano X")
        let bob = try await phone.addSignerKeys(name: "Bob", text: try TestKeys.keyExpression(master: masters[1]))
        let carol = try await phone.addSignerKeys(name: "Carol", text: try TestKeys.keyExpression(master: masters[2]))
        let daveMaster = try TestKeys.master(entropyByte: 0xE5)
        let dave = try await phone.addSignerKeys(name: "Dave", text: try TestKeys.keyExpression(master: daveMaster))
        let phoneKey = try phone.multisigKeyExpression()

        // The family: this phone, Bob and Carol, any two. The picker offers
        // it with its threshold; the member row names it so.
        let family = try await phone.createMultisigAccount(name: "Family", threshold: 2,
                                                           members: [[phoneKey], bob.keys, carol.keys], recovery: nil)
        let familyAccount = try phone.multisigAccount(for: family)
        XCTAssertEqual(SignerPickerSheet.accountText(familyAccount, eligible: true), "2 of 3: any 2 of its 3 keys")
        XCTAssertEqual(SignerPickerSheet.accountText(familyAccount, eligible: false), "2 of 3: a member of its own only")
        let member = MultisigBuildView.Member(
            keys: familyAccount.signerExpressions.map { .init(key: $0, label: $0 == phoneKey ? MultisigBuildView.phoneLabel : "Family") },
            name: "Family", threshold: 2)
        XCTAssertEqual(member.title, "Family 2-of-3")
        XCTAssertEqual(member.caption, "any 2 of its 3 keys")
        XCTAssertTrue(member.isThreshold)

        // The estate: the family, the Ledger and Dave, any two members.
        var estate = try await phone.createMultisigAccount(name: "Estate", threshold: 2,
                                                           members: [member.plan, .init(keys: nanoX.keys), .init(keys: dave.keys)],
                                                           recovery: nil)
        let account = try phone.multisigAccount(for: estate)
        XCTAssertTrue(account.isNested)
        XCTAssertEqual(account.signersLeaves.count, 7)
        XCTAssertEqual(account.policySummary, "2 of 3 members, one of them 2 of 3")
        XCTAssertEqual(MultisigBuildView.previewText(account),
                       "2 of 3 members, one of them 2 of 3: 7 ways to spend, each needing every key it lists, up to 3 keys. A member short of the keys it needs cannot help.")
        XCTAssertEqual(SignerPickerSheet.accountText(account, eligible: false),
                       "2 of 3 members, one of them 2 of 3: cannot be one member yet")
        let members = try XCTUnwrap(account.members)
        XCTAssertEqual(members.thresholds.sorted(), [1, 1, 2])
        let names = phone.signerNames(for: estate)
        let texts = members.groups.indices.map {
            MultisigAccountView.memberText(members, $0, ownKey: phone.multisigOwnAccountKey, names: names)
        }
        XCTAssertTrue(texts.contains { $0.hasPrefix("any 2 of: ") && $0.contains("(this phone)") && $0.contains("(Bob)")
            && $0.contains("(Carol)") }, "\(texts)")
        XCTAssertTrue(texts.contains { $0.contains("(Nano X)") && !$0.hasPrefix("any") }, "\(texts)")
        XCTAssertTrue(texts.contains { $0.contains("(Dave)") }, "\(texts)")
        let approved = try await phone.registerPairedLedger(record: estate)
        estate = try XCTUnwrap(approved)
        XCTAssertNotNil(estate.ledger)
        let registered = await ledger.registeredNames
        XCTAssertEqual(registered, ["Estate"])

        // A coin.
        let height = estate.createdAtHeight + 1
        let coinbase = Transaction(version: 1, inputs: [coinbaseInput()],
                                   outputs: [.init(value: 50, scriptPubKey: Data([0x51]))], locktime: height)
        let funding = Transaction(
            version: 2,
            inputs: [.init(previousOutput: Transaction.Outpoint(txid: Data(repeating: 0x37, count: 32), vout: 0),
                           scriptSig: Data(), sequence: 0xFFFF_FFFD)],
            outputs: [.init(value: 80_000, scriptPubKey: try account.scriptPubKey(index: 0))], locktime: 0)
        try await phone.multisigStore.apply(match: fakeMatch(height: height, transactions: [coinbase, funding]), network: .signet)
        await phone.refresh()
        let record = try XCTUnwrap(phone.multisigAccounts.first { $0.id == estate.id })
        XCTAssertEqual(record.balance, 80_000)
        let owned = phone.multisigOwnedCoordinates(for: record)
        let tip = phone.status.tipHeight
        let destination = try Descriptor("tr(\(try TestKeys.keyExpression(master: daveMaster)))")
            .derived(index: 1, bitcoinNetwork: .signet)[0].address

        // This phone (one family key) and the Ledger: the Ledger is a whole
        // member, the family is not yet. Bob makes it one: exactly one leaf
        // finishes, with the phone's, Bob's and the Ledger's signatures.
        var psbt = try await phone.createMultisigSpend(record: record, address: destination, amount: 50_000, feeRateSatPerVByte: 2)
        var screen = try phone.multisigSigningScreen(psbt, record: record)
        XCTAssertEqual(screen.paths.count, 7)
        XCTAssertEqual(screen.progress, MultisigSigningProgress(phoneHolds: true, phoneUnsigned: true, ledgerHolds: true,
                                                                ledgerUnsigned: true))
        psbt = try await phone.signMultisigSpend(psbt, record: record)
        psbt = try await phone.signMultisigSpendWithLedger(psbt, record: record)
        screen = try phone.multisigSigningScreen(psbt, record: record)
        XCTAssertFalse(screen.progress.complete || screen.progress.phoneUnsigned || screen.progress.ledgerUnsigned)
        XCTAssertTrue(screen.progress.nextStep.hasPrefix("Share the PSBT"))
        try account.sign(&psbt, signingKey: masters[1], knownUTXOs: record.utxos, ownedOutputCoordinates: owned, chainTip: tip)
        screen = try phone.multisigSigningScreen(psbt, record: record)
        XCTAssertTrue(screen.progress.complete)
        let complete = screen.paths.filter { screen.approvals[$0, default: []].count >= account.threshold(on: $0) }
        XCTAssertEqual(complete.count, 1)
        XCTAssertEqual(account.keys(on: try XCTUnwrap(complete.first)).count, 3)
        XCTAssertEqual(MultisigSigningScreen.signaturesTitle(try XCTUnwrap(complete.first), account: account).suffix(10), "signatures")
        var finalized = psbt
        let transaction = try account.finalizeSpend(&finalized, knownUTXOs: record.utxos, ownedOutputCoordinates: owned, chainTip: tip)
        XCTAssertEqual(transaction.inputs[0].witness.count, 5, "three signatures, the leaf and its control block")

        // This phone and Dave: one family key and one whole member, nothing;
        // Carol completes the family and the leaf of the phone, Carol and Dave.
        var other = try await phone.createMultisigSpend(record: record, address: destination, amount: 50_000, feeRateSatPerVByte: 2)
        other = try await phone.signMultisigSpend(other, record: record)
        try account.sign(&other, signingKey: daveMaster, knownUTXOs: record.utxos, ownedOutputCoordinates: owned, chainTip: tip)
        XCTAssertFalse(try phone.multisigSigningScreen(other, record: record).progress.complete)
        try account.sign(&other, signingKey: masters[2], knownUTXOs: record.utxos, ownedOutputCoordinates: owned, chainTip: tip)
        screen = try phone.multisigSigningScreen(other, record: record)
        XCTAssertTrue(screen.progress.complete)
        XCTAssertEqual(screen.paths.filter { screen.approvals[$0, default: []].count >= account.threshold(on: $0) }.count, 1)
    }

    func testPairingSavingAndRegisteringAreAdvancedModeOnly() async throws {
        let model = try await readyMultisigModel(advanced: false)
        model.ledgerConnector = LedgerPairingTests.SimulatorConnector(
            simulator: LedgerSimulator(master: try TestKeys.master(entropyByte: 0xB2)))
        do {
            _ = try await model.pairLedger(name: "Nano X")
            XCTFail("paired a Ledger in Simple mode")
        } catch {
            XCTAssertEqual(error as? AppModel.LedgerActionError, .advancedModeOnly)
        }
        do {
            _ = try await model.addSignerKeys(name: "Bob", text: try TestKeys.keyExpression(master: TestKeys.masters()[2]))
            XCTFail("saved a key in Simple mode")
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
        XCTAssertTrue(model.signers.isEmpty)
    }
}
