import XCTest

@MainActor
final class PeerGatewaySettingsTests: XCTestCase {
    func testExternalSelectionPersistsWithoutEmbeddedTor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "WINNOW_E2E": "1", "WINNOW_E2E_RUN": "gateways-\(UUID().uuidString)",
            "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f",
            "WINNOW_E2E_RESET": "1", "WINNOW_E2E_ADVANCED": "1",
            "WINNOW_E2E_CHALLENGE": "51", "WINNOW_E2E_TAB": "settings",
            "WINNOW_E2E_PEER": "127.0.0.1:9", "WINNOW_E2E_TOR_FAILURE": "1"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["createWalletButton"].waitForExistence(timeout: 40))
        app.buttons["createWalletButton"].tap()
        let written = app.switches["writtenDownToggle"]
        XCTAssertTrue(written.waitForExistence(timeout: 30))
        app.flipSwitch(written)
        let done = app.buttons["backupDoneButton"]
        XCTAssertTrue(scrollUntilExists(app, done, maxSwipes: 5))
        done.tap()
        let external = app.switches["externalGatewaysToggle"]
        XCTAssertTrue(scrollUntilExists(app, external, maxSwipes: 8))
        app.flipSwitch(external)
        app.flipSwitch(app.switches["peerType_tor"])
        app.flipSwitch(app.switches["peerType_i2p"])
        let tor = app.textFields["torGatewayAddress"]
        XCTAssertTrue(scrollUntilExists(app, tor, maxSwipes: 5))
        tor.tap(); tor.typeText("100.112.65.68:9050\n")
        let i2p = app.textFields["i2pGatewayAddress"]
        XCTAssertTrue(scrollUntilExists(app, i2p, maxSwipes: 5))
        i2p.tap(); i2p.typeText("100.112.65.68:4447\n")
        let apply = app.buttons["applyPeerRouting"]
        XCTAssertTrue(scrollUntilExists(app, apply, maxSwipes: 5))
        apply.tap()
        XCTAssertTrue(app.staticTexts["External gateway routing is active."].waitForExistence(timeout: 20))
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: apply)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 30), .completed)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "external-peer-gateways"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app.launchEnvironment["WINNOW_E2E_RESET"] = "0"
        app.launch()
        XCTAssertTrue(scrollUntilExists(app, external, maxSwipes: 8))
        XCTAssertEqual(external.value as? String, "1")
        for network in ["clearnet", "tor", "i2p"] {
            XCTAssertEqual(app.switches["peerType_\(network)"].value as? String, "1")
        }
        XCTAssertTrue(scrollUntilExists(app, tor, maxSwipes: 5))
        XCTAssertEqual(tor.value as? String, "100.112.65.68:9050")
        XCTAssertEqual(i2p.value as? String, "100.112.65.68:4447")
        XCTAssertFalse(app.switches["torEnabledToggle"].exists)
        app.terminate()
    }
}
