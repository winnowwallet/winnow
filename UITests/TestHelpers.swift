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
    /// Forms materialize rows lazily — `exists` is false below the fold),
    /// then moves it clear of the bars, so a tap that follows lands on the
    /// row and not on a bar drawn over it.
    ///
    /// Drags use screen coordinates: a TabView keeps every tab's list in
    /// the accessibility tree, so element-based swipes can hit a hidden
    /// tab's list instead of the visible form. The finger rests before it
    /// lifts, so the form stops where the drag ends. A flung form stops
    /// wherever its momentum ran out — a stepper left half under the
    /// navigation bar took its tap on the bar — or is still moving when
    /// the next tap arrives, which only stops the scroll.
    ///
    /// Each drag moves half the surface, so `maxSwipes` reaches some 16
    /// screens; a row found without dragging is where the form laid it out
    /// and is returned at once, unless the caller asked for it fully in view.
    @MainActor
    @discardableResult
    func scrollUntilExists(_ app: XCUIApplication, _ element: XCUIElement,
                           maxSwipes: Int = 16, up: Bool = false, fullyVisible: Bool = false) -> Bool {
        var surface: XCUIElement?
        for _ in 0 ..< maxSwipes {
            // Long enough for a row to materialise after a drag animates on
            // a slow CI VM, short enough that a row several drags down does
            // not cost many seconds of waiting per drag.
            if element.waitForExistence(timeout: 1.5) {
                guard fullyVisible || surface != nil else { return true }
                if let revealed = reveal(app, element, on: surface ?? scrollSurface(app), fullyVisible: fullyVisible) {
                    return revealed
                }
                // The nudge carried the row out of the form's window (an
                // iPad sheet drops a row just above its top); keep going.
            }
            let scrolled = surface ?? scrollSurface(app)
            surface = scrolled
            let start = scrolled.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.25 : 0.75))
            let end = scrolled.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.75 : 0.25))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.25)
        }
        guard element.waitForExistence(timeout: 1.5) else { return false }
        return reveal(app, element, on: surface ?? scrollSurface(app), fullyVisible: fullyVisible) ?? false
    }

    /// What the drags scroll: the screen, or on iPad the centered sheet a
    /// form is presented in — a drag at 30% of the whole display can land
    /// on the sheet's navigation bar instead of its content, moving the
    /// sheet without scrolling its fields.
    @MainActor
    private func scrollSurface(_ app: XCUIApplication) -> XCUIElement {
        let modal = app.collectionViews.allElementsBoundByIndex.last { view in
            view.exists && view.frame.width > 0 && view.frame.width < app.frame.width * 0.9
                && view.frame.height > 100 && app.frame.intersects(view.frame)
        }
        return modal ?? app
    }

    /// The vertical band a row is tappable in: below the lowest navigation
    /// bar (a sheet's sits below the screen's), above the tab bar and the
    /// keyboard.
    @MainActor
    private func clearBand(_ app: XCUIApplication, on surface: XCUIElement) -> ClosedRange<CGFloat> {
        let frame = surface.frame
        let barBottoms = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }
        let top = max(frame.minY, barBottoms.max() ?? frame.minY)
        var bottom = frame.maxY
        for cover in [app.tabBars.firstMatch, app.keyboards.firstMatch] where cover.exists {
            bottom = min(bottom, cover.frame.minY)
        }
        return top ... max(top, bottom)
    }

    /// Drags `element` clear of the bars. A row taller than the band shows
    /// its top; `fullyVisible` also asks for it to be hittable. Nil when a
    /// nudge carried the lazily built row out of the form's window, so the
    /// caller scrolls on toward it.
    @MainActor
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, on surface: XCUIElement,
                        fullyVisible: Bool) -> Bool? {
        let margin: CGFloat = 8
        let band = clearBand(app, on: surface)
        let reach = band.upperBound - band.lowerBound - 2 * margin
        for _ in 0 ..< 3 {
            guard element.exists else { return nil }
            let frame = element.frame
            var shift: CGFloat = 0
            if frame.minY < band.lowerBound + margin {
                shift = band.lowerBound + margin - frame.minY
            } else if frame.maxY > band.upperBound - margin, frame.height + 2 * margin < reach {
                shift = band.upperBound - margin - frame.maxY
            }
            guard shift != 0, reach > 0 else { return fullyVisible ? element.isHittable : true }
            // Content moves with the finger; both ends of the drag stay in
            // the band, and a drag too short to start a scroll is made long
            // enough to (a 17-point nudge moved nothing three times over).
            shift = max(-reach, min(reach, shift))
            if abs(shift) < 48 { shift = shift < 0 ? -48 : 48 }
            let midY = (band.lowerBound + band.upperBound) / 2
            let start = surface.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: surface.frame.width / 2, dy: midY - shift / 2 - surface.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: shift)),
                        withVelocity: .default, thenHoldForDuration: 0.25)
        }
        return fullyVisible ? element.isHittable : element.exists
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
    /// does nothing. Taps the child switch (or the row's right edge), and
    /// taps again while the value stays put: a synthesized tap now and then
    /// vanishes on a busy simulator, the switch drawn untouched.
    @MainActor
    func flipSwitch(_ container: XCUIElement) {
        let before = switchValue(container)
        for _ in 1 ... 3 {
            let thumb = container.children(matching: .switch).firstMatch
            if thumb.exists {
                thumb.tap()
            } else {
                container.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            }
            guard let before else { return }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if switchValue(container) != before { return }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        XCTFail("switch \(container.identifier) stayed at \(before ?? "?") through three taps")
    }

    @MainActor
    private func switchValue(_ container: XCUIElement) -> String? {
        let thumb = container.children(matching: .switch).firstMatch
        return (thumb.exists ? thumb.value : container.value) as? String
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
