import XCTest

@MainActor
final class PeerGatewaySettingsUITests: XCTestCase {
    func testManualGatewaySelectionPersistsAndAutomaticCanBeRestored() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [
            "WINNOW_E2E": "1", "WINNOW_E2E_RUN": "gateway-settings",
            "WINNOW_E2E_RESET": "1", "WINNOW_E2E_ENTROPY": "00000000000000000000000000000000",
            "WINNOW_E2E_ADVANCED": "1", "WINNOW_E2E_TAB": "settings",
            "WINNOW_E2E_PEER": "127.0.0.1:1", "WINNOW_E2E_CHALLENGE": "51",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["createWalletButton"].waitForExistence(timeout: 30))
        app.buttons["createWalletButton"].tap()
        let routing = app.buttons["gatewayRoutingMode"]
        XCTAssertTrue(scrollUntilExists(app, routing, fullyVisible: true))
        routing.tap()
        app.buttons["Manual"].tap()
        let tor = app.switches["peerType_tor"]
        XCTAssertTrue(scrollUntilExists(app, tor, fullyVisible: true))
        // SwiftUI exposes the whole labeled row as the switch; target the
        // control at the trailing edge rather than the row's text.
        tor.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(tor.value as? String, "1")
        XCTAssertTrue(scrollUntilExists(app, app.textFields["torGatewayAddress"], fullyVisible: true))
        app.typeInto("torGatewayAddress", "winnow-tor-gateway:9050")
        let apply = app.buttons["applyPeerRouting"]
        XCTAssertTrue(scrollUntilExists(app, apply, fullyVisible: true))
        apply.tap()
        app.terminate()
        app.launchEnvironment["WINNOW_E2E_RESET"] = "0"
        app.launch()
        XCTAssertTrue(scrollUntilExists(app, routing, fullyVisible: true))
        XCTAssertTrue(routing.label.contains("Manual") || routing.value as? String == "Manual")
        let field = app.textFields["torGatewayAddress"]
        XCTAssertTrue(scrollUntilExists(app, field, fullyVisible: true))
        XCTAssertEqual(field.value as? String, "winnow-tor-gateway:9050")
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Manual peer gateway settings"
        capture.lifetime = .keepAlways
        add(capture)
        XCTAssertTrue(scrollUntilExists(app, routing, up: true, fullyVisible: true))
        routing.tap()
        app.buttons["Automatic"].tap()
        XCTAssertTrue(scrollUntilExists(app, apply, fullyVisible: true))
        apply.tap()
        XCTAssertFalse(app.textFields["torGatewayAddress"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(scrollUntilExists(app, routing, fullyVisible: true))
        XCTAssertTrue(routing.label.contains("Automatic") || routing.value as? String == "Automatic")
    }
}
