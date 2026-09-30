import Foundation
import TestSupport
import UIKit
import WalletCore
import XCTest

/// Runs both Swift clients in separate namespaces. The host kills each actual
/// app PID, while stock LDK providers persist and settle the held payment.
@MainActor
final class LightningAppUITests: XCTestCase {
    // The single Bitcoin peer can time out a request, cool down and redial
    // before verified scanning resumes. Include that recovery within the wait;
    // the channel state and exact wallet balances still have to be verified.
    private let verifiedChainTimeout: TimeInterval = 120
    private var config: [String: String] = [:]
    private var control: URL!
    private var setup: [String: Any] = [:]

    /// Opt-in public-network smoke test. No local Bitcoin/Lightning peer,
    /// synthetic chain position, fee approval, or funds are used. This isolated
    /// debug wallet is for diagnostics only; never fund it from an exchange.
    func testLiveMainnetSyncAndUnpaidReceivingQuote() throws {
        guard ProcessInfo.processInfo.environment["WINNOW_LIVE_MAINNET"] == "1" else {
            throw XCTSkip("Requires explicit live mainnet diagnostic opt-in")
        }
        continueAfterFailure = false
        executionTimeAllowance = 1_050
        let app = XCUIApplication()
        defer { app.terminate() }
        let started = Date()
        app.launchEnvironment = [
            "WINNOW_E2E": "1", "WINNOW_E2E_RUN": "live-mainnet-\(UUID())",
            "WINNOW_E2E_NETWORK": "mainnet", "WINNOW_E2E_ADVANCED": "1",
            "WINNOW_E2E_ENTROPY": String(repeating: "05", count: 16),
            "WINNOW_E2E_SYNC_INTERVAL": "5",
            "WINNOW_E2E_CENSUS_URL": "https://census.winnowwallet.com/census/peers.json",
        ]
        app.launch()
        tap(app, "createWalletButton")
        selectTab(app, "Wallet")
        app.buttons["advancedModeButton"].tap()
        app.buttons["receiveButton"].tap()
        tap(app, "receiveLightning")
        XCTAssertEqual(app.staticTexts["lightningReceiveProvider"].value as? String, "Olympus by ZEUS")
        XCTAssertTrue(app.staticTexts["lightningReceivable"].label.contains("0 sats"))
        XCTAssertFalse(app.staticTexts["lightningReceiveInvoice"].exists)
        app.typeInto("lightningReceiveAmount", "500")
        app.dismissKeyboard()
        tap(app, "lightningGetCapacity")
        let options = app.buttons["lightningProviderOptions"]
        XCTAssertTrue(poll(timeout: 900, interval: 3, "fresh verified mainnet scan enables provider setup") {
            options.isEnabled
        }, app.debugDescription)
        print("LIVE_MAINNET_SYNC_SECONDS=\(Date().timeIntervalSince(started))")
        tap(app, "lightningProviderOptions")
        XCTAssertTrue(poll(timeout: 60, interval: 2, "live provider options") {
            app.textFields["lightningInboundCapacity"].exists || app.staticTexts["lightningLiquidityError"].exists
        }, app.debugDescription)
        XCTAssertFalse(app.staticTexts["lightningLiquidityError"].exists, app.debugDescription)
        XCTAssertTrue(app.textFields["lightningInboundCapacity"].exists, app.debugDescription)
        Screenshots.capture(app, "live-mainnet-provider-options", testCase: self)
        tap(app, "lightningQuoteCapacity")
        XCTAssertTrue(poll(timeout: 60, interval: 2, "live unpaid provider quote") {
            app.staticTexts["lightningSetupFee"].exists || app.staticTexts["lightningLiquidityError"].exists
        }, app.debugDescription)
        XCTAssertFalse(app.staticTexts["lightningLiquidityError"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["lightningSetupFee"].exists, app.debugDescription)
        let setupFee = app.staticTexts["lightningSetupFee"].label
        // Form review rows below the viewport materialize after scrolling.
        let approval = app.buttons["lightningApproveSetupFee"]
        XCTAssertTrue(scroll(app, approval, fullyVisible: true), app.debugDescription)
        XCTAssertTrue(approval.isEnabled, app.debugDescription)
        XCTAssertFalse(app.staticTexts["lightningSetupInvoice"].exists, "Unapproved quote must not expose a payable invoice")
        Screenshots.capture(app, "live-mainnet-unpaid-quote", testCase: self)
        print("LIVE_MAINNET_QUOTE=\(setupFee)")
        print("LIVE_MAINNET_FINANCIAL_ACTIONS=none")
        app.navigationBars["Set up receiving"].buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(poll(timeout: 900, interval: 3, "verified public mainnet sync") {
            app.staticTexts["syncSummaryText"].label == "Up to date"
        }, app.debugDescription)
        print("LIVE_MAINNET_SYNC_SECONDS_THIS_LAUNCH=\(Date().timeIntervalSince(started))")
        Screenshots.capture(app, "live-mainnet-synced", testCase: self)
    }

    func testFreshSimpleModeOffersBothReceiveMethodsAndThreeProviders() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchEnvironment = [
            "WINNOW_E2E": "1", "WINNOW_E2E_RUN": "lightning-receive-\(UUID())", "WINNOW_E2E_RESET": "1",
            "WINNOW_E2E_NETWORK": "mainnet", "WINNOW_E2E_ENTROPY": String(repeating: "04", count: 16), "WINNOW_E2E_ADVANCED": "1",
            "WINNOW_E2E_PEER": "127.0.0.1:1", "WINNOW_E2E_PEER_COUNT": "1",
        ]
        app.launch()
        tap(app, "createWalletButton")
        selectTab(app, "Wallet")
        let mode = app.buttons["advancedModeButton"]
        XCTAssertEqual(mode.label, "Simple", app.debugDescription)
        mode.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "advancedModeButton")
            .matching(NSPredicate(format: "label == %@", "Advanced")).firstMatch.appears(within: 10),
            "Simple must replace the advanced tab layout: \(app.debugDescription)")
        XCTAssertFalse(app.buttons["Lightning"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["Settings"].exists, app.debugDescription)
        // Resolve the Simple home's button at activation time rather than
        // retaining a screen coordinate through the mode layout transition.
        let receive = app.buttons["receiveButton"]
        XCTAssertTrue(receive.isHittable, app.debugDescription)
        receive.tap()
        let receivedEntry = app.buttons["receiveLightning"].appears(within: 10)
        if !receivedEntry {
            Screenshots.capture(app, "lightning-simple-receive-entry-failure", testCase: self)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "lightning-simple-receive-entry-failure-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(receivedEntry, app.debugDescription)
        XCTAssertTrue(app.buttons["receiveBitcoin"].exists)
        Screenshots.capture(app, "lightning-simple-receive-methods", testCase: self)
        app.buttons["receiveLightning"].tap()
        let providerName = app.staticTexts["lightningReceiveProvider"]
        XCTAssertTrue(providerName.appears(within: 10), app.debugDescription)
        XCTAssertEqual(providerName.value as? String, "Olympus by ZEUS")
        XCTAssertTrue(app.staticTexts["lightningReceivable"].exists)
        XCTAssertFalse(app.staticTexts["lightningReceiveInvoice"].exists, "fresh install must not pretend to have receiving capacity")
        Screenshots.capture(app, "lightning-simple-receive-setup", testCase: self)
        tap(app, "lightningReceiveSetup")
        for provider in ["olympus", "megalith", "lnserver"] {
            XCTAssertTrue(scroll(app, app.buttons["lightningProvider.\(provider)"]))
        }
        Screenshots.capture(app, "lightning-three-providers", testCase: self)
        tapToolbar(app, "lightningSetupDone")
        XCTAssertTrue(app.buttons["lightningSetupDone"].disappears(within: 10), app.debugDescription)
        XCTAssertTrue(scroll(app, app.buttons["Receive Bitcoin instead"]))
        app.buttons["Receive Bitcoin instead"].tap()
        let skip = app.buttons["skipReceiveAddressLabelButton"]
        if skip.appears(within: 10) { skip.tap() }
        let address = app.staticTexts["receiveAddress"]
        XCTAssertTrue(address.appears(within: 15))
        XCTAssertTrue((address.value as? String ?? "").hasPrefix("bc1p"))
        Screenshots.capture(app, "lightning-simple-bitcoin-receive", testCase: self)
    }

    func testSimpleModePersistsAndKeepsLightningIdentity() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchEnvironment = [
            "WINNOW_E2E": "1", "WINNOW_E2E_RUN": "lightning-simple-\(UUID())",
            "WINNOW_E2E_RESET": "1", "WINNOW_E2E_NETWORK": "signet",
            "WINNOW_E2E_ENTROPY": String(repeating: "03", count: 16),
            "WINNOW_E2E_PEER": "127.0.0.1:1", "WINNOW_E2E_PEER_COUNT": "1",
            // Start on the tabs; the relaunch below drops this so the saved
            // Simple choice alone decides the layout.
            "WINNOW_E2E_ADVANCED": "1",
        ]
        app.launch()
        tap(app, "createWalletButton")
        selectTab(app, "Lightning")
        let node = app.staticTexts["lightningNodeID"]
        XCTAssertTrue(scroll(app, node))
        XCTAssertTrue(poll(timeout: 30, interval: 0.2, "durable node identity") {
            (node.value as? String)?.count == 66
        })
        let identity = try XCTUnwrap(node.value as? String)
        selectTab(app, "Wallet")
        let mode = app.buttons["advancedModeButton"]
        XCTAssertEqual(mode.label, "Simple")
        mode.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "advancedModeButton")
            .matching(NSPredicate(format: "label == %@", "Advanced")).firstMatch.appears(within: 10),
            "Simple must replace the advanced tab layout")
        XCTAssertFalse(app.buttons["Lightning"].exists)
        XCTAssertTrue(scroll(app, app.buttons["openSendButton"]))
        XCTAssertTrue(scroll(app, app.staticTexts["networkTag"], up: true))
        XCTAssertEqual(app.staticTexts["networkTag"].label, "Signet · test coins")
        Screenshots.capture(app, "lightning-simple-mode", testCase: self)

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "WINNOW_E2E_RESET")
        app.launchEnvironment.removeValue(forKey: "WINNOW_E2E_ADVANCED")
        app.launch()
        XCTAssertTrue(mode.appears(within: 30))
        XCTAssertEqual(mode.label, "Advanced", "relaunch must keep Simple mode")
        XCTAssertFalse(app.buttons["Lightning"].exists)
        XCTAssertTrue(scroll(app, app.buttons["receiveButton"]))
        mode.tap()
        let confirmation = app.alerts["Turn on Advanced mode?"]
        XCTAssertTrue(confirmation.appears(within: 10))
        confirmation.buttons["Turn on"].tap()
        selectTab(app, "Lightning")
        XCTAssertTrue(scroll(app, node))
        XCTAssertEqual(node.value as? String, identity, "mode changes must retain the Lightning identity")
        selectTab(app, "Wallet")
        XCTAssertEqual(mode.label, "Simple")
    }

    func testAsyncOfferAcrossActualAppCrashes() throws {
        continueAfterFailure = false
        executionTimeAllowance = 900
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["WINNOW_LIGHTNING_UI_FIXTURE"], "Run scripts/ci-lightning-ui with a fresh fixture")
        config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        setup = try rpc("status")
        control = FileManager.default.temporaryDirectory.appending(path: "lightning-control-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: control) }
        let app = XCUIApplication()
        defer { app.terminate() }

        try launch(app, role: "recipient", fresh: true)
        try configure(app, profile: XCTUnwrap(setup["recipient"] as? [String: Any]))
        try waitConnected(app)
        let recipientProfile = try rpc("recipient_channel")
        try configure(app, profile: recipientProfile, up: false)
        try waitConnected(app)
        let reminderBanner = app.buttons["channelReminderBanner"]
        XCTAssertTrue(reminderBanner.appears(within: 60), "funded channels must offer check reminders")
        reminderBanner.tap()
        XCTAssertTrue(scroll(app, app.staticTexts["channelProtectionLimitations"]))
        XCTAssertTrue(scroll(app, app.buttons["channelCheckReminders"], up: true))
        Screenshots.capture(app, "lightning-channel-protection-reminders", testCase: self)
        app.buttons["Done"].tap()
        tap(app, "lightningCreateOffer")
        let offerElement = app.staticTexts["lightningReceiveOffer"]
        XCTAssertTrue(scroll(app, offerElement))
        XCTAssertTrue(offerElement.appears(within: 60))
        let offer = try XCTUnwrap(offerElement.value as? String)
        XCTAssertTrue(offer.hasPrefix("lno1"))
        tap(app, "lightningCopyOffer")
        XCTAssertEqual(try clipboard(), offer, "Copy changed the reusable offer bytes")
        Screenshots.capture(app, "lightning-01-reusable-offer", testCase: self)
        // Verify a fresh Share write, rather than reusing the direct Copy value.
        UIPasteboard.general.items = []
        XCTAssertEqual(try clipboard(), "", "Share must start with an empty simulator clipboard")
        tap(app, "lightningShareOffer")
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy")).firstMatch
        let more = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "View More")).firstMatch
        XCTAssertTrue(poll(timeout: 15, interval: 0.2, "Apple Share actions") { copy.exists || more.exists })
        // At accessibility text sizes iOS groups actions behind View More.
        if !copy.exists { more.tap() }
        XCTAssertTrue(copy.appears(within: 15), "Apple Share sheet did not open: \(app.debugDescription)")
        Screenshots.capture(app, "lightning-02-apple-share", testCase: self)
        copy.tap()
        XCTAssertTrue(try waitForSharedOffer(copy: copy, expected: offer),
                      "Apple Share did not copy the exact offer and dismiss within 15 seconds: \(app.debugDescription)")
        try killed(app, response: rpc("kill", values: ["role": "recipient"]))

        try launch(app, role: "sender", fresh: true)
        try fundWallet(app)
        try configure(app, profile: XCTUnwrap(setup["sender"] as? [String: Any]))
        try waitConnected(app)
        let capacity = app.textFields["lightningCapacity"]
        XCTAssertTrue(scroll(app, capacity, fullyVisible: true))
        app.typeInto("lightningCapacity", "100000", dismissKeyboardAfterTyping: false)
        XCTAssertTrue(dismissLightningKeyboard(app, action: "lightningCapacityHideKeyboard"), app.debugDescription)
        XCTAssertEqual(capacity.value as? String, "100000")
        XCTAssertTrue(NSPredicate(format: "hasKeyboardFocus == false").evaluate(with: capacity), app.debugDescription)
        XCTAssertEqual(app.keyboards.count, 0)
        tap(app, "lightningOpen")
        let funding = app.buttons["lightningFundingReview"]
        XCTAssertTrue(scroll(app, funding), channelRequestFailure(app))
        XCTAssertTrue(funding.appears(within: 60))
        tap(app, "lightningFundingReview")
        XCTAssertTrue(app.navigationBars["Review Lightning"].appears(within: 20))
        Screenshots.capture(app, "lightning-03-funding-review", testCase: self)
        // Canceling review leaves no transaction in the independent node.
        app.buttons["lightningCancel"].tap()
        _ = try rpc("assert_no_funding")
        tap(app, "lightningFundingReview")
        tap(app, "lightningConfirm")
        _ = try rpc("confirm_funding")
        XCTAssertTrue(poll(timeout: verifiedChainTimeout, interval: 1, "app verifies channel funding") {
            app.staticTexts["lightningChannelPhase"].label.contains("ready")
        })
        try paste(offer)
        tap(app, "lightningSend")
        tap(app, "lightningPasteOffer")
        XCTAssertTrue(scroll(app, app.textFields["lightningAmount"], fullyVisible: true))
        app.typeInto("lightningAmount", "5000", dismissKeyboardAfterTyping: false)
        let keyboardDismissed = dismissLightningKeyboard(app, action: "lightningOfferHideKeyboard")
        if !keyboardDismissed {
            Screenshots.capture(app, "async-payment-keyboard-failure", testCase: self)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "async-payment-keyboard-failure-hierarchy.txt"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(keyboardDismissed, app.debugDescription)
        XCTAssertTrue(app.navigationBars["Pay receive offer"].exists,
                      "Hide keyboard must keep the payment input open: \(app.debugDescription)")
        XCTAssertEqual(app.textFields["lightningAmount"].value as? String, "5000")
        XCTAssertTrue(NSPredicate(format: "hasKeyboardFocus == false").evaluate(with: app.textFields["lightningAmount"]), app.debugDescription)
        XCTAssertEqual(app.keyboards.count, 0)
        tap(app, "lightningReviewPayment")
        XCTAssertTrue(app.navigationBars["Review Lightning"].appears(within: 15), app.debugDescription)
        for row in ["Amount, 5000 sats", "Maximum fee, 50 sats", "Maximum expiry, 2016 blocks"] {
            XCTAssertTrue(scroll(app, app.staticTexts[row], fullyVisible: true))
        }
        Screenshots.capture(app, "lightning-04-payment-review", testCase: self)
        tap(app, "lightningConfirm")
        XCTAssertTrue(app.navigationBars["Review Lightning"].disappears(within: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["lightningSendDone"].disappears(within: 15), app.debugDescription)
        XCTAssertTrue(scroll(app, app.staticTexts["Awaiting recipient"]))
        XCTAssertTrue(app.staticTexts["Awaiting recipient"].appears(within: 60))
        XCTAssertFalse(app.staticTexts["Settled"].exists)
        Screenshots.capture(app, "lightning-05-awaiting-offline-recipient", testCase: self)
        try killed(app, response: rpc("hold_and_kill"))

        try launch(app, role: "recipient", fresh: false)
        XCTAssertTrue(scroll(app, app.staticTexts["Settled"]))
        XCTAssertTrue(app.staticTexts["Settled"].appears(within: 90))
        let settled = try rpc("recipient_settled")
        let hash = try XCTUnwrap(settled["hash"] as? String)
        try verifyHash(app, hash: hash)
        Screenshots.capture(app, "lightning-06-recipient-settled-sender-stopped", testCase: self)
        try killed(app, response: rpc("kill", values: ["role": "recipient"]))

        try launch(app, role: "sender", fresh: false)
        XCTAssertTrue(scroll(app, app.staticTexts["Settled"]))
        XCTAssertTrue(app.staticTexts["Settled"].appears(within: 90))
        try verifyHash(app, hash: hash)
        XCTAssertEqual(app.staticTexts.matching(identifier: "lightningPaymentHash." + hash).count, 1, "settlement duplicated on sender restart")
        Screenshots.capture(app, "lightning-07-sender-reconciled-once", testCase: self)
        _ = try rpc("finish")
        tap(app, "lightningClose", up: true)
        let closeReviewAppeared = app.navigationBars["Review Lightning"].appears(within: 60)
        if !closeReviewAppeared {
            Screenshots.capture(app, "lightning-close-review-failed", testCase: self)
        }
        XCTAssertTrue(closeReviewAppeared, app.debugDescription)
        XCTAssertTrue(scroll(app, app.staticTexts["Maximum negotiated fee, 905 sats"], fullyVisible: true))
        Screenshots.capture(app, "lightning-08-close-review", testCase: self)
        tap(app, "lightningConfirm")
        XCTAssertTrue(app.navigationBars["Review Lightning"].disappears(within: 30), app.debugDescription)
        let closed = try rpc("mine_close")
        let expectedBalance = try XCTUnwrap(closed["expected_balance"] as? Int64)
        selectTab(app, "Wallet")
        XCTAssertTrue(poll(timeout: verifiedChainTimeout, interval: 1, "wallet discovers returned channel funds") {
            Int64(self.balanceText(app).filter(\.isNumber)) == expectedBalance
        })
        Screenshots.capture(app, "lightning-09-returned-wallet-funds", testCase: self)
    }

    func testBolt11InvoiceFromSimpleSendSettlesAndSurvivesRestart() throws {
        continueAfterFailure = false
        executionTimeAllowance = 600
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["WINNOW_LIGHTNING_UI_FIXTURE"])
        config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        setup = try rpc("invoice_fixture")
        control = FileManager.default.temporaryDirectory.appending(path: "invoice-control-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: control) }
        let app = XCUIApplication(); defer { app.terminate() }
        try launch(app, role: "sender", fresh: true)
        try fundWallet(app)
        try configure(app, profile: XCTUnwrap(setup["sender"] as? [String: Any]))
        try waitConnected(app)
        XCTAssertTrue(scroll(app, app.textFields["lightningCapacity"], fullyVisible: true))
        app.typeInto("lightningCapacity", "100000", dismissKeyboardAfterTyping: false)
        XCTAssertTrue(dismissLightningKeyboard(app, action: "lightningCapacityHideKeyboard"), app.debugDescription)
        XCTAssertEqual(app.textFields["lightningCapacity"].value as? String, "100000")
        XCTAssertTrue(NSPredicate(format: "hasKeyboardFocus == false").evaluate(with: app.textFields["lightningCapacity"]), app.debugDescription)
        XCTAssertEqual(app.keyboards.count, 0)
        tap(app, "lightningOpen"); tap(app, "lightningFundingReview")
        XCTAssertTrue(app.navigationBars["Review Lightning"].appears(within: 30), app.debugDescription)
        tap(app, "lightningConfirm")
        requireFundingReviewConfirmed(app)
        _ = try rpc("confirm_funding")
        XCTAssertTrue(poll(timeout: verifiedChainTimeout, interval: 1, "invoice channel verified") {
            app.staticTexts["lightningChannelPhase"].label.contains("ready")
        })
        let invoice = try rpc("bolt11_invoice"), text = try XCTUnwrap(invoice["bolt11"] as? String)
        selectTab(app, "Wallet"); app.buttons["advancedModeButton"].tap()
        tap(app, "openSendButton"); tap(app, "sendLightning")
        tap(app, "lightningScanInvoice")
        XCTAssertTrue(app.staticTexts["Camera scanning unavailable"].appears(within: 15))
        tapToolbar(app, "lightningScanCancel")
        XCTAssertTrue(app.buttons["lightningScanCancel"].disappears(within: 10), app.debugDescription)
        try paste("LIGHTNING:" + text); tap(app, "lightningPasteInvoice")
        tap(app, "lightningReviewInvoice")
        XCTAssertTrue(app.navigationBars["Review Lightning"].appears(within: 30), app.debugDescription)
        // The invoice form underneath the review also shows this amount.
        // Read the presented Form, not a globally ambiguous static-text query.
        let reviewForm = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
        XCTAssertTrue(scroll(app, reviewForm.staticTexts["Amount, 2000 sats"], fullyVisible: true))
        Screenshots.capture(app, "bolt11-payment-review", testCase: self)
        app.buttons["lightningCancel"].tap(); _ = try rpc("assert_invoice_unpaid")
        tap(app, "lightningReviewInvoice"); tap(app, "lightningConfirm")
        XCTAssertTrue(poll(timeout: 90, interval: 1, "ordinary invoice settled") {
            app.staticTexts["lightningInvoicePaymentStatus"].label == "Settled"
        }, app.debugDescription)
        let receipt = try rpc("invoice_settled"), hash = try XCTUnwrap(receipt["payment_hash"] as? String)
        Screenshots.capture(app, "bolt11-settled", testCase: self)
        tapToolbar(app, "lightningInvoiceSendDone")
        XCTAssertTrue(app.buttons["lightningInvoiceSendDone"].disappears(within: 10), app.debugDescription)
        tapToolbar(app, "closeSendButton")
        XCTAssertTrue(app.buttons["closeSendButton"].disappears(within: 10), app.debugDescription)
        app.buttons["advancedModeButton"].tap()
        XCTAssertTrue(app.alerts["Turn on Advanced mode?"].appears(within: 10))
        app.alerts["Turn on Advanced mode?"].buttons["Turn on"].tap()
        XCTAssertTrue(app.buttons["Lightning"].appears(within: 10), app.debugDescription)
        // Restore the same wallet and invoice history in a new process.
        app.terminate()
        try launch(app, role: "sender", fresh: false)
        try verifyHash(app, hash: hash)
        XCTAssertEqual(app.staticTexts.matching(identifier: "lightningPaymentHash." + hash).count, 1)
        Screenshots.capture(app, "bolt11-restored-once", testCase: self)
    }

    private func selectTab(_ app: XCUIApplication, _ name: String) {
        // iPadOS 18 exposes the top tab strip outside the TabBar hierarchy.
        let button = app.buttons[name].firstMatch
        XCTAssertTrue(button.appears(within: 60), app.debugDescription)
        button.tap()
    }
    private func launch(_ app: XCUIApplication, role: String, fresh: Bool) throws {
        let run = try XCTUnwrap(setup["run"] as? String)
        app.launchEnvironment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": run + "-" + role,
            "WINNOW_E2E_NETWORK": "regtest", "WINNOW_E2E_ENTROPY": String(repeating: role == "recipient" ? "02" : (setup["sender_entropy"] as? String ?? "01"), count: 16),
            "WINNOW_E2E_PEER": try XCTUnwrap(setup["bitcoin_peer"] as? String), "WINNOW_E2E_PEER_COUNT": "1",
            "WINNOW_E2E_SYNC_INTERVAL": "3", "WINNOW_E2E_TAB": "lightning", "WINNOW_E2E_CONTROL_FILE": control.path,
            // The journey drives the Lightning tab, which Advanced mode shows.
            "WINNOW_E2E_ADVANCED": "1"]
        if fresh { app.launchEnvironment["WINNOW_E2E_RESET"] = "1" }
        app.launch()
        if fresh {
            tap(app, "createWalletButton")
        }
        selectTab(app, "Lightning")
        let node = app.staticTexts["lightningNodeID"]
        XCTAssertTrue(scroll(app, node))
        XCTAssertTrue(poll(timeout: 30, interval: 0.2, "durable node identity") { (node.value as? String)?.count == 66 })
        _ = try rpc("register", values: ["role": role, "node": XCTUnwrap(node.value as? String)])
    }
    private func configure(_ app: XCUIApplication, profile: [String: Any], up: Bool = true) throws {
        try paste(String(decoding: JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys]), as: UTF8.self))
        tap(app, "lightningSetup", up: up)
        tap(app, "lightningPasteProfile")
        tap(app, "lightningReviewProfile")
        XCTAssertTrue(app.navigationBars["Review Lightning"].appears(within: 15))
        tap(app, "lightningConfirm")
        try dismissInput(app, done: "lightningSetupDone")
    }
    private func dismissInput(_ app: XCUIApplication, done: String) throws {
        XCTAssertTrue(app.buttons["lightningConfirm"].disappears(within: 30), app.debugDescription)
        let button = app.buttons[done]
        XCTAssertTrue(poll(timeout: 15, interval: 0.2, "input sheet is visible after approval") { button.isHittable })
        XCTAssertTrue(tapVisibleCenter(app, button, excludingBars: false))
        XCTAssertTrue(button.disappears(within: 15))
    }
    /// A channel request that produced no funding review: the app's own error.
    private func channelRequestFailure(_ app: XCUIApplication) -> String {
        let error = app.staticTexts["lightningError"]
        guard scroll(app, error, up: true) else { return "no funding request and no app error shown: \(app.debugDescription)" }
        return "no funding request: \(error.label)"
    }
    private func waitConnected(_ app: XCUIApplication) throws {
        let connection = app.descendants(matching: .any)["lightningConnection"].firstMatch
        XCTAssertTrue(scroll(app, connection, up: true))
        XCTAssertTrue(poll(timeout: 90, interval: 0.5, "authenticated provider connection") {
            connection.value as? String == "Connected"
        }, connection.debugDescription)
    }
    private func fundWallet(_ app: XCUIApplication) throws {
        selectTab(app, "Wallet")
        // Receive is a navigation-bar action in the advanced wallet. Form
        // scrolling deliberately excludes the navigation bar from its band.
        XCTAssertTrue(app.buttons["receiveButton"].appears(within: 20))
        app.buttons["receiveButton"].tap()
        XCTAssertTrue(app.buttons["receiveBitcoin"].appears(within: 10))
        app.buttons["receiveBitcoin"].tap()
        tap(app, "skipReceiveAddressLabelButton")
        XCTAssertTrue(scroll(app, app.staticTexts["receiveAddress"]))
        let address = try XCTUnwrap(app.staticTexts["receiveAddress"].value as? String)
        _ = try AddressDecoder.scriptPubKey(for: address, network: .regtest)
        app.buttons["Done"].tap()
        _ = try rpc("fund_wallet", values: ["address": address])
        XCTAssertTrue(poll(timeout: verifiedChainTimeout, interval: 1, "Winnow discovers regtest funding") {
            Int64(self.balanceText(app).filter(\.isNumber)) == 2_000_000
        })
        selectTab(app, "Lightning")
    }
    private func scroll(_ app: XCUIApplication, _ element: XCUIElement,
                        up: Bool = false, fullyVisible: Bool = false) -> Bool {
        // At accessibility sizes a centered drag can land in a TextEditor and
        // scroll its contents. The form gutter moves the surrounding controls.
        // On iPad the modal form is centered within the wider app surface.
        return scrollUntilExists(app, element, up: up, fullyVisible: fullyVisible,
                                 dragX: 0.03)
    }
    private func dismissLightningKeyboard(_ app: XCUIApplication, action: String) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        // Activate the field-owned navigation action, outside keyboard windows.
        // System Hide and generic fallbacks do not establish app focus clearing.
        var activated = false
        for _ in 0..<2 {
            guard deadline.timeIntervalSinceNow > 0 else { break }
            let done = app.buttons[action]
            let popup = app.windows.containing(.keyboard, identifier: nil)
                .otherElements["PopoverDismissRegion"].firstMatch
            let dismissingPopup = popup.exists
            guard done.exists, done.isEnabled, tapVisibleCenter(app, done, excludingBars: false) else { break }
            activated = true
            // iPad's numeric popover consumes the first outside activation.
            // Wait for that observed modal region to leave before activating
            // the app's Hide action again; both share the original deadline.
            if dismissingPopup {
                let remaining = max(0, deadline.timeIntervalSinceNow)
                guard popup.disappears(within: remaining) else { return false }
            }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            if app.keyboards.firstMatch.disappears(within: min(1, remaining)),
               app.keyboards.count == 0 { return true }
        }
        let remaining = max(0, deadline.timeIntervalSinceNow)
        return activated && app.keyboards.firstMatch.disappears(within: remaining) && app.keyboards.count == 0
    }
    private func requireFundingReviewConfirmed(_ app: XCUIApplication) {
        let review = app.navigationBars["Review Lightning"]
        let error = app.staticTexts["lightningReviewError"]
        let deadline = Date().addingTimeInterval(30)
        while review.exists && !error.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: min(0.2, max(0, deadline.timeIntervalSinceNow)))
        }
        // Keep the actual local rejection before a fatal assertion or the
        // host's mempool wait. A synthesized tap is not successful approval.
        let errorText = error.exists ? error.label : "Funding review did not close after confirmation."
        let confirmed = !review.exists && !error.exists
        if !confirmed {
            Screenshots.capture(app, "bolt11-funding-confirmation-failure", testCase: self)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "bolt11-funding-confirmation-hierarchy.txt"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(confirmed, errorText)
    }
    private func tapToolbar(_ app: XCUIApplication, _ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.appears(within: 15), app.debugDescription)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(tapVisibleCenter(app, button, excludingBars: false), app.debugDescription)
    }
    private func tap(_ app: XCUIApplication, _ identifier: String, up: Bool = false) {
        let button = app.buttons[identifier]
        XCTAssertTrue(scroll(app, button, up: up), app.debugDescription)
        XCTAssertTrue(button.isEnabled)
        // Use the real center: SwiftUI may expose an incorrect activation
        // point for a button. iPad's last row can fit the window without
        // fitting the helper's extra home-indicator margin.
        if !tapVisibleCenter(app, button, excludingBars: true) {
            XCTAssertTrue(scroll(app, button, up: up, fullyVisible: true), app.debugDescription)
            XCTAssertTrue(tapVisibleCenter(app, button, excludingBars: true))
        }
    }
    private func verifyHash(_ app: XCUIApplication, hash: String) throws {
        let value = app.staticTexts["lightningPaymentHash." + hash]
        XCTAssertTrue(scroll(app, value), app.debugDescription)
        XCTAssertEqual(value.value as? String, hash)
    }
    private func paste(_ text: String) throws {
        try JSONEncoder().encode(["clipboard": text]).write(to: control, options: .atomic)
    }
    private func killed(_ app: XCUIApplication, response: [String: Any]) throws {
        XCTAssertEqual(response["signal"] as? String, "SIGKILL")
        XCTAssertEqual(response["running"] as? Bool, false, "host must verify the real PID has exited")
        // Discard XCTest's cached running state only after the host has killed
        // and reaped the process. This is not the crash mechanism.
        app.terminate()
    }
    private func waitForSharedOffer(copy: XCUIElement,
                                    expected: String) throws -> Bool {
        try SharedClipboard.wait(expected: expected, timeout: 15,
                                 read: { remaining in try clipboard(timeout: remaining) },
                                 isShareDismissed: { !copy.exists })
    }
    private func clipboard(timeout: TimeInterval = 120) throws -> String {
        // The test runner is a background app and cannot read another app's
        // pasteboard on current iOS. Inspect the actual simulator pasteboard.
        try XCTUnwrap(rpc("clipboard", timeout: timeout)["text"] as? String)
    }
    private func rpc(_ command: String, values: [String: String] = [:],
                     timeout: TimeInterval = 120) throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: values.merging(["command": command]) { _, new in new })
        let response = try HostProcess.run("/usr/bin/curl", ["--silent", "--show-error", "--fail", "--max-time", String(timeout), "-X", "POST",
            "-H", "Authorization: Bearer " + XCTUnwrap(config["token"]), "-H", "Content-Type: application/json",
            "--data-binary", "@-", XCTUnwrap(config["url"])], input: input)
        XCTAssertEqual(response.status, 0, response.stderr)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(value["ok"] as? Bool, true, String(describing: value["error"]))
        return try XCTUnwrap(value["result"] as? [String: Any])
    }
}

