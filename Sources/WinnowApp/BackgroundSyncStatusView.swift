import SwiftUI
import UIKit

struct BackgroundSyncStatusView: View {
    @Environment(AppModel.self) private var model
    @State private var protection = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 4) {
                if let checked = model.lastCompleteCheck {
                    Text("Chain checked \(checked, style: .relative) ago")
                        .accessibilityIdentifier("lastCompleteChainCheck")
                    if context.date.timeIntervalSince(checked) > 60 * 60 {
                        Text("Check overdue. Open Winnow and finish syncing.").foregroundStyle(.orange)
                    }
                } else {
                    Text("Waiting for a complete chain check").foregroundStyle(.orange)
                }
                if UIApplication.shared.backgroundRefreshStatus != .available {
                    Text("Background App Refresh is unavailable. Open Winnow regularly to check the chain.")
                        .foregroundStyle(.orange)
                }
                Text("Background checks cover the selected network when iOS allows. They cannot run while the phone is off or after you force-quit Winnow. Timing is not guaranteed.")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
        }
        if !model.channelProtection.records.isEmpty {
            Button("Channel protection and reminders") { protection = true }
                .sheet(isPresented: $protection) {
                    NavigationStack {
                        Form { Section("Lightning channel protection") { ChannelProtectionDetails() } }
                            .navigationTitle("Channel protection")
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { protection = false } } }
                    }
                }
        }
    }
}
