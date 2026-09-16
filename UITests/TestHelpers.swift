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

    /// Nudges a scan pass: "Sync now" in Advanced mode, a pull to refresh
    /// on the one screen. The pull happens only while that screen is the
    /// frontmost one — over a sheet it would scroll, or on an iPhone
    /// dismiss, the sheet — so a journey waiting inside a sheet waits for
    /// the app's own periodic pass instead.
    @MainActor
    func nudgeSync(_ app: XCUIApplication) {
        let button = app.buttons["syncNowButton"]
        if button.exists {
            if button.isEnabled { button.tap() }
            return
        }
        guard !XCUIApplication.sheetMarkers.contains(where: { app.buttons[$0].exists }) else { return }
        let home = app.buttons["openSendButton"]
        guard home.exists, home.isHittable else { return }
        let list = app.collectionViews.firstMatch
        guard list.exists else { return }
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.3)
    }

    /// The interface in the mode this journey wants, whichever mode the
    /// last journey left it in. A switch made through the UI lands with
    /// the tab bar before its tabs: the journey gets the Wallet tab ready.
    @MainActor
    func ensureMode(_ app: XCUIApplication, advanced: Bool) {
        if app.hasTabs != advanced { setAdvancedMode(app, advanced) }
        if advanced {
            XCTAssertTrue(app.navigationTab("Wallet").waitForExistence(timeout: 15), "no Wallet tab in Advanced mode")
        }
    }

    /// Switches the interface. Turning Advanced on asks first; Simple on
    /// the Advanced Wallet tab brings the one screen back.
    @MainActor
    func setAdvancedMode(_ app: XCUIApplication, _ on: Bool) {
        if on {
            XCTAssertFalse(app.hasTabs, "already in Advanced mode")
            app.goToWallet()
            let advanced = app.buttons["advancedModeButton"]
            XCTAssertTrue(advanced.waitForExistence(timeout: 10), "no Advanced button on the one screen")
            advanced.tap()
            let confirm = app.alerts.buttons["Turn on"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Advanced mode did not ask first")
            confirm.tap()
            XCTAssertTrue(poll(timeout: 15, interval: 0.5, "the three tabs") { app.hasTabs },
                          "Advanced mode did not show its tabs")
        } else {
            XCTAssertTrue(app.hasTabs, "already in beginner mode")
            app.navigationTab("Wallet").tap()
            let simple = app.buttons["advancedModeButton"]
            XCTAssertTrue(simple.waitForExistence(timeout: 10), "no Simple button on the Wallet tab")
            simple.tap()
            XCTAssertTrue(app.buttons["openSendButton"].waitForExistence(timeout: 15),
                          "Simple did not bring the one screen back")
        }
    }

    /// Scrolls the one screen from its top down to `element`: the savings
    /// rows sit below Activity, so on a wallet with a few payments they are
    /// below the fold, and a List row below the fold does not exist yet.
    @MainActor
    @discardableResult
    func revealOnOneScreen(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        _ = scrollUntilExists(app, app.buttons["receiveButton"], maxSwipes: 6, up: true)
        return scrollUntilExists(app, element, maxSwipes: 8)
    }

    /// Where the backup file and the recovery words are: Settings in
    /// Advanced mode, the Back up row on the one screen otherwise.
    @MainActor
    func openBackup(_ app: XCUIApplication) {
        if app.hasTabs {
            app.navigationTab("Settings").tap()
            return
        }
        app.goToWallet()
        let row = app.buttons["backupButton"]
        XCTAssertTrue(scrollUntilExists(app, row), "no Back up row on the one screen")
        row.tap()
        XCTAssertTrue(app.buttons["exportBundleButton"].waitForExistence(timeout: 20), "Back up did not open")
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
    ///
    /// A tap that lands while the previous field's keyboard is still on its
    /// way out can leave nothing focused, and typing then fails with
    /// "neither element nor any descendant has keyboard focus" (seen on the
    /// hosted runners, #84). So the tap is repeated until the field has
    /// the keyboard, and dismissal waits for the keyboard to be gone.
    @MainActor
    func typeInto(_ identifier: String, _ text: String) {
        var field = textFields[identifier]
        if !field.exists { field = textViews[identifier] }
        XCTAssertTrue(field.waitForExistence(timeout: 20), "no text field \(identifier)")
        var focused = false
        for _ in 1...3 where !focused {
            field.tap()
            focused = field.waitForKeyboardFocus(timeout: 3)
        }
        XCTAssertTrue(focused, "\(identifier) never took keyboard focus")
        field.typeText(text)
        dismissKeyboard()
    }

    @MainActor
    func dismissKeyboard() {
        let keyboard = keyboards.firstMatch
        guard keyboard.exists else { return }
        defer {
            // The dismissal animates independently of app idleness; the next
            // tap must not race it.
            _ = keyboard.waitForNonExistence(timeout: 5)
        }
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
        if keyboard.exists {
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
    /// Advanced mode only: the one screen has no tabs, and this would fall
    /// through to its Send button — use `openSend` and `goToWallet` there.
    func navigationTab(_ title: String) -> XCUIElement {
        let phone = tabBars.buttons[title]
        if phone.exists { return phone }
        let floating = cells[title].firstMatch
        if floating.exists { return floating }
        return buttons[title].firstMatch
    }

    /// Advanced mode has tabs (a bar on iPhone; on iPad floating cells, or
    /// toolbar buttons identified by their symbols); beginner mode is one
    /// screen.
    var hasTabs: Bool {
        if tabBars.firstMatch.exists || cells["Wallet"].firstMatch.exists { return true }
        return buttons["bitcoinsign.circle"].firstMatch.exists && buttons["gear"].firstMatch.exists
    }

    /// Whether the Send form, its review or its receipt is on screen: the
    /// selected tab, or the sheet over the one screen.
    var sendIsOpen: Bool {
        if hasTabs { return navigationTab("Send").isSelected }
        return buttons["closeSendButton"].exists
    }

    /// Opens Send: the tab, or the one screen's button. Already open is
    /// fine. A screen pushed over the one screen (a payment, an account)
    /// is popped first, since the button is only on the screen itself.
    func openSend() {
        if hasTabs {
            navigationTab("Send").tap()
            return
        }
        if buttons["closeSendButton"].exists { return }
        popToOneScreen()
        let open = buttons["openSendButton"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "no Send button on the one screen")
        // A tap that lands while the list is still settling from the
        // scroll above is lost; ask again rather than wait it out.
        for _ in 0 ..< 3 where !buttons["closeSendButton"].exists {
            open.tap()
            _ = buttons["closeSendButton"].waitForExistence(timeout: 7)
        }
        XCTAssertTrue(buttons["closeSendButton"].waitForExistence(timeout: 20), "the Send sheet did not open")
    }

    /// Buttons that exist only while one of the app's sheets is up.
    static let sheetMarkers = ["closeSendButton", "newReceiveAddressButton", "saveReceiveAddressLabelButton",
                               "skipReceiveAddressLabelButton", "addSavingsCoOwnerButton", "savingsCardPasteButton",
                               "exportConfirmButton", "walletSharedSavingsButton"]

    /// The dismissal a sheet's bar offers, if a sheet is up. One query.
    private var sheetDismissal: XCUIElement? {
        let bar = navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Close", "Cancel"]))
        return bar.count > 0 ? bar.firstMatch : nil
    }

    /// Whether one of the app's sheets is up: its buttons exist, or its bar
    /// offers a way out. "Save with other people" marks the beginner
    /// chooser sheet; on the Advanced Wallet tab it is an ordinary row.
    /// Two queries, whatever the number of markers: every one of these
    /// costs a second on a slow runner.
    func sheetIsUp(tabs: Bool) -> Bool {
        let markers = tabs ? Self.sheetMarkers.filter { $0 != "walletSharedSavingsButton" } : Self.sheetMarkers
        if buttons.matching(NSPredicate(format: "identifier IN %@", markers)).count > 0 { return true }
        return sheetDismissal != nil
    }

    /// The wallet, with nothing over it and its top on screen: its own
    /// navigation bar in front, no sheet, and the balance row visible.
    var atHome: Bool {
        let root = navigationBars["Winnow"]
        guard root.exists, root.isHittable, !sheetIsUp(tabs: hasTabs) else { return false }
        return staticTexts["balanceText"].exists
    }

    /// Back to the wallet from wherever the last journey stopped: keyboard
    /// down, alerts answered, sheets closed, pushed screens popped, the
    /// wallet scrolled to its top. A journey that attaches to the running
    /// app starts here, the way one that launched afresh started at the
    /// wallet.
    @MainActor
    func resetToHome() {
        // The common case first, and cheaply: the last journey ended on the
        // wallet. Every query below is a second on a slow runner.
        if atHome { return }
        for _ in 0 ..< 10 {
            dismissKeyboard()
            if alerts.firstMatch.exists {
                let cancel = alerts.buttons["Cancel"]
                (cancel.exists ? cancel : alerts.buttons.firstMatch).tap()
                continue
            }
            let close = buttons["closeSendButton"]
            if close.exists, close.isHittable {
                close.tap()
                _ = close.waitForNonExistence(timeout: 10)
                continue
            }
            let tabs = hasTabs
            if tabs, tabBars.firstMatch.isHittable, !navigationTab("Wallet").isSelected {
                navigationTab("Wallet").tap()
                continue
            }
            let root = navigationBars["Winnow"]
            let rootInFront = root.exists && root.isHittable
            let sheet = sheetIsUp(tabs: tabs)
            if rootInFront, !sheet {
                if staticTexts["balanceText"].exists { return }
                // The wallet, scrolled: bring its top back.
                scrollToTop()
                continue
            }
            // A sheet closes from its bar.
            if sheet, let dismiss = sheetDismissal, dismiss.isHittable {
                dismiss.tap()
                _ = dismiss.waitForNonExistence(timeout: 10)
                continue
            }
            // A pushed screen pops from its back button — never from just any
            // leading button: the wallet's own bar leads with the mode switch.
            let back = navigationBars.buttons.matching(identifier: "BackButton").firstMatch
            if back.exists, back.isHittable {
                back.tap()
                continue
            }
            let winnow = navigationBars.buttons["Winnow"]
            if winnow.exists, winnow.isHittable {
                winnow.tap()
                continue
            }
            goToWallet()
        }
        XCTAssertTrue(atHome, "could not get back to the wallet")
    }

    /// iOS's own scroll-to-top: a tap on the status bar. Unlike a drag it
    /// cannot land on a row. For the screen in front, whatever it is — a
    /// tab keeps its scroll position while another is shown, so a journey
    /// that switches to Settings starts wherever the last one left it.
    func scrollTabToTop() {
        coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.012)).tap()
    }

    /// The wallet's top row, its balance, back on screen: a List row
    /// scrolled out of view is not in the tree. The status-bar tap first;
    /// drags are the fallback.
    func scrollToTop() {
        let balance = staticTexts["balanceText"]
        if balance.exists { return }
        scrollTabToTop()
        if balance.waitForExistence(timeout: 3) { return }
        let list = collectionViews.firstMatch
        for _ in 0 ..< 6 where !balance.exists {
            guard list.exists else { break }
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0.25)
        }
    }

    /// Back to the wallet: the tab, or closing the Send sheet and popping
    /// any screen pushed over the one screen. A sheet's form state does
    /// not survive this; a receipt still open is read before it is closed.
    func goToWallet() {
        if hasTabs {
            navigationTab("Wallet").tap()
            return
        }
        let close = buttons["closeSendButton"]
        if close.exists {
            close.tap()
            _ = close.waitForNonExistence(timeout: 10)
        }
        popToOneScreen()
    }

    /// Pops pushed screens and scrolls the one screen back to its top, so
    /// its own controls exist again: a List row scrolled out of view is not
    /// in the tree, and the screen stays scrolled while a detail is pushed.
    private func popToOneScreen() {
        for _ in 0 ..< 3 {
            let back = navigationBars.buttons["Winnow"]
            guard back.exists, back.isHittable else { break }
            back.tap()
            _ = navigationBars["Winnow"].waitForExistence(timeout: 5)
        }
        scrollToTop()
    }
}

extension XCUIElement {
    /// Whether this element holds the keyboard within `timeout`: the
    /// condition `typeText` checks before it synthesizes a keystroke.
    @MainActor
    func waitForKeyboardFocus(timeout: TimeInterval) -> Bool {
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: self)
        return XCTWaiter().wait(for: [focused], timeout: timeout) == .completed
    }
}
