import SwiftUI
import UIKit

/// When a scan last reached the tip, and whether iOS may check in the
/// background. Background checks are requests; iOS decides when they run.
struct ChainCheckStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let checked = model.lastCompleteCheck {
                Text("Chain last checked \(checked, style: .relative) ago")
                    .accessibilityIdentifier("lastCompleteChainCheck")
            } else {
                Text("Chain not fully checked yet")
                    .accessibilityIdentifier("lastCompleteChainCheck")
            }
            if UIApplication.shared.backgroundRefreshStatus == .available {
                Text("iOS may also check while Winnow is closed, through the same routing. It cannot while the phone is off or after you force-quit Winnow.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Background App Refresh is off, so Winnow checks the chain only while open.")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
    }
}
