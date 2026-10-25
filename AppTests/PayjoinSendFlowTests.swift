@testable import WinnowApp
import WalletCore
import TestSupport
import XCTest

/// Paying a BIP 21 request that offers BIP 77 payjoin, the way the app does
/// it: review (with the payjoin envelope on screen), authentication, build,
/// the ordinary gate, the directory round trip through a loopback fake, the
/// proposal gate, signing only our inputs, broadcast and the receipt. The
/// receiver is `FakePayjoinReceiver`, which also plays hostile, slow and
/// silent; every one of those ends with the reviewed original broadcast.
@MainActor
final class PayjoinSendFlowTests: XCTestCase {
    private enum FixtureError: Error { case unavailable }

    private struct Rig {
        var model: AppModel
        var fundings: [Transaction]
        var directory: FakePayjoinDirectory
        var receiver: FakePayjoinReceiver
    }

    /// A booted signet model with one mature coin per entry of `coins`, a
    /// dead peer (so broadcasts queue), direct routing, and a fake directory
    /// the model is pointed at through the E2E control file.
    private func rig(coins: [Int64], name: String) async throws -> Rig {
        let control = FileManager.default.temporaryDirectory.appending(path: "payjoin-\(UUID().uuidString).json")
        let environment = [
            "WINNOW_E2E": "1",
            "WINNOW_E2E_RUN": "\(name)-\(UUID().uuidString)",
            "WINNOW_E2E_ENTROPY": String(repeating: "a1", count: 16),
            "WINNOW_E2E_PEER": "127.0.0.1:1",
            "WINNOW_E2E_CHALLENGE": "51",
            "WINNOW_E2E_CONTROL_FILE": control.path,
        ]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else {
            XCTFail("could not create isolated send fixture")
            throw FixtureError.unavailable
        }
        let directory = try FakePayjoinDirectory(pollTimeout: .milliseconds(200))
        try await directory.start()
        let receiver = try FakePayjoinReceiver(network: .signet, directory: directory)
        receiver.fund(outpoint: Transaction.Outpoint(txid: Data(repeating: 0x5A, count: 32), vout: 1), amount: 40_000)
        try JSONEncoder().encode(["payjoinRelay": await directory.url.absoluteString]).write(to: control, options: .atomic)
        let model = AppModel(e2e: mode, storeKeys: InMemoryStoreKeyVault(), keyStore: InMemoryKeyStore())
        model.payjoinWaitBudget = 8
        addTeardownBlock {
            await model.scenePhaseChanged(.background)
            await directory.stop()
            cleanup.wipeIfRequested()
            try? FileManager.default.removeItem(at: control)
        }
        let storage = try XCTUnwrap(model.storageDirectory())
        let wallet = try Wallet.create(network: .signet, keyStore: model.keyStore,
                                       storageURL: storage.appending(path: "wallet.json"), entropy: mode.entropy)
        var fundings: [Transaction] = []
        for (index, amount) in coins.enumerated() {
            fundings.append(try await fund(wallet, amount: amount, height: 100, index: UInt32(index)))
        }
        try await matureCoinbase(wallet, height: 100)
        await model.boot()
        XCTAssertEqual(model.stage, .ready)
        await model.scenePhaseChanged(.active)
        XCTAssertNotNil(model.stack)
        try await model.setPeerGatewaySettings(.init(mode: .direct))
        return Rig(model: model, fundings: fundings, directory: directory, receiver: receiver)
    }

    private func sentEntry(_ model: AppModel, txid: Data) throws -> HistoryEntry {
        try XCTUnwrap(model.status.history.first { $0.txid == txid })
    }

