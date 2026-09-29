import SwiftUI
import UIKit

struct ChannelProtectionBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var details = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let warning = model.channelProtection.warning(now: context.date) {
                Button { details = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(typeSize.isAccessibilitySize ? "Check Lightning channels" : warning.title,
                              systemImage: "exclamationmark.shield")
                            .font(.callout.weight(.semibold))
                        if !typeSize.isAccessibilitySize {
                            Text("Channel funds can be at risk. Connect and finish syncing.").font(.footnote)
                        }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .foregroundStyle(warning.severity == .urgent ? Color.red : Color.orange)
                        .background(.background)
                }
                .accessibilityIdentifier("channelProtectionBanner")
                .accessibilityLabel(warning.title + ". Channel funds can be at risk. Connect and finish syncing.")
                .accessibilityHint("Review the last verified check and channel check reminders")
            } else if !model.channelProtection.records.isEmpty && !model.channelProtection.remindersEnabled {
                Button { details = true } label: {
                    Label("Channel check reminders", systemImage: "bell.badge")
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(.background)
                }
                .accessibilityIdentifier("channelReminderBanner")
            }
        }
        .task { await model.channelProtection.refreshPermission() }
        .sheet(isPresented: $details) {
            NavigationStack {
                Form { Section("Lightning channel protection") { ChannelProtectionDetails() } }
                    .navigationTitle("Channel protection")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { details = false } } }
            }
        }
    }
}

struct ChannelProtectionDetails: View {
    @Environment(AppModel.self) private var model
    @State private var busy = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            ForEach(model.channelProtection.records.keys.sorted(), id: \.self) { name in
                if let record = model.channelProtection.records[name] {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(name.capitalized) channels").font(.headline)
                        if let checked = record.checked { Text("Last verified check: \(checked, style: .relative) ago") }
                        else { Text("No complete channel check recorded").foregroundStyle(.orange) }
                        if record.failed { Text("The latest check or recovery relay did not finish.").foregroundStyle(.orange) }
                    }
                }
            }
        }
        Text("Connect to the internet and keep Winnow open until syncing finishes. If a peer publishes an old commitment, Winnow must detect it and relay a justice transaction before the channel's deadline or you can lose funds.")
        Button("Check channels now") { Task { await checkChannels() } }
            .disabled(busy).accessibilityIdentifier("checkChannelsNow")
        reminderControls
        Text("Reminders arrive after 1 hour and again after 6 hours without a complete channel check, and when a check or recovery relay fails. These are reminders, not safe offline limits: channel deadlines are measured in blocks. Notifications can be silenced or delayed and do not protect funds. iOS background checks are not guaranteed; a watchtower is not configured by these reminders.")
            .font(.footnote).foregroundStyle(.secondary)
            .accessibilityIdentifier("channelProtectionLimitations")
    }
    @ViewBuilder private var reminderControls: some View {
        Button(model.channelProtection.remindersEnabled ? "Turn off channel check reminders" : "Enable channel check reminders") {
            Task { await model.channelProtection.setReminders(!model.channelProtection.remindersEnabled) }
        }
        .accessibilityIdentifier("channelCheckReminders")
        if model.channelProtection.notificationPermission == .denied {
            Text("Notifications are blocked. In-app warnings remain available.").foregroundStyle(.orange)
            if let url = URL(string: UIApplication.openSettingsURLString) { Link("Open notification settings", destination: url) }
        }
        if let error = model.channelProtection.notificationError { Text(error).foregroundStyle(.orange) }
    }
    private func checkChannels() async {
        busy = true; defer { busy = false }
        guard let warning = model.channelProtection.warning() else { await model.syncNow(); return }
        if model.network != warning.network { await model.switchNetwork(to: warning.network) }
        await model.syncNow()
    }
}
