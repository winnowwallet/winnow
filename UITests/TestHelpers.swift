import Foundation
import TestSupport
import XCTest

/// Screenshot capture: XCTAttachment on the test result AND a PNG copy on the
/// host. CI supplies WINNOW_SCREENSHOT_DIR; local runs use a fresh temporary
/// directory. Captures never write directly into the public website.
enum Screenshots {
    static let directory: URL = {
        if let path = BitcoinCLI.environmentValue("WINNOW_SCREENSHOT_DIR"), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.temporaryDirectory
            .appending(path: "winnow-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
    }()

    @MainActor
    static func capture(_ app: XCUIApplication, _ name: String, testCase: XCTestCase) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)

        let destination = directory.appending(path: "\(name).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: destination)
        } catch {
            // Direct host-path writes can be refused from the sim container;
            // fall back to host-side mkdir+cp via a spawned process.
            do {
                let staging = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "\(name).png")
                try screenshot.pngRepresentation.write(to: staging)
                let mkdir = try HostProcess.run("/bin/mkdir", ["-p", directory.path])
                let copy = try HostProcess.run("/bin/cp", [staging.path, destination.path])
                if mkdir.status != 0 || copy.status != 0 {
                    XCTFail("could not save \(name).png to \(destination.path): \(mkdir.stderr)\(copy.stderr)")
                }
            } catch {
                XCTFail("could not save \(name).png to \(destination.path): \(error.localizedDescription)")
            }
        }
    }
}

extension XCTestCase {
    /// Text of the balance label ("12,345 sats").
    @MainActor
    func balanceText(_ app: XCUIApplication) -> String {
        (app.staticTexts["balanceText"].value as? String) ?? ""
    }

    /// Taps "Sync now" when idle to nudge a scan pass.
    @MainActor
    func nudgeSync(_ app: XCUIApplication) {
        let button = app.buttons["syncNowButton"]
        if button.exists, button.isEnabled { button.tap() }
    }

    /// Scrolls the topmost scroll view until `element` exists (SwiftUI
    /// Forms materialize rows lazily — `exists` is false below the fold).
    /// Uses screen-coordinate drags: a TabView keeps every tab's list in the
    /// accessibility tree, so element-based swipes can hit a hidden tab's
    /// list instead of the visible form.
    @MainActor
    @discardableResult
    func scrollUntilExists(_ app: XCUIApplication, _ element: XCUIElement,
                           maxSwipes: Int = 10, up: Bool = false, fullyVisible: Bool = false) -> Bool {
        func ready() -> Bool {
            guard element.exists else { return false }
            guard fullyVisible else { return true }
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : app.frame.minY
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY
            return element.isHittable && element.frame.minY >= top && element.frame.maxY <= bottom
        }
        for _ in 0 ... maxSwipes {
            // Long enough for a row to materialise after a swipe animates on
            // a slow CI VM, short enough that a row several swipes down does
            // not cost many seconds of waiting per swipe.
            _ = element.waitForExistence(timeout: 1.5)
            if ready() { return true }
            // iPad forms are centered sheets. A drag at 30% of the whole
            // display can land on the sheet's navigation bar instead of its
            // content, moving the sheet without scrolling its fields.
            let modal = app.collectionViews.allElementsBoundByIndex.last { view in
                view.exists && view.frame.width > 0 && view.frame.width < app.frame.width * 0.9
                    && view.frame.height > 100 && app.frame.intersects(view.frame)
            }
            let surface: XCUIElement = modal ?? app
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.30 : 0.62))
            let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.62 : 0.30))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return ready()
    }

    /// The sync-progress section can put confirmation below an iPad sheet's
    /// visible rows. First await the sheet, then scroll its actual content.
    @MainActor
    func backupConfirmationIsReachable(_ app: XCUIApplication) -> Bool {
        guard app.navigationBars["Wallet backup"].waitForExistence(timeout: 30) else { return false }
        return scrollUntilExists(app, app.switches["writtenDownToggle"], maxSwipes: 5)
    }

    @MainActor
    func confirmBackupAndContinue(_ app: XCUIApplication) -> Bool {
        let toggle = app.switches["writtenDownToggle"]
        guard backupConfirmationIsReachable(app) else { return false }
        let confirmed = poll(timeout: 20, interval: 1, "backup confirmation switched on") {
            let thumb = toggle.children(matching: .switch).firstMatch
            if (thumb.exists ? thumb.value : toggle.value) as? String == "1" { return true }
            app.flipSwitch(toggle)
            return false
        }
        guard confirmed else { return false }
        let done = app.buttons["backupDoneButton"]
        guard scrollUntilExists(app, done, maxSwipes: 5),
              poll(timeout: 10, interval: 1, "backup Done enabled", condition: { done.isEnabled }) else { return false }
        done.tap()
        return true
    }

    /// Polls `condition` until it holds or the deadline passes (explicit
    /// waits, no fixed sleeps — the one allowed exception is the polling
    /// interval itself).
    @discardableResult
    func poll(timeout: TimeInterval, interval: TimeInterval = 2,
              _ message: String = "condition", condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: interval)
        }
        let result = condition()
        if !result { XCTFail("timed out (\(timeout)s) waiting for: \(message)") }
        return result
    }
}

