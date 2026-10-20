import Foundation
import TestSupport
import WalletCore
import XCTest

/// A 2-of-2 MuSig2 account between the phone and Bitcoin Core, through the
/// raw Advanced screens: the phone files the descriptor, receives into it,
/// creates the PSBT, and runs both rounds with Core, whose own libsecp256k1
/// MuSig2 is the other signer. Core must accept and mine the aggregate
/// key-path signature the phone's Swift code produced.
extension WinnowAppUITests {
    nonisolated static let muSig2Funding: Int64 = 5_000_000
    nonisolated static let muSig2Payment: Int64 = 1_000_000

    func muSig2Journey(in app: XCUIApplication, control: URL) async throws {
        let started = Date()
        let core = try CoreSigner(wallet: "ui-core-\(UUID().uuidString)")
        // The multisig leg leaves Advanced mode on, inside its account's PSBT
        // screen: back out to the Wallet list, checking the screen each time.
        let walletList = app.navigationBars["Winnow"]
        for _ in 0 ..< 4 where !walletList.exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            _ = walletList.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(walletList.exists, "the multisig leg did not return to the Wallet list")

        // The phone's own participant key, as the Add screen shows it.
        muSig2Tap(app, "musig2AddButton")
        app.typeInto("musig2NameField", "Phone and Core")
        let keyText = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '[' AND label CONTAINS ']tpub'")).firstMatch
        XCTAssertTrue(keyText.appears(within: 20), "the Add screen shows no key expression")
        let text = "tr(musig(\(keyText.label),\(core.publicExpression))/<0;1>/*)"
        let account = try MuSig2Account(text, network: .signet)
        try muSig2Clipboard(text, at: control)
        muSig2Tap(app, "musig2DescriptorPasteButton")
        let firstAddress = try coreAddress(account, choice: 0)
        XCTAssertTrue(app.staticTexts[firstAddress].appears(within: 20) || scrollUntilExists(app, app.staticTexts[firstAddress]),
                      "the Add screen's first address is not Core's")
        let save = app.navigationBars.buttons["musig2SaveButton"]
        XCTAssertTrue(poll(timeout: 15, interval: 0.2, "Save is enabled") { save.exists && save.isEnabled })
        save.tap()
        try core.importMuSig2Account(account)

        // Receive: the address on screen is Core's first address too.
        muSig2Tap(app, "musig2Account-\(account.id)", up: true)
        let shown = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'tb1p'")).firstMatch
        XCTAssertTrue(shown.appears(within: 20))
        XCTAssertEqual(shown.label, firstAddress)
        let funding = try await Self.fundAndConfirm(firstAddress, sats: Self.muSig2Funding)
        expectMuSig2Balance(app, Self.muSig2Funding)
        let coins = try XCTUnwrap(BitcoinCLI.runJSON(["listunspent", "1", "9999999", "[\"\(firstAddress)\"]"],
                                                     wallet: core.wallet) as? [[String: Any]])
        let coreCoin = try XCTUnwrap(coins.first { $0["txid"] as? String == funding }, "Core did not see the payment")
        let fundingVout = try UInt32(BitcoinCLI.int(coreCoin, "vout"))
        Screenshots.capture(app, "35-extra-device-policy", testCase: self)

        // The phone creates the spend.
        let destination = try BitcoinCLI.newAddress(wallet: Self.bankWallet)
        muSig2Tap(app, "musig2PSBTButton")
        app.typeInto("musig2AddressField", destination)
        app.typeInto("musig2AmountField", String(Self.muSig2Payment))
        muSig2Tap(app, "musig2CreateButton")
        let feeText = app.staticTexts["musig2Fee"]
        XCTAssertTrue(scrollUntilExists(app, feeText), "the PSBT review did not open")
        let fee = try XCTUnwrap(Int64(feeText.label.filter(\.isNumber)))
        Screenshots.capture(app, "36-extra-device-review", testCase: self)

        // Round 1: Core's nonce and the phone's, combined on the phone.
        let output = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'cHNidP'")).firstMatch
        XCTAssertTrue(scrollUntilExists(app, output))
        let proposal = try PSBT(base64: output.label)
        let unsigned = try proposal.unsignedTransaction()
        let coreNonce = try core.process(proposal)
        XCTAssertEqual(coreNonce.inputs[0].musig2PubNonces.count, 1)
        XCTAssertTrue(coreNonce.inputs[0].musig2PartialSigs.isEmpty)
        muSig2Tap(app, "musigNonceButton", up: true)
        XCTAssertTrue(scrollUntilExists(app, output))
        XCTAssertTrue(poll(timeout: 20, interval: 0.2, "phone nonce") {
            (try? PSBT(base64: output.label).inputs[0].musig2PubNonces.count) == 1
        })
        let nonces = try PSBT(base64: output.label).combined(with: [coreNonce])
        XCTAssertEqual(nonces.inputs[0].musig2PubNonces.count, 2)
        try muSig2Paste(app, nonces.base64V0(), control: control)

        // Round 2: the phone signs first; it cannot send alone.
        // A paste leaves the form at its top; the signing buttons are below.
        muSig2Tap(app, "musigSignButton")
        XCTAssertTrue(scrollUntilExists(app, output))
        XCTAssertTrue(poll(timeout: 20, interval: 0.2, "phone partial signature") {
            (try? PSBT(base64: output.label).inputs[0].musig2PartialSigs.count) == 1
        })
        let phoneSigned = try PSBT(base64: output.label)
        XCTAssertEqual(try phoneSigned.unsignedTransaction(), unsigned)
        XCTAssertTrue(scrollUntilExists(app, app.buttons["musigBroadcastButton"], up: true, fullyVisible: true))
        XCTAssertFalse(app.buttons["musigBroadcastButton"].isEnabled, "the phone alone cannot send")
        Screenshots.capture(app, "37-extra-device-waiting", testCase: self)
        let signed = try core.process(phoneSigned)
        XCTAssertEqual(signed.inputs[0].musig2PartialSigs.count, 2)
        XCTAssertEqual(try signed.unsignedTransaction(), unsigned)
        try muSig2Paste(app, signed.base64V0(), control: control)

        // The phone aggregates and broadcasts; Core accepts it.
        let before = Set(try BitcoinCLI.mempoolTxids())
        muSig2Tap(app, "musigBroadcastButton")
        XCTAssertTrue(app.staticTexts["musig2PaymentSent"].appears(within: 30))
        var accepted: String?
        XCTAssertTrue(poll(timeout: 30, interval: 0.2, "Core accepts the MuSig2 payment") {
            accepted = (try? Set(BitcoinCLI.mempoolTxids()))?.subtracting(before).first
            return accepted != nil
        })
        let txid = try XCTUnwrap(accepted)
        try verifyMuSig2Spend(txid: txid, account: account, funding: (funding, fundingVout),
                              destination: destination, fee: fee)
        Screenshots.capture(app, "39-extra-device-sent", testCase: self)

        try await Self.mineBlock()
        let change = try verifyMuSig2Confirmed(txid: txid, account: account, funding: (funding, fundingVout),
                                               destination: destination, fee: fee, core: core)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let changeLine = "\(txid.prefix(16))…:\(change.vout) · change 0 · "
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", changeLine)).firstMatch
        XCTAssertTrue(scrollUntilExists(app, row))
        XCTAssertTrue(poll(timeout: 60, interval: 0.5, "the phone confirms its MuSig2 change") {
            row.label == "\(changeLine)block \(change.height)"
        })
        expectMuSig2Balance(app, Self.muSig2Funding - Self.muSig2Payment - fee)
        Screenshots.capture(app, "40-extra-device-confirmed", testCase: self)
        print("SIGNET_MUSIG_SECONDS=\(Date().timeIntervalSince(started))")
    }

