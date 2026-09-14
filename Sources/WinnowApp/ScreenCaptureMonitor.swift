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
    /// Holds the observation for as long as the monitor lives; the box
    /// removes it when it goes away, so nothing has to hop actors in `deinit`.
    private let subscription: NotificationSubscription

    init(center: NotificationCenter = .default,
         currentlyCaptured: @escaping @MainActor () -> Bool = ScreenCaptureMonitor.anyScreenIsCaptured) {
        self.currentlyCaptured = currentlyCaptured
        isCaptured = currentlyCaptured()
        let box = NotificationSubscription(center: center)
        subscription = box
        box.token = center.addObserver(forName: UIScreen.capturedDidChangeNotification, object: nil,
                                       queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
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

/// A notification observation that ends with the object holding it.
private final class NotificationSubscription: @unchecked Sendable {
    let center: NotificationCenter
    var token: (any NSObjectProtocol)?

    init(center: NotificationCenter) {
        self.center = center
    }

    deinit {
        if let token { center.removeObserver(token) }
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