extension XCTestCase {
    /// Sends `app` through a real background transition and brings it back.
    /// A bare home-press followed immediately by `activate()` can complete
    /// before the scene ever reaches `.background` (observed on the iOS 26.5
    /// simulator), and every dismissal invariant in the app keys on that
    /// phase — so a test that skips the transition is not exercising the
    /// invariant, just racing it.
    @MainActor
    func backgroundAndReturn(_ app: XCUIApplication) {
        // Not a home-press: on the iOS 26.5 simulator a home-press leaves the
        // scene fully foregrounded, so the `.background` phase the dismissal
        // invariants key on never arrives. Foregrounding another app
        // backgrounds ours for real. The transition is awaited on the
        // Settings side because our app's `state` keeps reporting
        // .runningForeground through the whole round trip on that simulator.
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 15),
                      "Settings did not come to the foreground")
        // The scene phase lands in the app just after it leaves the screen;
        // give it a beat before returning.
        Thread.sleep(forTimeInterval: 1)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15),
                      "app did not return to the foreground")
    }
}

extension XCUIApplication {
    /// Types into a field (TextField or TextEditor) and dismisses the
    /// software keyboard afterwards.
    @MainActor
    func typeInto(_ identifier: String, _ text: String) {
        var field = textFields[identifier]
        if !field.exists { field = textViews[identifier] }
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no text field \(identifier)")
        field.tap()
        field.typeText(text)
        dismissKeyboard()
    }

    @MainActor
    func dismissKeyboard() {
        guard keyboards.firstMatch.exists else { return }
        let returnKey = keyboards.buttons["return"]
        if returnKey.exists, returnKey.isHittable {
            returnKey.tap()
            return
        }
        // Keypads without a return key get an input-accessory Done button
        // (a toolbar floating above the keyboard).
        let toolbarDone = toolbars.buttons["Done"]
        if toolbarDone.waitForExistence(timeout: 2), toolbarDone.isHittable {
            toolbarDone.tap()
            return
        }
        let doneKey = keyboards.buttons["Done"]
        if doneKey.exists, doneKey.isHittable {
            doneKey.tap()
            return
        }
        // Last resort: tapping the navigation bar dismisses the keyboard
        // without triggering any control.
        navigationBars.firstMatch.tap()
        if keyboards.firstMatch.exists {
            collectionViews.firstMatch.swipeDown()
        }
    }

    /// iOS 26 SwiftUI quirk: a Toggle in a Form/List surfaces as a container
    /// switch element wrapping the real UISwitch child; tapping the container
    /// does nothing. Taps the child switch (or the row's right edge).
    @MainActor
    func flipSwitch(_ container: XCUIElement) {
        let thumb = container.children(matching: .switch).firstMatch
        if thumb.exists {
            thumb.tap()
        } else {
            container.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }
}

@MainActor
extension XCUIApplication {
    /// iPadOS exposes its floating tabs as cells instead of an iPhone TabBar.
    /// Keep the same asserted journeys on each platform's native tab layout.
    func navigationTab(_ title: String) -> XCUIElement {
        let phone = tabBars.buttons[title]
        if phone.exists { return phone }
        let floating = cells[title].firstMatch
        if floating.exists { return floating }
        return buttons[title].firstMatch
    }
}
