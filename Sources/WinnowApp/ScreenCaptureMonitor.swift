import Observation
import SwiftUI
import UIKit

/// Whether a screen this app is on is being recorded, mirrored or shared.
///
/// The privacy cover hides wallet content while the app is inactive; this is
/// the other way a screen leaves the device, with the app in front and the
/// user looking at it. The recovery-phrase grids hide themselves while it
/// says so (IR-022). `.privacySensitive()` alone does not: it bites only
/// under a `.redacted(.privacy)` the cover applies when the app is not in
/// front.
@MainActor
@Observable
final class ScreenCaptureMonitor {
    private(set) var isCaptured: Bool
    private let currentlyCaptured: @MainActor () -> Bool
    private let center: NotificationCenter
    /// Read once more from `deinit`, which is not on the main actor; the
    /// token is written only in `init`.
    private nonisolated(unsafe) var observer: (any NSObjectProtocol)?

    init(center: NotificationCenter = .default,
         currentlyCaptured: @escaping @MainActor () -> Bool = ScreenCaptureMonitor.anyScreenIsCaptured) {
        self.center = center
        self.currentlyCaptured = currentlyCaptured
        isCaptured = currentlyCaptured()
        observer = center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil,
                                      queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    func refresh() {
        isCaptured = currentlyCaptured()
    }

    /// Every screen the app has a scene on; a mirrored external display
    /// counts the same as a recording of the built-in one.
    static func anyScreenIsCaptured() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.screen.isCaptured }
    }
}

/// What stands in for a recovery phrase while the screen is captured.
struct PhraseHiddenWhileCaptured: View {
    var body: some View {
        Label("Hidden while the screen is being recorded or mirrored.", systemImage: "record.circle")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("phraseHiddenWhileCaptured")
    }
}
