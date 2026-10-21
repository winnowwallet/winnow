import Foundation
import TestSupport
import WalletCore
import XCTest

/// A 2-of-2 MuSig2 account between the phone and a Satochip card on the
/// disposable signet. The card is TestSupport's `SatochipEmulator`, served to
/// the app over 127.0.0.1 in place of Core NFC and set up as the checker
/// leaves it: PIN, seed and 2FA on. The phone reads the card's key, builds the
/// account, and runs both rounds with card taps; the test plays the checker
/// with WalletCore's `Satochip.Checker` on the PSBT the screen shows. The node
/// must accept and mine the single key-path signature. No screenshots: the
/// published checkpoints belong to test01.
extension WinnowAppUITests {
    nonisolated static let satochipPIN = "1234"
    nonisolated static let satochipSeed = Data(repeating: 0x5C, count: 32)
    nonisolated static let satochipTwoFactorKey = Data(repeating: 0x2F, count: 20)
    nonisolated static let satochipPath: [UInt32] = [86 + HDKey.hardenedOffset, 1 + HDKey.hardenedOffset,
                                                     HDKey.hardenedOffset]
    nonisolated static let satochipFunding: Int64 = 3_000_000
    nonisolated static let satochipPayment: Int64 = 700_000

    func test02SatochipCosigner() async throws {
        continueAfterFailure = false
        executionTimeAllowance = 600
        try SignetFixture.requirePreparedBank()
        let started = Date()
        let card = SatochipEmulator(pin: Data(Self.satochipPIN.utf8), seed: Self.satochipSeed,
                                    twoFactorKey: Self.satochipTwoFactorKey)
        let server = try SatochipLineServer(card: card)
        defer { server.stop() }
        let control = FileManager.default.temporaryDirectory.appending(path: "winnow-satochip-\(UUID().uuidString).json")
        try satochipClipboard("", at: control)
        defer { try? FileManager.default.removeItem(at: control) }

        let app = XCUIApplication()
        app.launchEnvironment = [
            "WINNOW_E2E": "1",
            "WINNOW_E2E_RUN": "satochip",
            "WINNOW_E2E_RESET": "1",
            "WINNOW_E2E_ENTROPY": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "WINNOW_E2E_CONTROL_FILE": control.path,
            "WINNOW_E2E_PEER": "\(BitcoinCLI.nodeHost):\(BitcoinCLI.p2pPort)",
            "WINNOW_E2E_CHALLENGE": BitcoinCLI.challengeHex,
            "WINNOW_E2E_PEER_COUNT": "1",
            "WINNOW_E2E_SYNC_INTERVAL": "3",
            "WINNOW_E2E_ADVANCED": "1",
            "WINNOW_E2E_SATOCHIP_PORT": String(server.port),
        ]
        app.launch()
        defer { app.terminate() }
        let create = app.buttons["createWalletButton"]
        XCTAssertTrue(create.appears(within: 60))
        XCTAssertTrue(tapVisibleCenter(app, create), "create wallet has no onscreen tap target")
        XCTAssertTrue(app.tabBars.buttons["Wallet"].appears(within: 60))
        app.tabBars.buttons["Wallet"].tap()

        // The checker's own view of the card: the keys the setup tool read.
        let master = try HDKey(seed: Self.satochipSeed)
        let cardAccount = try master.derived(path: Self.satochipPath)
        let cardKey = try Satochip.Checker.cardKeyExpression(
            masterXpub: master.neutered.serialized(network: .testnet),
            accountXpub: cardAccount.neutered.serialized(network: .testnet), path: Self.satochipPath, network: .testnet)

        // Add: the phone's key, then the card's with a tap; the descriptor builds itself.
        satochipTap(app, "musig2AddButton")
        app.typeInto("musig2NameField", "Phone and card")
        let phoneKeyText = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '[' AND label CONTAINS ']tpub'"))
            .firstMatch
        XCTAssertTrue(phoneKeyText.appears(within: 20), "the Add screen shows no key expression")
        let descriptor = "tr(musig(\(phoneKeyText.label),\(cardKey))/<0;1>/*)"
        let account = try MuSig2Account(descriptor, network: .signet)
        satochipTap(app, "musig2SatochipReadButton")
        enterSatochipPIN(app)
        let inDescriptor = app.staticTexts["musig2SatochipInDescriptor"]
        XCTAssertTrue(scrollUntilExists(app, inDescriptor), "the card's key did not reach the descriptor")
        XCTAssertEqual(inDescriptor.label, "One participant is the Satochip read above.")
        let firstAddress = try account.address(index: 0)
        XCTAssertTrue(app.staticTexts[firstAddress].appears(within: 20) || scrollUntilExists(app, app.staticTexts[firstAddress]),
                      "the Add screen's first address is not the checker's")
        let save = app.navigationBars.buttons["musig2SaveButton"]
        XCTAssertTrue(poll(timeout: 15, interval: 0.2, "Save is enabled") { save.exists && save.isEnabled })
        save.tap()
        let checker = try Satochip.Checker(descriptor: descriptor, network: .signet, cardKey: cardAccount.publicKey,
                                           twoFactorKey: Self.satochipTwoFactorKey, searchLimit: 20)

        // Receive and fund.
        satochipTap(app, "musig2Account-\(account.id)", up: true)
        XCTAssertTrue(app.staticTexts["musig2AccountSatochip"].appears(within: 20) ||
                      scrollUntilExists(app, app.staticTexts["musig2AccountSatochip"]))
        let shown = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'tb1p'")).firstMatch
        XCTAssertTrue(scrollUntilExists(app, shown, up: true))
        XCTAssertEqual(shown.label, firstAddress)
        let funding = try await Self.fundAndConfirm(firstAddress, sats: Self.satochipFunding)
        satochipBalance(app, Self.satochipFunding)

        // The phone creates the spend and adds its nonce; one tap adds the card's.
        let destination = try BitcoinCLI.newAddress(wallet: Self.bankWallet)
        satochipTap(app, "musig2PSBTButton")
        app.typeInto("musig2AddressField", destination)
        app.typeInto("musig2AmountField", String(Self.satochipPayment))
        satochipTap(app, "musig2CreateButton")
        let output = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'cHNidP'")).firstMatch
        XCTAssertTrue(scrollUntilExists(app, output), "the PSBT did not appear")
        satochipTap(app, "musigNonceButton", up: true)
        XCTAssertTrue(poll(timeout: 20, interval: 0.2, "phone nonce") { self.nonces(output) == 1 })
        satochipTap(app, "musig2CardNonceButton", up: true)
        enterSatochipPIN(app)
        XCTAssertTrue(scrollUntilExists(app, output))
        XCTAssertTrue(poll(timeout: 30, interval: 0.2, "card nonce") { self.nonces(output) == 2 })

        // The card has 2FA on: without the checker's approvals the phone does not even ask it.
        satochipTap(app, "musig2CardSignButton", up: true)
        enterSatochipPIN(app)
        let error = app.staticTexts["musig2Error"]
        XCTAssertTrue(scrollUntilExists(app, error), "a card signature without approvals was not refused")
        XCTAssertTrue(error.label.contains("2FA"), error.label)

        // The checker reviews the PSBT alone and approves it; the phone pastes the approvals.
        XCTAssertTrue(scrollUntilExists(app, output))
        let proposal = try PSBT(base64: output.label)
        let review = try checker.review(proposal)
        XCTAssertEqual(review.sentAway, Self.satochipPayment)
        XCTAssertEqual(review.outputs.first { !$0.isAccountOwned }?.address, destination)
        try satochipClipboard(try checker.approve(proposal).text, at: control)
        satochipTap(app, "musig2ApprovalsPasteButton", up: true)
        XCTAssertTrue(poll(timeout: 10, interval: 0.2, "approvals pasted") {
            app.buttons["musig2ApprovalsPasteButton"].label == "Approvals for 1 input(s)"
        })

        // Round 2: one tap for the card, then the phone; then broadcast.
        satochipTap(app, "musig2CardSignButton")
        enterSatochipPIN(app)
        XCTAssertTrue(scrollUntilExists(app, output))
        XCTAssertTrue(poll(timeout: 30, interval: 0.2, "card partial signature") { self.partials(output) == 1 })
        satochipTap(app, "musigSignButton", up: true)
        XCTAssertTrue(scrollUntilExists(app, output))
        XCTAssertTrue(poll(timeout: 20, interval: 0.2, "phone partial signature") { self.partials(output) == 2 })
        let before = Set(try BitcoinCLI.mempoolTxids())
        satochipTap(app, "musigBroadcastButton", up: true)
        XCTAssertTrue(app.staticTexts["musig2PaymentSent"].appears(within: 30))
        var accepted: String?
        XCTAssertTrue(poll(timeout: 30, interval: 0.2, "Core accepts the phone-and-card payment") {
            accepted = (try? Set(BitcoinCLI.mempoolTxids()))?.subtracting(before).first
            return accepted != nil
        })
        let txid = try XCTUnwrap(accepted)
        let transaction = try BitcoinCLI.runObject(["getrawtransaction", txid, "true"])
        let input = try XCTUnwrap((transaction["vin"] as? [[String: Any]])?.first)
        XCTAssertEqual(try BitcoinCLI.string(input, "txid"), funding)
        XCTAssertEqual(try XCTUnwrap((input["txinwitness"] as? [String])?.first).count, 128, "one key-path signature")
        try await Self.mineBlock()
        XCTAssertGreaterThan(try BitcoinCLI.int(BitcoinCLI.runObject(["getrawtransaction", txid, "true"]),
                                                "confirmations"), 0)
        print("SIGNET_SATOCHIP_SECONDS=\(Date().timeIntervalSince(started))")
    }

