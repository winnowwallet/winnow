import Foundation
import TestSupport
import WalletCore
import XCTest

/// A BIP 77 payjoin from the everyday wallet on the signet fixture. The test
/// plays the receiver: a `FakePayjoinDirectory` (relay, gateway and
/// mailboxes) listens on loopback in the runner, and a `FakePayjoinReceiver`
/// with a coin Core funded answers the Original PSBT with a proposal that
/// adds that coin. The app pastes the receiver's `bitcoin:` request, shows
/// the payjoin envelope on the review, posts through the relay, checks the
/// proposal, signs only its own input and broadcasts; Core must accept and
/// mine a transaction with both parties' inputs, and the phone's receipt and
/// history say what happened.
extension WinnowAppUITests {
    nonisolated static let payjoinAmount: Int64 = 200_000

    func payjoinJourney(in app: XCUIApplication, control: URL) async throws {
        let directory = try FakePayjoinDirectory(pollTimeout: .seconds(2))
        try await directory.start()
        defer { Task { await directory.stop() } }
        let receiver = try FakePayjoinReceiver(network: .signet, directory: directory)

        // Core funds the receiver's own coin and mines it.
        let fundingTxid = try await Self.fundAndConfirm(receiver.address)
        let funding = try BitcoinCLI.runObject(["getrawtransaction", fundingTxid, "true"])
        let outputs = try XCTUnwrap(funding["vout"] as? [[String: Any]])
        let vout = try XCTUnwrap(outputs.firstIndex {
            ($0["scriptPubKey"] as? [String: Any])?["hex"] as? String == receiver.paymentScript.hex
        })
        receiver.fund(outpoint: Transaction.Outpoint(txid: Data(try XCTUnwrap(Data(hex: fundingTxid)).reversed()),
                                                     vout: UInt32(vout)),
                      amount: try BitcoinCLI.sats(XCTUnwrap(outputs[vout]["value"])))

        // The request reaches the app as pasted text; the relay through the control file.
        let uri = await receiver.uri(amountSats: Self.payjoinAmount)
        try JSONEncoder().encode(["clipboard": uri, "payjoinRelay": await directory.url.absoluteString])
            .write(to: control, options: .atomic)
        app.buttons["openSendButton"].tap()
        XCTAssertTrue(app.buttons["pasteDestinationButton"].appears(within: 20))
        app.buttons["pasteDestinationButton"].tap()
        app.typeInto("amountField", String(Self.payjoinAmount))
        app.buttons["reviewButton"].tap()
        let send = app.buttons["sendButton"]
        XCTAssertTrue(send.appears(within: 30), "the payjoin review did not open")
        XCTAssertEqual(app.staticTexts["reviewDestination"].label, receiver.address)
        XCTAssertTrue(app.staticTexts["payjoinNote"].exists, "the review does not say this is a payjoin")
        XCTAssertTrue(app.staticTexts["payjoinDisclosure"].label.contains("127.0.0.1"))
        Screenshots.capture(app, "30-payjoin-review", testCase: self)

        let before = Set(try BitcoinCLI.mempoolTxids())
        let serving = Task { try await receiver.serve(.honest, timeout: .seconds(90)) }
        send.tap()
        try await serving.value
        var payment: String?
        let sendError = app.staticTexts["sendError"]
        let arrived = poll(timeout: 90, interval: 1, "the node receives the payjoin transaction") {
            payment = (try? Set(BitcoinCLI.mempoolTxids()))?.subtracting(before).first
            return payment != nil || sendError.exists
        }
        if sendError.exists { XCTFail("the app reported: \(sendError.label)") }
        let seen = await directory.innerRequests.map { "\($0.method) \($0.path) \($0.body.count)B" }
        XCTAssertTrue(arrived, "no payjoin transaction reached the node; the directory saw: \(seen)")
        let txid = try XCTUnwrap(payment)
        let transaction = try BitcoinCLI.runObject(["getrawtransaction", txid, "true"])
        let decoded = try Transaction.decode(XCTUnwrap(Data(hex: BitcoinCLI.string(transaction, "hex"))))
        XCTAssertEqual(decoded.inputs.count, 2, "the transaction Core accepted has both parties' inputs")
        XCTAssertTrue(decoded.inputs.contains { $0.previousOutput == receiver.coin?.outpoint },
                      "the receiver's coin is not among the inputs")
        let paid = try XCTUnwrap(decoded.outputs.first { $0.scriptPubKey == receiver.paymentScript })
        XCTAssertGreaterThanOrEqual(paid.value, Self.payjoinAmount)
        XCTAssertEqual(receiver.receivedParameters["disableoutputsubstitution"], "true")

        // The receipt says what the receiver did.
        XCTAssertTrue(app.staticTexts["payjoinOutcome"].appears(within: 20), "the receipt does not mention the payjoin")
        XCTAssertTrue(app.staticTexts["payjoinOutcome"].label.contains("added 1 input"))
        Screenshots.capture(app, "31-payjoin-sent", testCase: self)
        try await Self.mineBlock()
        XCTAssertTrue(app.staticTexts["broadcastConfirmed"].appears(within: 90),
                      "the open receipt did not notice the payjoin confirming")
        app.buttons["closeSendButton"].tap()
        let sent = app.buttons["historyPayment-\(txid)"]
        XCTAssertTrue(sent.appears(within: 20), "the payjoin is missing from history")
        XCTAssertTrue(sent.label.contains("Sent"))
    }
}
