import Foundation
import TestSupport
import WalletCore
import XCTest

/// A 2-of-2 script-path multisig account between the phone and Bitcoin Core,
/// through the raw Advanced screens: the phone files the descriptor,
/// receives into it, creates the PSBT and signs first; Core adds its own
/// script-path signature with its own libsecp256k1; the phone finalizes and
/// broadcasts. Core must accept and mine the BIP387 witness the phone's
/// Swift code assembled.
extension WinnowAppUITests {
    nonisolated static let multisigFunding: Int64 = 5_000_000
    nonisolated static let multisigPayment: Int64 = 1_000_000

    func multisigJourney(in app: XCUIApplication, control: URL) async throws {
        let started = Date()
        let core = try CoreSigner(wallet: "ui-core-\(UUID().uuidString)")
        app.buttons["advancedModeButton"].tap()
        XCTAssertTrue(app.alerts.buttons["Turn on"].appears(within: 10))
        app.alerts.buttons["Turn on"].tap()
        XCTAssertTrue(app.tabBars.buttons["Wallet"].appears(within: 15))
        app.tabBars.buttons["Wallet"].tap()

        // The phone's own signer key, as the Add screen shows it.
        multisigTap(app, "multisigAddButton")
        app.typeInto("multisigNameField", "Phone and Core")
        let keyText = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '[' AND label CONTAINS ']tpub'")).firstMatch
        XCTAssertTrue(keyText.appears(within: 20), "the Add screen shows no key expression")
        let descriptor = try MultisigAccount.descriptor(threshold: 2, signers: [keyText.label, core.signerExpression],
                                                        network: .signet)
        let account = try MultisigAccount(descriptor: descriptor, network: .signet)
        try multisigClipboard(descriptor.serialized(), at: control)
        multisigTap(app, "multisigDescriptorPasteButton")
        let firstAddress = try coreAddress(account, choice: 0)
        XCTAssertTrue(app.staticTexts[firstAddress].appears(within: 20) || scrollUntilExists(app, app.staticTexts[firstAddress]),
                      "the Add screen's first address is not Core's")
        let save = app.navigationBars.buttons["multisigSaveButton"]
        XCTAssertTrue(poll(timeout: 15, interval: 0.2, "Save is enabled") { save.exists && save.isEnabled })
        save.tap()
        try core.importMultisigAccount(account)

        // Receive: the address on screen is Core's first address too.
        multisigTap(app, "multisigAccount-\(account.id)", up: true)
        let shown = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'tb1p'")).firstMatch
        XCTAssertTrue(shown.appears(within: 20))
        XCTAssertEqual(shown.label, firstAddress)
        Screenshots.capture(app, "26-savings-share", testCase: self)
        let funding = try await Self.fundAndConfirm(firstAddress, sats: Self.multisigFunding)
        expectMultisigBalance(app, Self.multisigFunding)
        let coins = try XCTUnwrap(BitcoinCLI.runJSON(["listunspent", "1", "9999999", "[\"\(firstAddress)\"]"],
                                                     wallet: core.wallet) as? [[String: Any]])
        let coreCoin = try XCTUnwrap(coins.first { $0["txid"] as? String == funding }, "Core did not see the payment")
        let fundingVout = try UInt32(BitcoinCLI.int(coreCoin, "vout"))
        Screenshots.capture(app, "27-savings-funded", testCase: self)

        // The phone creates the spend and signs first; one signature is not enough.
        let destination = try BitcoinCLI.newAddress(wallet: Self.bankWallet)
        multisigTap(app, "multisigPSBTButton")
        app.typeInto("multisigAddressField", destination)
        app.typeInto("multisigAmountField", String(Self.multisigPayment))
        multisigTap(app, "multisigCreateButton")
        let feeText = app.staticTexts["multisigFee"]
        XCTAssertTrue(scrollUntilExists(app, feeText), "the PSBT review did not open")
        let fee = try XCTUnwrap(Int64(feeText.label.filter(\.isNumber)))
        let output = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'cHNidP'")).firstMatch
        XCTAssertTrue(scrollUntilExists(app, output))
        let unsigned = try PSBT(base64: output.label).unsignedTransaction()

        multisigTap(app, "multisigSignButton", up: true)
        XCTAssertTrue(scrollUntilExists(app, output))
        XCTAssertTrue(poll(timeout: 20, interval: 0.2, "phone signature") {
            (try? PSBT(base64: output.label).inputs[0].tapScriptSignatures.count) == 1
        })
        let phoneSigned = try PSBT(base64: output.label)
        XCTAssertEqual(try phoneSigned.unsignedTransaction(), unsigned)
        let count = app.staticTexts["multisigSignatureCount"]
        XCTAssertTrue(scrollUntilExists(app, count, up: true))
        XCTAssertEqual(count.label, "1 of 2")
        XCTAssertTrue(scrollUntilExists(app, app.buttons["multisigBroadcastButton"], fullyVisible: true))
        XCTAssertFalse(app.buttons["multisigBroadcastButton"].isEnabled, "one signer alone cannot send")
        Screenshots.capture(app, "14-approval-waiting", testCase: self)

        // Core signs its copy with its own key; the phone combines it.
        let signed = try core.process(phoneSigned)
        XCTAssertEqual(signed.inputs[0].tapScriptSignatures.count, 2, "Core did not sign the script path")
        XCTAssertEqual(try signed.unsignedTransaction(), unsigned)
        try multisigPaste(app, signed.base64V0(), control: control)
        XCTAssertTrue(poll(timeout: 20, interval: 0.2, "both signatures verify") { count.label == "2 of 2" })

        // The phone finalizes the BIP387 witness and broadcasts; Core accepts it.
        let before = Set(try BitcoinCLI.mempoolTxids())
        multisigTap(app, "multisigBroadcastButton")
        XCTAssertTrue(app.staticTexts["multisigPaymentSent"].appears(within: 30))
        var accepted: String?
        XCTAssertTrue(poll(timeout: 30, interval: 0.2, "Core accepts the multisig payment") {
            accepted = (try? Set(BitcoinCLI.mempoolTxids()))?.subtracting(before).first
            return accepted != nil
        })
        let txid = try XCTUnwrap(accepted)
        try verifyMultisigSpend(txid: txid, account: account, funding: (funding, fundingVout),
                                destination: destination, fee: fee)
        Screenshots.capture(app, "15-approval-sent", testCase: self)

        try await Self.mineBlock()
        let change = try verifyMultisigConfirmed(txid: txid, account: account, funding: (funding, fundingVout),
                                                 destination: destination, fee: fee, core: core)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let changeLine = "\(txid.prefix(16))…:\(change.vout) · change 0 · "
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", changeLine)).firstMatch
        XCTAssertTrue(scrollUntilExists(app, row))
        XCTAssertTrue(poll(timeout: 60, interval: 0.5, "the phone confirms its multisig change") {
            row.label == "\(changeLine)block \(change.height)"
        })
        expectMultisigBalance(app, Self.multisigFunding - Self.multisigPayment - fee)
        Screenshots.capture(app, "28-savings-confirmed", testCase: self)
        print("SIGNET_MULTISIG_SECONDS=\(Date().timeIntervalSince(started))")
    }

