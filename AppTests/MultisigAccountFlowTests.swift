@testable import WinnowApp
import TestSupport
import WalletCore
import XCTest

extension XCTestCase {
    /// A ready phone in an isolated wallet fixture; `entropyByte` picks its
    /// seed, `TestKeys.master(entropyByte:)`'s.
    @MainActor
    func readyMultisigModel(advanced: Bool, entropyByte: UInt8 = 0xA1) async throws -> AppModel {
        let environment = [
            "WINNOW_E2E": "1",
            "WINNOW_E2E_RUN": "multisig-\(UUID().uuidString)",
            "WINNOW_E2E_ENTROPY": String(repeating: String(format: "%02x", entropyByte), count: 16),
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
}

/// Multisig accounts through the app model with no hardware signer: the
/// builder, a co-signer's spend signed on two phones, and the recovery path's
/// age check. Advanced mode only.
@MainActor
final class MultisigAccountFlowTests: XCTestCase {
    func testBuilderMakesAccountWithAnotherWinnowAndRecovery() async throws {
        let model = try await readyMultisigModel(advanced: true)
        let masters = try TestKeys.masters()
        let otherWinnow = try TestKeys.keyExpression(master: masters[2])

        let record = try await model.createMultisigAccount(
            name: "Family 2-of-2", threshold: 2, members: [[try model.multisigKeyExpression()], [" \(otherWinnow) "]],
            recovery: .fewerSigners(threshold: 1, blocks: 4320))
        let account = try model.multisigAccount(for: record)
        XCTAssertEqual(account.threshold, 2)
        XCTAssertEqual(account.signers.count, 2)
        XCTAssertEqual(account.recovery?.blocks, 4320)
        XCTAssertEqual(account.recovery?.threshold, 1)
        // The other Winnow joins with the same descriptor: its key is a signer.
        let joined = try MultisigAccount(record.descriptor, network: .signet)
        XCTAssertTrue(joined.includes(accountKey: try masters[2].derived(path: "m/86'/1'/0'").neutered))
        XCTAssertEqual(try joined.address(index: 0), try account.address(index: 0))
        // The same account with this phone's recovery copy under another fingerprint
        // would leave a signer unable to find its key: joining refuses it (SEC-037).
        let phoneKey = try model.multisigKeyExpression()
        let bare = String(phoneKey.dropLast("/<0;1>/*".count))
        let body = String(record.descriptor.split(separator: "#")[0])
        let relabelled = body.replacingOccurrences(of: bare + "/<2;3>/*", with: "[deadbeef" + bare.dropFirst(9) + "/<2;3>/*")
        XCTAssertNotEqual(relabelled, body)
        do {
            _ = try await model.addMultisigAccount(name: "Relabelled", descriptor: relabelled)
            XCTFail("joined an account whose recovery leaf relabels a signer")
        } catch {
            XCTAssertEqual(error as? MultisigAccountError,
                           .invalidDescriptor("a signer reused for recovery must keep its own fingerprint and path there"))
        }
        XCTAssertEqual(model.multisigAccounts.count, 1)

        // Phone and another Winnow with a separate recovery key.
        let recoveryKey = try TestKeys.keyExpression(master: TestKeys.master(entropyByte: 0xD4))
        let pair = try await model.createMultisigAccount(
            name: "Two phones", threshold: 2, members: [[phoneKey], [otherWinnow]],
            recovery: .separateKeys(threshold: 1, keys: [recoveryKey], blocks: 144))
        XCTAssertEqual(try model.multisigAccount(for: pair).recovery?.keys.count, 1)
        XCTAssertEqual(model.multisigAccounts.count, 2)
    }

    func testTwoPhonesSignACoSignersSpendWithBIP326Sequences() async throws {
        let phone = try await readyMultisigModel(advanced: true)
        let otherPhone = try await readyMultisigModel(advanced: true, entropyByte: 0xC3)
        let recoveryKey = try TestKeys.keyExpression(master: TestKeys.master(entropyByte: 0xD4))
        let created = try await phone.createMultisigAccount(
            name: "Two phones", threshold: 2,
            members: [[try phone.multisigKeyExpression()], [try otherPhone.multisigKeyExpression()]],
            recovery: .separateKeys(threshold: 1, keys: [recoveryKey], blocks: 144))
        _ = try await otherPhone.addMultisigAccount(name: "Two phones", descriptor: created.descriptor)
        let account = try phone.multisigAccount(for: created)

        // Two coins 300 blocks apart reach both phones.
        let height = created.createdAtHeight + 1
        var coins: [Transaction] = []
        for (offset, index) in [(UInt32(0), UInt32(0)), (300, 1)] {
            let funding = Transaction(
                version: 2,
                inputs: [.init(previousOutput: Transaction.Outpoint(txid: Data(repeating: 0x35 + UInt8(index), count: 32),
                                                                    vout: 0), scriptSig: Data(), sequence: 0xFFFF_FFFD)],
                outputs: [.init(value: 60_000, scriptPubKey: try account.scriptPubKey(index: index))], locktime: 0)
            let coinbase = Transaction(version: 1, inputs: [coinbaseInput()],
                                       outputs: [.init(value: 50, scriptPubKey: Data([0x51]))], locktime: height + offset)
            coins.append(funding)
            for model in [phone, otherPhone] {
                try await model.multisigStore.apply(match: fakeMatch(height: height + offset, transactions: [coinbase, funding]),
                                                    network: .signet)
            }
        }
        await phone.refresh()
        await otherPhone.refresh()
        let record = try XCTUnwrap(phone.multisigAccounts.first { $0.id == created.id })
        let otherRecord = try XCTUnwrap(otherPhone.multisigAccounts.first { $0.id == created.id })
        XCTAssertEqual(record.balance, 120_000)

        // A co-signer's wallet builds the spend and, following BIP326, sets each
        // Taproot input's sequence to its coin's confirmations: one meets the
        // 144-block recovery lock, one does not. Both phones take it as the
        // signers' path, sign their own copies and combine them (SEC-035).
        let destination = try Descriptor("tr(\(try TestKeys.keyExpression(master: TestKeys.masters()[1])))")
            .derived(index: 0, bitcoinNetwork: .signet)[0].address
        var proposal = try await phone.createMultisigSpend(record: record, address: destination, amount: 100_000,
                                                           feeRateSatPerVByte: 2)
        for (index, input) in try proposal.unsignedTransaction().inputs.enumerated() {
            proposal.inputs[index].sequence = input.previousOutput.txid == coins[0].txid ? 305 : 5
        }
        for (model, copy) in [(phone, record), (otherPhone, otherRecord)] {
            let screen = try model.multisigSigningScreen(proposal, record: copy)
            XCTAssertEqual(screen.paths, [.signers])
            XCTAssertTrue(screen.progress.phoneUnsigned)
        }
        let mine = try await phone.signMultisigSpend(proposal, record: record)
        let theirs = try await otherPhone.signMultisigSpend(proposal, record: otherRecord)
        var combined = try phone.combineMultisigSpend(mine, with: theirs, record: record)
        XCTAssertTrue(try phone.multisigSigningScreen(combined, record: record).progress.complete)
        let transaction = try account.finalizeSpend(&combined, knownUTXOs: record.utxos,
                                                    ownedOutputCoordinates: phone.multisigOwnedCoordinates(for: record),
                                                    chainTip: height + 304)
        XCTAssertEqual(transaction.inputs.map(\.sequence).sorted(), [5, 305])
    }

    func testRecoveryPathRefusesCoinsThatAreTooYoung() async throws {
        let model = try await readyMultisigModel(advanced: true)
        let record = try await model.createMultisigAccount(
            name: "Two phones", threshold: 2,
            members: [[try model.multisigKeyExpression()], [try TestKeys.keyExpression(master: TestKeys.masters()[2])]],
            recovery: .fewerSigners(threshold: 1, blocks: 1000))
        let account = try model.multisigAccount(for: record)
        let height = record.createdAtHeight + 1
        let coinbase = Transaction(version: 1, inputs: [coinbaseInput()],
                                   outputs: [.init(value: 50, scriptPubKey: Data([0x51]))], locktime: height)
        let funding = Transaction(
            version: 2,
            inputs: [.init(previousOutput: Transaction.Outpoint(txid: Data(repeating: 0x34, count: 32), vout: 0),
                           scriptSig: Data(), sequence: 0xFFFF_FFFD)],
            outputs: [.init(value: 60_000, scriptPubKey: try account.scriptPubKey(index: 0))], locktime: 0)
        try await model.multisigStore.apply(match: fakeMatch(height: height, transactions: [coinbase, funding]),
                                            network: .signet)
        await model.refresh()
        let funded = try XCTUnwrap(model.multisigAccounts.first { $0.id == record.id })
        let destination = try Descriptor("tr(\(try TestKeys.keyExpression(master: TestKeys.masters()[0])))")
            .derived(index: 5, bitcoinNetwork: .signet)[0].address
        do {
            _ = try await model.createMultisigSpend(record: funded, address: destination, amount: 20_000,
                                                    feeRateSatPerVByte: 2, path: .recovery)
            XCTFail("a coin younger than the recovery delay was offered to the recovery path")
        } catch {
            guard case MultisigAccountError.invalidSpend = error else { return XCTFail("unexpected \(error)") }
        }
        // The signers' path spends it at once.
        _ = try await model.createMultisigSpend(record: funded, address: destination, amount: 20_000,
                                                feeRateSatPerVByte: 2)
    }

    // MARK: - One wallet: Send from an account, one Transactions list

    /// Two phones sharing a 2-of-2, each with the account funded by one block.
    private struct TwoPhones {
        var phone: AppModel
        var otherPhone: AppModel
        var id: String
        var account: MultisigAccount
        var funding: Transaction
        var height: UInt32

        @MainActor
        func record(of model: AppModel) throws -> MultisigAccountRecord {
            let found = model.multisigAccounts.first { $0.id == id }
            return try XCTUnwrap(found)
        }
    }

    private func twoPhones() async throws -> TwoPhones {
        let phone = try await readyMultisigModel(advanced: true)
        let otherPhone = try await readyMultisigModel(advanced: true, entropyByte: 0xC3)
        // A broadcast hands the transaction to the stack's broadcaster; no
        // peer answers in this fixture, so it only queues.
        await phone.scenePhaseChanged(.active)
        XCTAssertNotNil(phone.stack)
        let created = try await phone.createMultisigAccount(
            name: "Two phones", threshold: 2,
            members: [[try phone.multisigKeyExpression()], [try otherPhone.multisigKeyExpression()]], recovery: nil)
        _ = try await otherPhone.addMultisigAccount(name: "Two phones", descriptor: created.descriptor)
        let account = try phone.multisigAccount(for: created)
        let height = created.createdAtHeight + 1
        let funding = Transaction(
            version: 2,
            inputs: [.init(previousOutput: Transaction.Outpoint(txid: Data(repeating: 0x45, count: 32), vout: 0),
                           scriptSig: Data(), sequence: 0xFFFF_FFFD)],
            outputs: [.init(value: 60_000, scriptPubKey: try account.scriptPubKey(index: 0))], locktime: 0)
        for model in [phone, otherPhone] {
            try await model.multisigStore.apply(match: block(at: height, [funding]), network: .signet)
            await model.refresh()
        }
        return TwoPhones(phone: phone, otherPhone: otherPhone, id: created.id, account: account,
                         funding: funding, height: height)
    }

    private func block(at height: UInt32, _ transactions: [Transaction]) -> BlockMatch {
        let coinbase = Transaction(version: 1, inputs: [coinbaseInput()],
                                   outputs: [.init(value: 50, scriptPubKey: Data([0x51]))], locktime: height)
        return fakeMatch(height: height, transactions: [coinbase] + transactions)
    }

    private func destination(index: UInt32 = 0) throws -> String {
        try Descriptor("tr(\(try TestKeys.keyExpression(master: TestKeys.masters()[1])))")
            .derived(index: index, bitcoinNetwork: .signet)[0].address
    }

    /// The other phone signs this phone's draft and this phone takes the
    /// signatures back, the way the PSBT text travels between signers.
    private func collectOtherSignature(_ pair: TwoPhones) async throws {
        let draft = try XCTUnwrap(pair.record(of: pair.phone).draft)
        let otherRecord = try pair.record(of: pair.otherPhone)
        try await pair.otherPhone.adoptMultisigDraft(try draft.psbt(), record: otherRecord)
        let adopted = try pair.record(of: pair.otherPhone)
        let theirs = try await pair.otherPhone.signMultisigSpend(try pair.otherPhone.multisigDraft(for: adopted), record: adopted)
        try await pair.otherPhone.updateMultisigDraft(theirs, record: adopted)
        try await pair.phone.adoptMultisigDraft(theirs, record: try pair.record(of: pair.phone))
    }

    /// Send, From: the account. The review is the PSBT this phone built;
    /// "Sign and continue" files it as the draft, which survives a reload and
    /// shows in Transactions; the other phone signs; the broadcast lands in
    /// both phones' lists named with the account, confirms in place, and a
    /// reorg re-pends it.
    func testSendTabSpendsFromAnAccountAcrossTwoPhones() async throws {
        let pair = try await twoPhones()
        let phone = pair.phone
        var record = try pair.record(of: phone)
        XCTAssertEqual(phone.status.accountsBalance, 60_000)
        XCTAssertEqual(phone.status.balance, 0)
        XCTAssertEqual(phone.status.payments.map(\.txid), [pair.funding.txid])
        XCTAssertEqual(phone.status.payments.first?.source, .account(name: "Two phones"))
        XCTAssertEqual(phone.status.payments.first?.entry.received, 60_000)
        XCTAssertEqual(phone.status.payments.first?.entry.height, pair.height)

        let preview = try await phone.previewSend(from: record, destination: try destination(), amount: 25_000,
                                                  priority: .medium, override: nil)
        XCTAssertEqual(preview.account?.name, "Two phones")
        XCTAssertEqual(preview.account?.threshold, 2)
        XCTAssertEqual(preview.account?.signerCount, 2)
        XCTAssertEqual(preview.amountSent, 25_000)
        XCTAssertEqual(preview.inputCount, 1)
        XCTAssertEqual(preview.changeAmount, 60_000 - 25_000 - preview.fee)
        do {
            _ = try await phone.previewSend(from: record, destination: "tsp1qqnonsense", amount: 1_000,
                                            priority: .medium, override: nil)
            XCTFail("paid a silent payment code from an account")
        } catch {
            XCTAssertEqual(error as? AppModel.MultisigActionError, .silentPaymentUnsupported)
        }

        let draft = try await phone.signAndDraftMultisigSpend(preview: preview)
        record = try pair.record(of: phone)
        XCTAssertEqual(record.draft, draft)
        let screen = try phone.multisigSigningScreen(try draft.psbt(), record: record)
        XCTAssertEqual(screen.approvals[.signers]?.count, 1)
        XCTAssertTrue(screen.progress.signedHere)
        let row = try XCTUnwrap(phone.status.payments.first)
        XCTAssertTrue(row.isDraft)
        XCTAssertEqual(row.source, .draft(name: "Two phones", signatures: "1 of 2"))
        XCTAssertEqual(row.txid, try draft.txid())
        XCTAssertEqual(row.entry.spent, 60_000)
        XCTAssertEqual(row.entry.received, 60_000 - 25_000 - preview.fee)
        XCTAssertEqual(row.entry.fee, preview.fee)
        XCTAssertEqual(phone.paymentRecipients(row.entry).map(\.amount), [25_000])
        await phone.configureMultisig()
        await phone.refresh()
        XCTAssertEqual(try pair.record(of: phone).draft, draft, "the draft survives a reload")
        do {
            _ = try await phone.previewSend(from: try pair.record(of: phone), destination: try destination(),
                                            amount: 1_000, priority: .medium, override: nil)
            XCTFail("a second spend was built while a draft stands")
        } catch {
            XCTAssertEqual(error as? AppModel.MultisigActionError, .draftInProgress)
        }

        // Another payment's PSBT cannot be combined into the draft.
        let otherRecord = try pair.record(of: pair.otherPhone)
        let different = try await pair.otherPhone.createMultisigSpend(record: otherRecord, address: try destination(index: 1),
                                                                      amount: 1_000, feeRateSatPerVByte: 1)
        do {
            try await phone.adoptMultisigDraft(different, record: try pair.record(of: phone))
            XCTFail("combined a different payment into the draft")
        } catch {
            XCTAssertEqual(error as? AppModel.MultisigActionError, .draftMismatch)
        }

        try await collectOtherSignature(pair)
        record = try pair.record(of: phone)
        XCTAssertTrue(try phone.multisigSigningScreen(try phone.multisigDraft(for: record), record: record).progress.complete)
        let txid = try await phone.broadcastMultisigDraft(record: record)
        XCTAssertEqual(txid, try draft.txid())
        record = try pair.record(of: phone)
        XCTAssertNil(record.draft)
        XCTAssertEqual(record.inFlight.map(\.txid), [txid])
        let pending = try XCTUnwrap(phone.status.payments.first)
        XCTAssertEqual(pending.source, .account(name: "Two phones"))
        XCTAssertEqual(pending.entry.height, 0)
        XCTAssertEqual(pending.entry.fee, preview.fee)
        XCTAssertEqual(phone.status.accountsBalance, 60_000 - 25_000 - preview.fee)

        // It confirms on both phones: in place here, as the account's spend there.
        let spend = try XCTUnwrap(record.inFlight.first).transaction()
        for model in [phone, pair.otherPhone] {
            try await model.multisigStore.apply(match: block(at: pair.height + 1, [spend]), network: .signet)
            await model.refresh()
        }
        XCTAssertEqual(phone.status.payments.map(\.txid), [txid, pair.funding.txid])
        XCTAssertEqual(phone.status.payments.first?.entry.height, pair.height + 1)
        XCTAssertEqual(pair.otherPhone.status.payments.first?.source, .account(name: "Two phones"))
        XCTAssertEqual(pair.otherPhone.status.payments.first?.entry.spent, 60_000)
        XCTAssertNil(try pair.record(of: pair.otherPhone).draft, "its draft went with the coin")

        // A reorg below the spend puts it back in flight, bytes still kept.
        try await phone.multisigStore.rollBack(to: pair.height)
        await phone.refresh()
        record = try pair.record(of: phone)
        XCTAssertEqual(phone.status.payments.first?.entry.height, 0)
        XCTAssertEqual(record.inFlight.map(\.txid), [txid])
    }

    /// A payment between the wallet and one of its accounts is one row.
    func testATransferBetweenTheWalletAndAnAccountIsOneRow() async throws {
        let pair = try await twoPhones()
        let phone = pair.phone
        let wallet = try XCTUnwrap(phone.wallet)
        let walletScript = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let walletFunding = Transaction(
            version: 2,
            inputs: [.init(previousOutput: Transaction.Outpoint(txid: Data(repeating: 0x46, count: 32), vout: 0),
                           scriptSig: Data(), sequence: 0xFFFF_FFFD)],
            outputs: [.init(value: 30_000, scriptPubKey: walletScript)], locktime: 0)
        try await wallet.apply(match: block(at: pair.height + 1, [walletFunding]))
        // The wallet pays the account, with change back to itself.
        let change = try await wallet.scriptPubKey(chain: .change, index: 0)
        let transfer = Transaction(
            version: 2,
            inputs: [.init(previousOutput: Transaction.Outpoint(txid: walletFunding.txid, vout: 0),
                           scriptSig: Data(), sequence: 0xFFFF_FFFD)],
            outputs: [.init(value: 20_000, scriptPubKey: try pair.account.scriptPubKey(index: 1)),
                      .init(value: 9_500, scriptPubKey: change)], locktime: 0)
        let match = block(at: pair.height + 2, [transfer])
        try await wallet.apply(match: match)
        try await phone.multisigStore.apply(match: match, network: .signet)
        await phone.refresh()

        XCTAssertEqual(phone.status.balance, 9_500)
        XCTAssertEqual(phone.status.accountsBalance, 80_000)
        XCTAssertEqual(phone.status.payments.map(\.txid), [transfer.txid, walletFunding.txid, pair.funding.txid])
        let moved = phone.status.payments[0]
        XCTAssertEqual(moved.source, .transfer(from: "Wallet", to: "Two phones", amount: 20_000))
        XCTAssertNil(moved.accountID)
        XCTAssertEqual(moved.entry.spent, 30_000)
        XCTAssertEqual(moved.entry.fee, 500)
        XCTAssertEqual(phone.displayedPayment(txid: transfer.txid)?.source, moved.source)
    }

    /// A backup carries a spend no block has taken, with its bytes, so a
    /// restored phone can announce it again; given up on, its coins are the
    /// account's again.
    func testAnInFlightAccountSpendSurvivesABackupAndCanBeRebroadcastOrGivenUp() async throws {
        let pair = try await twoPhones()
        let phone = pair.phone
        let preview = try await phone.previewSend(from: try pair.record(of: phone), destination: try destination(),
                                                  amount: 25_000, priority: .medium, override: nil)
        try await phone.signAndDraftMultisigSpend(preview: preview)
        try await collectOtherSignature(pair)
        let txid = try await phone.broadcastMultisigDraft(record: try pair.record(of: phone))

        let json = try await phone.exportWalletBundle(includeMnemonic: false)
        let bundle = try ImportBundle.decode(json: json)
        let carried = try XCTUnwrap(bundle.vaults?.first)
        XCTAssertEqual(carried.inFlight.map(\.txid), [txid])
        XCTAssertEqual(carried.history.first { $0.txid == txid }?.height, 0)
        XCTAssertEqual(try carried.inFlight[0].transaction().txid, txid)

        try await phone.rebroadcastMultisigSpend(record: try pair.record(of: phone), txid: txid)
        try await phone.abandonMultisigSpend(record: try pair.record(of: phone), txid: txid)
        let record = try pair.record(of: phone)
        XCTAssertEqual(record.inFlight, [])
        XCTAssertEqual(record.balance, 60_000)
        XCTAssertEqual(phone.status.accountsBalance, 60_000)
        XCTAssertEqual(phone.status.payments.map(\.txid), [pair.funding.txid])
        do {
            try await phone.rebroadcastMultisigSpend(record: record, txid: txid)
            XCTFail("announced a spend the account gave up on")
        } catch {
            XCTAssertEqual(error as? AppModel.MultisigActionError, .notInFlight)
        }
    }

    func testBuilderIsAdvancedModeOnly() async throws {
        let model = try await readyMultisigModel(advanced: false)
        do {
            _ = try await model.createMultisigAccount(
                name: "Two phones", threshold: 2,
                members: [[try model.multisigKeyExpression()], [try TestKeys.keyExpression(master: TestKeys.masters()[2])]],
                recovery: nil)
            XCTFail("built a multisig account in Simple mode")
        } catch {
            XCTAssertEqual(error as? AppModel.LedgerActionError, .advancedModeOnly)
        }
    }
}