    /// Core's own derivation of the account address at (choice, 0).
    private func coreAddress(_ account: MuSig2Account, choice: Int) throws -> String {
        let body = String(account.descriptor.serialized().split(separator: "#")[0])
        let single = try Descriptor(body.replacingOccurrences(of: "/<0;1>/*", with: "/\(choice)/*")).serialized()
        let derived = try XCTUnwrap(BitcoinCLI.runJSON(["deriveaddresses", single, "[0,0]"]) as? [String])
        return try XCTUnwrap(derived.first)
    }

    /// Mempool checks: one input (the funded coin), the payment, change to
    /// the account's first change address, a single 64-byte witness.
    private func verifyMuSig2Spend(txid: String, account: MuSig2Account, funding: (txid: String, vout: UInt32),
                                   destination: String, fee: Int64) throws {
        _ = try BitcoinCLI.runObject(["getmempoolentry", txid])
        let transaction = try BitcoinCLI.runObject(["getrawtransaction", txid, "true"])
        let inputs = try XCTUnwrap(transaction["vin"] as? [[String: Any]])
        XCTAssertEqual(inputs.count, 1)
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(try BitcoinCLI.string(input, "txid"), funding.txid)
        XCTAssertEqual(try BitcoinCLI.int(input, "vout"), Int(funding.vout))
        let witness = try XCTUnwrap(input["txinwitness"] as? [String])
        XCTAssertEqual(witness.count, 1)
        XCTAssertEqual(try XCTUnwrap(witness.first).count, 128, "one 64-byte key-path signature")

        let destinationScript = try AddressDecoder.scriptPubKey(for: destination, network: .signet)
        let changeScript = try account.scriptPubKey(index: 0, choice: AddressChain.change.rawValue)
        XCTAssertEqual(try AddressDecoder.scriptPubKey(for: coreAddress(account, choice: 1), network: .signet),
                       changeScript)
        let outputs = try XCTUnwrap(transaction["vout"] as? [[String: Any]]).map { output -> (Int64, String) in
            let script = try XCTUnwrap(output["scriptPubKey"] as? [String: Any])
            return (try BitcoinCLI.sats(XCTUnwrap(output["value"])), try BitcoinCLI.string(script, "hex"))
        }
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs.filter { $0.1 == destinationScript.hex }.map(\.0), [Self.muSig2Payment])
        XCTAssertEqual(outputs.filter { $0.1 == changeScript.hex }.map(\.0),
                       [Self.muSig2Funding - Self.muSig2Payment - fee])
        XCTAssertGreaterThan(fee, 0)
    }

    /// After the block: the funding coin is spent, the bank received the
    /// payment, and Core found the exact change. Returns the change's vout
    /// and block height.
    private func verifyMuSig2Confirmed(txid: String, account: MuSig2Account, funding: (txid: String, vout: UInt32),
                                       destination: String, fee: Int64,
                                       core: CoreSigner) throws -> (vout: Int, height: Int) {
        let transaction = try BitcoinCLI.runObject(["getrawtransaction", txid, "true"])
        XCTAssertGreaterThan(try BitcoinCLI.int(transaction, "confirmations"), 0)
        let spent = try BitcoinCLI.runJSON(["gettxout", funding.txid, String(funding.vout)])
        XCTAssertTrue(spent == nil || spent is NSNull, "the funded output was not spent")
        let bank = try BitcoinCLI.runObject(["gettransaction", txid], wallet: Self.bankWallet)
        let receipts = try XCTUnwrap(bank["details"] as? [[String: Any]]).filter {
            $0["category"] as? String == "receive" && $0["address"] as? String == destination
        }
        XCTAssertEqual(try receipts.map { try BitcoinCLI.sats(XCTUnwrap($0["amount"])) }, [Self.muSig2Payment])

        let changeAddress = try coreAddress(account, choice: 1)
        let height = try BitcoinCLI.int(BitcoinCLI.runObject(["getblockheader",
                                                              BitcoinCLI.string(transaction, "blockhash")]), "height")
        let coins = try XCTUnwrap(BitcoinCLI.runJSON(["listunspent", "1", "9999999", "[\"\(changeAddress)\"]"],
                                                     wallet: core.wallet) as? [[String: Any]])
        let change = try XCTUnwrap(coins.first { $0["txid"] as? String == txid }, "Core did not find the change")
        XCTAssertEqual(try BitcoinCLI.sats(XCTUnwrap(change["amount"])), Self.muSig2Funding - Self.muSig2Payment - fee)
        return (try BitcoinCLI.int(change, "vout"), height)
    }

    private func muSig2Clipboard(_ text: String, at url: URL) throws {
        try JSONEncoder().encode(["clipboard": text]).write(to: url, options: .atomic)
    }

    private func muSig2Paste(_ app: XCUIApplication, _ text: String, control: URL) throws {
        try muSig2Clipboard(text, at: control)
        muSig2Tap(app, "psbtPasteButton", up: true)
        muSig2Tap(app, "addPSBTButton")
    }

    private func expectMuSig2Balance(_ app: XCUIApplication, _ amount: Int64) {
        let balance = app.staticTexts["musig2Balance"]
        XCTAssertTrue(scrollUntilExists(app, balance, up: true, fullyVisible: true))
        XCTAssertTrue(poll(timeout: 60, interval: 0.5, "MuSig2 balance \(amount)") {
            Int64(balance.label.filter(\.isNumber)) == amount
        })
    }

    private func muSig2Tap(_ app: XCUIApplication, _ identifier: String, up: Bool = false) {
        let button = app.buttons[identifier]
        XCTAssertTrue(scrollUntilExists(app, button, maxSwipes: 8, up: up, fullyVisible: true), identifier)
        // A lazy row can be replaced after scrolling while still reporting
        // enabled; wait for usable geometry before the one tap.
        XCTAssertTrue(poll(timeout: 15, interval: 0.2, "\(identifier) enabled with an onscreen tap target") {
            button.exists && button.isEnabled && tapVisibleCenter(app, button)
        })
    }
}