    nonisolated static var bankWallet: String { SignetFixture.bank }

    nonisolated static func fundAndConfirm(_ address: String, sats: Int64) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let txid = try BitcoinCLI.sendToAddress(wallet: bankWallet, address: address, sats: sats, feeRate: 2)
            try await mineBlock()
            return txid
        }.value
    }

    /// Core's own derivation of the account address at (choice, 0).
    private func coreAddress(_ account: MultisigAccount, choice: Int) throws -> String {
        let body = String(account.descriptor.serialized().split(separator: "#")[0])
        let single = try Descriptor(body.replacingOccurrences(of: "/<0;1>/*", with: "/\(choice)/*")).serialized()
        let derived = try XCTUnwrap(BitcoinCLI.runJSON(["deriveaddresses", single, "[0,0]"]) as? [String])
        return try XCTUnwrap(derived.first)
    }

    /// Mempool checks: one input (the funded coin), the payment, change to
    /// the account's first change address, and the BIP387 witness: two
    /// 64-byte signatures, the leaf script and the control block.
    private func verifyMultisigSpend(txid: String, account: MultisigAccount, funding: (txid: String, vout: UInt32),
                                     destination: String, fee: Int64) throws {
        _ = try BitcoinCLI.runObject(["getmempoolentry", txid])
        let transaction = try BitcoinCLI.runObject(["getrawtransaction", txid, "true"])
        let inputs = try XCTUnwrap(transaction["vin"] as? [[String: Any]])
        XCTAssertEqual(inputs.count, 1)
        let input = try XCTUnwrap(inputs.first)
        XCTAssertEqual(try BitcoinCLI.string(input, "txid"), funding.txid)
        XCTAssertEqual(try BitcoinCLI.int(input, "vout"), Int(funding.vout))
        let witness = try XCTUnwrap(input["txinwitness"] as? [String])
        XCTAssertEqual(witness.count, 4, "two signatures, the leaf script and the control block")
        XCTAssertEqual(witness.prefix(2).map(\.count), [128, 128], "two 64-byte script-path signatures")
        XCTAssertEqual(witness.last?.count, 66, "a 33-byte single-leaf control block")

        let destinationScript = try AddressDecoder.scriptPubKey(for: destination, network: .signet)
        let changeScript = try account.scriptPubKey(index: 0, choice: AddressChain.change.rawValue)
        XCTAssertEqual(try AddressDecoder.scriptPubKey(for: coreAddress(account, choice: 1), network: .signet),
                       changeScript)
        let outputs = try XCTUnwrap(transaction["vout"] as? [[String: Any]]).map { output -> (Int64, String) in
            let script = try XCTUnwrap(output["scriptPubKey"] as? [String: Any])
            return (try BitcoinCLI.sats(XCTUnwrap(output["value"])), try BitcoinCLI.string(script, "hex"))
        }
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs.filter { $0.1 == destinationScript.hex }.map(\.0), [Self.multisigPayment])
        XCTAssertEqual(outputs.filter { $0.1 == changeScript.hex }.map(\.0),
                       [Self.multisigFunding - Self.multisigPayment - fee])
        XCTAssertGreaterThan(fee, 0)
    }

    /// After the block: the funding coin is spent, the bank received the
    /// payment, and Core found the exact change. Returns the change's vout
    /// and block height.
    private func verifyMultisigConfirmed(txid: String, account: MultisigAccount, funding: (txid: String, vout: UInt32),
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
        XCTAssertEqual(try receipts.map { try BitcoinCLI.sats(XCTUnwrap($0["amount"])) }, [Self.multisigPayment])

        let changeAddress = try coreAddress(account, choice: 1)
        let height = try BitcoinCLI.int(BitcoinCLI.runObject(["getblockheader",
                                                              BitcoinCLI.string(transaction, "blockhash")]), "height")
        let coins = try XCTUnwrap(BitcoinCLI.runJSON(["listunspent", "1", "9999999", "[\"\(changeAddress)\"]"],
                                                     wallet: core.wallet) as? [[String: Any]])
        let change = try XCTUnwrap(coins.first { $0["txid"] as? String == txid }, "Core did not find the change")
        XCTAssertEqual(try BitcoinCLI.sats(XCTUnwrap(change["amount"])), Self.multisigFunding - Self.multisigPayment - fee)
        return (try BitcoinCLI.int(change, "vout"), height)
    }

    private func multisigClipboard(_ text: String, at url: URL) throws {
        try JSONEncoder().encode(["clipboard": text]).write(to: url, options: .atomic)
    }

    private func multisigPaste(_ app: XCUIApplication, _ text: String, control: URL) throws {
        try multisigClipboard(text, at: control)
        multisigTap(app, "psbtPasteButton", up: true)
        multisigTap(app, "addPSBTButton")
    }

    private func expectMultisigBalance(_ app: XCUIApplication, _ amount: Int64) {
        let balance = app.staticTexts["multisigBalance"]
        XCTAssertTrue(scrollUntilExists(app, balance, up: true, fullyVisible: true))
        XCTAssertTrue(poll(timeout: 60, interval: 0.5, "multisig balance \(amount)") {
            Int64(balance.label.filter(\.isNumber)) == amount
        })
    }

    private func multisigTap(_ app: XCUIApplication, _ identifier: String, up: Bool = false) {
        let button = app.buttons[identifier]
        XCTAssertTrue(scrollUntilExists(app, button, maxSwipes: 8, up: up, fullyVisible: true), identifier)
        // A lazy row can be replaced after scrolling while still reporting
        // enabled; wait for usable geometry before the one tap.
        XCTAssertTrue(poll(timeout: 15, interval: 0.2, "\(identifier) enabled with an onscreen tap target") {
            button.exists && button.isEnabled && tapVisibleCenter(app, button)
        })
    }
}
