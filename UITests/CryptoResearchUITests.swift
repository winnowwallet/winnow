import XCTest

@MainActor
final class CryptoResearchUITests: XCTestCase {
    func testPublicExamplesKeepWarningVisibleAndDoNotOfferWalletInputs() {
        checkPublicExamples()
    }

    func testWarningAndResultsAtLargestAccessibilityTextSize() {
        checkPublicExamples(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    private func checkPublicExamples(contentSize: String? = nil) {
        continueAfterFailure = false
        let app = XCUIApplication()
        if let contentSize {
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launchEnvironment = [
            "WINNOW_E2E": "1", "WINNOW_E2E_RUN": "crypto-research",
            "WINNOW_E2E_RESET": "1", "WINNOW_E2E_ENTROPY": "00000000000000000000000000000000",
            "WINNOW_E2E_ADVANCED": "1", "WINNOW_E2E_TAB": "settings",
            "WINNOW_E2E_PEER": "127.0.0.1:1", "WINNOW_E2E_CHALLENGE": "51",
        ]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(scrollUntilExists(app, app.buttons["createWalletButton"], fullyVisible: true))
        app.buttons["createWalletButton"].tap()
        let entry = app.buttons["cryptoResearchLink"]
        XCTAssertTrue(scrollUntilExists(app, entry, maxSwipes: 64, fullyVisible: true))
        entry.tap()
        let warning = app.staticTexts["cryptoResearchWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        XCTAssertTrue(warning.isHittable)
        XCTAssertTrue(app.staticTexts["cryptoResearchWarningDetail"].isHittable)
        XCTAssertEqual(app.textFields.count, 0)
        XCTAssertEqual(app.secureTextFields.count, 0)
        let run = app.buttons["cryptoResearchRun"]
        XCTAssertTrue(scrollUntilExists(app, run, fullyVisible: true))
        run.tap()
        let summary = app.staticTexts["cryptoResearchSummary"]
        XCTAssertTrue(scrollUntilExists(app, summary, fullyVisible: contentSize == nil))
        XCTAssertEqual(summary.label, "318 of 318 bundled examples matched")
        XCTAssertTrue(warning.isHittable, "The warning stays visible when results are scrolled into view.")
        XCTAssertTrue(app.staticTexts["cryptoResearchWarningDetail"].isHittable)
        XCTAssertTrue(scrollUntilExists(app, app.staticTexts["cryptoResearchResultLimit"], fullyVisible: contentSize == nil))
        XCTAssertTrue(warning.isHittable)
        XCTAssertTrue(app.staticTexts["cryptoResearchWarningDetail"].isHittable)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Experimental public-data results and persistent warning"
        capture.lifetime = .keepAlways
        add(capture)
    }
}
