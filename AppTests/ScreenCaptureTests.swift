@testable import WinnowApp
import UIKit
import XCTest

/// The recovery-phrase grids hide while the screen is captured (IR-022).
/// The simulator cannot record itself, so the monitor takes what "captured"
/// means as a closure and the notification that flips it is posted by hand.
@MainActor
final class ScreenCaptureTests: XCTestCase {
    final class Screen: @unchecked Sendable {
        var captured = false
    }

    func testTheMonitorFollowsTheCaptureNotification() async throws {
        let screen = Screen()
        let center = NotificationCenter()
        let monitor = ScreenCaptureMonitor(center: center) { screen.captured }
        XCTAssertFalse(monitor.isCaptured)

        screen.captured = true
        center.post(name: UIScreen.capturedDidChangeNotification, object: nil)
        try await waitUntil { monitor.isCaptured }

        screen.captured = false
        center.post(name: UIScreen.capturedDidChangeNotification, object: nil)
        try await waitUntil { !monitor.isCaptured }
    }

    func testANotificationOnAnotherCenterIsNotHeard() async throws {
        let screen = Screen()
        let monitor = ScreenCaptureMonitor(center: NotificationCenter()) { screen.captured }
        screen.captured = true
        NotificationCenter.default.post(name: UIScreen.capturedDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(monitor.isCaptured, "the monitor listens on the centre it was given")
        monitor.refresh()
        XCTAssertTrue(monitor.isCaptured)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 40 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(condition(), "the monitor did not update in time", file: file, line: line)
    }
}