    /// The whole path with an honest receiver: the review shows the payjoin
    /// envelope, the broadcast transaction has the receiver's input, the
    /// payment and change are as reviewed (change down by at most the
    /// contribution), history records the payjoin and lists only the
    /// reviewed recipient.
    func testPaysAPayjoinRequestWithTheReceiversInput() async throws {
        let rig = try await rig(coins: [200_000], name: "pj-send")
        let uri = await rig.receiver.uri(amountSats: 50_000)
        let preview = try await rig.model.previewSend(destination: uri, amount: 50_000, priority: .medium, override: 2)
        XCTAssertEqual(preview.destination, rig.receiver.address)
        XCTAssertEqual(preview.payments.map(\.amount), [50_000])
        let request = try XCTUnwrap(preview.payjoin, "the review did not take up the payjoin offer")
        XCTAssertEqual(request.parameters.mailboxID, rig.receiver.mailboxID)
        XCTAssertEqual(request.maxFeeContribution, 220, "2 sat/vB × 110 vB")
        XCTAssertNil(preview.payjoinUnavailable)

        let serving = Task { try await rig.receiver.serve(.honest) }
        let txid = try await rig.model.send(preview: preview)
        try await serving.value
        let entry = try sentEntry(rig.model, txid: txid)
        let transaction = try XCTUnwrap(entry.transaction())
        XCTAssertEqual(transaction.inputs.count, 2, "ours and the receiver's")
        XCTAssertTrue(transaction.inputs.contains { $0.previousOutput == rig.receiver.coin?.outpoint })
        let payment = try XCTUnwrap(transaction.outputs.first { $0.scriptPubKey == rig.receiver.paymentScript })
        XCTAssertGreaterThanOrEqual(payment.value, 50_000)
        let change = try XCTUnwrap(preview.change)
        let changeOutput = try XCTUnwrap(transaction.outputs.first { $0.scriptPubKey == change.scriptPubKey })
        XCTAssertGreaterThanOrEqual(changeOutput.value, change.amount - 220)
        XCTAssertLessThan(changeOutput.value, change.amount)
        guard case let .joined(inputs, contribution)? = rig.model.lastPayjoinOutcome else {
            return XCTFail("the receipt does not record a payjoin: \(String(describing: rig.model.lastPayjoinOutcome))")
        }
        XCTAssertEqual(inputs, 1)
        XCTAssertEqual(contribution, change.amount - changeOutput.value)
        XCTAssertEqual(entry.fee, preview.fee + contribution, "history records what we paid")
        // Only the reviewed recipient is listed; the receiver's own output is not.
        let recipients = rig.model.paymentRecipients(entry)
        XCTAssertEqual(recipients.map(\.address), [rig.receiver.address])
        // The receiver saw the original with our parameters and no key material.
        let original = try XCTUnwrap(rig.receiver.receivedOriginal)
        XCTAssertTrue(original.inputs.allSatisfy { $0.isFinalized && !$0.carriesKeyPaths && $0.tapInternalKey == nil })
        XCTAssertEqual(rig.receiver.receivedParameters["disableoutputsubstitution"], "true")
        XCTAssertEqual(rig.receiver.receivedParameters["maxadditionalfeecontribution"], "220")
        // The change coin entered the wallet with its reduced value, and the spent coin left.
        let utxos = await rig.model.wallet?.spendableUtxos ?? []
        XCTAssertEqual(utxos.map(\.amount), [changeOutput.value])
    }

    /// A proposal that reduces the payment fails the checks; the reviewed
    /// original goes out instead, and the receipt says so.
    func testHostileProposalFallsBackToTheOriginal() async throws {
        let rig = try await rig(coins: [200_000], name: "pj-hostile")
        let preview = try await rig.model.previewSend(destination: await rig.receiver.uri(), amount: 50_000,
                                                      priority: .medium, override: 2)
        let serving = Task { try await rig.receiver.serve(.reducePayment) }
        let txid = try await rig.model.send(preview: preview)
        try await serving.value
        let transaction = try XCTUnwrap(sentEntry(rig.model, txid: txid).transaction())
        XCTAssertEqual(transaction.inputs.count, 1)
        XCTAssertEqual(rig.model.lastPayjoinOutcome, .plain(reason: "the receiver's proposal failed review"))
        XCTAssertEqual(transaction.outputs.first { $0.scriptPubKey == rig.receiver.paymentScript }?.value, 50_000)
    }