// MARK: - Form helpers for the Lightning sheets

/// Lightning's forms are often modal sheets, on iPad only part of the window,
/// and at accessibility sizes a centered drag can land in a TextEditor. These
/// variants of the shared helpers (TestHelpers.swift) drag and tap inside
/// the presented form, at a chosen horizontal position.
@MainActor
private extension XCTestCase {
    @discardableResult
    func scrollUntilExists(_ app: XCUIApplication, _ element: XCUIElement,
                           maxSwipes: Int = 16, up: Bool = false, fullyVisible: Bool = false,
                           dragX: CGFloat) -> Bool {
        for _ in 0 ..< maxSwipes {
            if element.appears(within: 1.5) {
                guard fullyVisible else { return true }
                return reveal(app, element, fullyVisible: fullyVisible, dragX: dragX)
            }
            guard let appFrame = usableFrame(app), let frame = formFrame(app, within: appFrame),
                  let band = formBand(app, in: frame) else { return false }
            let reach = band.upperBound - band.lowerBound
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: frame.minX + frame.width * dragX - appFrame.minX,
                dy: band.lowerBound + reach * (up ? 0.25 : 0.75) - appFrame.minY))
            let end = origin.withOffset(CGVector(dx: frame.minX + frame.width * dragX - appFrame.minX,
                dy: band.lowerBound + reach * (up ? 0.75 : 0.25) - appFrame.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.25)
        }
        guard element.appears(within: 1.5) else { return false }
        guard fullyVisible else { return true }
        return reveal(app, element, fullyVisible: fullyVisible, dragX: dragX)
    }

    /// Taps the visible part of `element`, optionally only where no bar
    /// covers the presented form.
    func tapVisibleCenter(_ app: XCUIApplication, _ element: XCUIElement, excludingBars: Bool) -> Bool {
        guard let appFrame = usableFrame(app), let frame = usableFrame(element) else { return false }
        var viewport = appFrame
        if excludingBars {
            guard let form = formFrame(app, within: appFrame), let band = formBand(app, in: form) else { return false }
            viewport = CGRect(x: form.minX, y: band.lowerBound,
                              width: form.width, height: band.upperBound - band.lowerBound)
        }
        let visible = frame.intersection(viewport)
        guard !visible.isNull, visible.width > 0,
              visible.height >= min(frame.height, 24) else {
            print("Tap target outside visible area: app=\(appFrame), target=\(frame), viewport=\(viewport)")
            return false
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: visible.midX - appFrame.minX, dy: visible.midY - appFrame.minY))
            .tap()
        return true
    }

    /// The last Form belongs to the presented navigation stack. On iPad its
    /// sheet occupies only part of the window; drags outside it hit the dimmed
    /// wallet instead of scrolling the form.
    func formFrame(_ app: XCUIApplication, within frame: CGRect) -> CGRect? {
        guard let snapshot = try? app.snapshot() else { return nil }
        func forms(_ node: XCUIElementSnapshot) -> [CGRect] {
            (node.elementType == .collectionView ? [node.frame] : []) + node.children.flatMap(forms)
        }
        return forms(snapshot).last.map { $0.intersection(frame) } ?? frame
    }

    /// Where a form row is tappable: below the lowest navigation bar, clear of
    /// a tab strip above and of the tab bar, keyboard and home indicator below.
    func formBand(_ app: XCUIApplication, in frame: CGRect) -> ClosedRange<CGFloat>? {
        guard let snapshot = try? app.snapshot() else {
            XCTFail("could not snapshot the app's navigation bars")
            return nil
        }
        var top = max(frame.minY, navigationBarBottom(snapshot) ?? frame.minY)
        // A tall accessibility row can use the entire drag band. Keep its
        // starting point above the home indicator, where a swipe exits the
        // app instead of scrolling a modal sheet.
        var bottom = frame.maxY - 34
        for cover in [app.tabBars.firstMatch, app.keyboards.firstMatch] where cover.exists && cover.isHittable {
            if cover.frame.maxY < frame.midY {
                top = max(top, cover.frame.maxY)
            } else {
                bottom = min(bottom, cover.frame.minY)
            }
        }
        return top ... max(top, bottom)
    }

    func reveal(_ app: XCUIApplication, _ element: XCUIElement, fullyVisible: Bool, dragX: CGFloat) -> Bool {
        let margin: CGFloat = 8
        guard let appFrame = usableFrame(app),
              let viewport = formFrame(app, within: appFrame),
              let band = formBand(app, in: viewport) else { return false }
        let reach = band.upperBound - band.lowerBound - 2 * margin
        guard reach.isFinite, reach > 0 else { return false }
        for attempt in 0 ... 3 {
            guard let frame = usableFrame(element, within: 1.5) else { return false }
            let shift = revealShift(frame, in: band, margin: margin, reach: reach)
            if shift == 0 {
                return !fullyVisible || (frame.minX >= viewport.minX && frame.maxX <= viewport.maxX
                    && frame.minY >= band.lowerBound + margin && frame.maxY <= band.upperBound - margin)
            }
            guard attempt < 3 else { return false }
            let midY = (band.lowerBound + band.upperBound) / 2
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: viewport.minX + viewport.width * dragX - appFrame.minX,
                                     dy: midY - shift / 2 - appFrame.minY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: shift)),
                        withVelocity: .default, thenHoldForDuration: 0.25)
        }
        return false
    }
}

@MainActor
private extension XCUIApplication {
    /// `typeInto` without its keyboard dismissal: the Lightning forms dismiss
    /// through their own Hide keyboard action.
    func typeInto(_ identifier: String, _ text: String, dismissKeyboardAfterTyping: Bool) {
        guard !dismissKeyboardAfterTyping else {
            typeInto(identifier, text)
            return
        }
        var field = textFields[identifier]
        if !field.exists { field = textViews[identifier] }
        XCTAssertTrue(field.appears(within: 20), "no text field \(identifier)")
        var focused = false
        for _ in 1...3 where !focused {
            field.tap()
            focused = field.waitForKeyboardFocus(timeout: 3)
        }
        XCTAssertTrue(focused, "\(identifier) never took keyboard focus")
        field.typeText(text)
    }
}