    private func nonces(_ output: XCUIElement) -> Int? {
        (try? PSBT(base64: output.label))?.inputs.first?.musig2PubNonces.count
    }

    private func partials(_ output: XCUIElement) -> Int? {
        (try? PSBT(base64: output.label))?.inputs.first?.musig2PartialSigs.count
    }

    private func enterSatochipPIN(_ app: XCUIApplication) {
        let field = app.secureTextFields["satochipPINField"]
        XCTAssertTrue(field.appears(within: 20), "the PIN sheet did not open")
        field.tap()
        field.typeText(Self.satochipPIN)
        let next = app.buttons["satochipPINContinue"]
        XCTAssertTrue(poll(timeout: 10, interval: 0.2, "PIN accepted") { next.isEnabled })
        next.tap()
        XCTAssertTrue(field.disappears(within: 10), "the PIN sheet did not close")
        // Focus returns to the screen's last field, and its keyboard would
        // cover the rows the next steps scroll to.
        app.dismissKeyboard()
    }

    private func satochipClipboard(_ text: String, at url: URL) throws {
        try JSONEncoder().encode(["clipboard": text]).write(to: url, options: .atomic)
    }

    private func satochipBalance(_ app: XCUIApplication, _ amount: Int64) {
        let balance = app.staticTexts["musig2Balance"]
        XCTAssertTrue(scrollUntilExists(app, balance, up: true, fullyVisible: true))
        XCTAssertTrue(poll(timeout: 60, interval: 0.5, "card account balance \(amount)") {
            Int64(balance.label.filter(\.isNumber)) == amount
        })
    }

    private func satochipTap(_ app: XCUIApplication, _ identifier: String, up: Bool = false) {
        let button = app.buttons[identifier]
        XCTAssertTrue(scrollUntilExists(app, button, maxSwipes: 8, up: up, fullyVisible: true), identifier)
        XCTAssertTrue(poll(timeout: 15, interval: 0.2, "\(identifier) enabled with an onscreen tap target") {
            button.exists && button.isEnabled && tapVisibleCenter(app, button)
        })
    }
}