    /// No answer within the budget: the original is broadcast on its own.
    func testSilentReceiverFallsBackAfterTheWait() async throws {
        let rig = try await rig(coins: [200_000], name: "pj-silent")
        rig.model.payjoinWaitBudget = 1.5
        let preview = try await rig.model.previewSend(destination: await rig.receiver.uri(), amount: 50_000,
                                                      priority: .medium, override: 2)
        let started = Date()
        let txid = try await rig.model.send(preview: preview)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1.4)
        XCTAssertEqual(rig.model.lastPayjoinOutcome, .plain(reason: "the receiver did not answer in time"))
        XCTAssertEqual(try XCTUnwrap(sentEntry(rig.model, txid: txid).transaction()).inputs.count, 1)
        XCTAssertNil(rig.model.payjoinPhase)
    }

    /// "Send without payjoin" ends the wait early.
    func testSkippingTheWaitSendsTheOriginal() async throws {
        let rig = try await rig(coins: [200_000], name: "pj-skip")
        rig.model.payjoinWaitBudget = 30
        let preview = try await rig.model.previewSend(destination: await rig.receiver.uri(), amount: 50_000,
                                                      priority: .medium, override: 2)
        let sending = Task { try await rig.model.send(preview: preview) }
        var waiting = false
        for _ in 0 ..< 200 where !waiting {
            waiting = rig.model.payjoinPhase == .waiting
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(waiting, "the send never reached the waiting phase")
        rig.model.skipPayjoinWait()
        let txid = try await sending.value
        XCTAssertEqual(rig.model.lastPayjoinOutcome, .plain(reason: "you chose not to wait"))
        XCTAssertEqual(try XCTUnwrap(sentEntry(rig.model, txid: txid).transaction()).inputs.count, 1)
    }

    /// A receiver that declines with a BIP 78 error: original broadcast,
    /// receipt shows the well-known code only.
    func testReceiverErrorFallsBack() async throws {
        let rig = try await rig(coins: [200_000], name: "pj-error")
        let preview = try await rig.model.previewSend(destination: await rig.receiver.uri(), amount: 50_000,
                                                      priority: .medium, override: 2)
        let serving = Task { try await rig.receiver.serve(.error("original-psbt-rejected")) }
        _ = try await rig.model.send(preview: preview)
        try await serving.value
        XCTAssertEqual(rig.model.lastPayjoinOutcome, .plain(reason: "the receiver declined (original-psbt-rejected)"))
    }

    /// The request's own rules at review time: a mismatched amount, a silent
    /// payment code with payjoin, and a `req-pj` request with no relay.
    func testRequestRefusals() async throws {
        let rig = try await rig(coins: [200_000], name: "pj-refusals")
        let uri = await rig.receiver.uri(amountSats: 60_000)
        do {
            _ = try await rig.model.previewSend(destination: uri, amount: 50_000, priority: .medium, override: 2)
            XCTFail("a different amount was accepted")
        } catch let error as AppModel.AppError {
            guard case .paymentRequestAmount(sats: 60_000) = error else { return XCTFail("\(error)") }
        }
        let code = try SilentPaymentTestReceiver(network: .signet).code
        let silent = "bitcoin:\(code)?pj=\(await rig.receiver.parameters().queryValue)"
        do {
            _ = try await rig.model.previewSend(destination: silent, amount: 50_000, priority: .medium, override: 2)
            XCTFail("a silent payment code inside a payjoin was accepted")
        } catch let error as AppModel.AppError {
            guard case .payjoinCannotPaySilentPayment = error else { return XCTFail("\(error)") }
        }
        // Without a usable relay a plain offer is declined on the review and
        // a required one refuses the payment.
        rig.model.setPayjoinRelay("ftp://nope")
        try JSONEncoder().encode([String: String]()).write(to: try XCTUnwrap(rig.model.e2e?.controlFile), options: .atomic)
        let declined = try await rig.model.previewSend(destination: await rig.receiver.uri(), amount: 50_000,
                                                       priority: .medium, override: 2)
        XCTAssertNil(declined.payjoin)
        XCTAssertEqual(declined.payjoinUnavailable, "the payjoin relay in Settings is not an https URL")
        do {
            _ = try await rig.model.previewSend(destination: await rig.receiver.uri(required: true), amount: 50_000,
                                                priority: .medium, override: 2)
            XCTFail("a required payjoin without a relay was accepted")
        } catch let error as AppModel.AppError {
            guard case .payjoinUnavailable = error else { return XCTFail("\(error)") }
        }
    }

    /// I2P-only routing makes no HTTP request, so no payjoin either.
    func testI2POnlyRoutingDeclinesPayjoin() async throws {
        let rig = try await rig(coins: [200_000], name: "pj-i2p")
        try await rig.model.setPeerGatewaySettings(.init(mode: .manual, manual: .init(
            networks: [.i2p], torProxy: nil, i2pProxy: PeerEndpoint(host: "127.0.0.1", port: 4447))))
        let declined = try await rig.model.previewSend(destination: await rig.receiver.uri(), amount: 50_000,
                                                       priority: .medium, override: 2)
        XCTAssertNil(declined.payjoin)
        XCTAssertEqual(declined.payjoinUnavailable, "I2P-only routing makes no HTTP request")
    }
}
