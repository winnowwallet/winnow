import SwiftUI

struct CloudBackupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmEnable = false
    @State private var error: String?
    @State private var working = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.cloudBackups.enabled {
                        Label("Automatic backup is on", systemImage: "checkmark.icloud")
                        if let saved = model.cloudBackups.lastSaved {
                            LabeledContent("Saved to iCloud", value: saved.formatted())
                        }
                        Button("Stop automatic backups", role: .destructive) {
                            do { try model.cloudBackups.stop() } catch { self.error = error.localizedDescription }
                        }
                        .disabled(working || model.cloudBackups.busy)
                    } else {
                        Button("Enable iCloud backup") { confirmEnable = true }
                            .disabled(working || model.cloudBackups.busy || model.walletID == nil)
                            .accessibilityIdentifier("enableCloudBackupButton")
                    }
                } footer: {
                    Text("Saves this phone’s signing key, wallet history and shared accounts. Winnow updates the backup while open, once pending payments confirm. Other owners still need their own key backups.")
                }
                Section {
                    Text("To restore on a new device, use the same Apple Account with iCloud and Passwords & Keychain enabled. Keep your recovery words and a manual backup too.")
                    Text("Stopping automatic backups leaves the saved copy in iCloud.")
                }
                if working || model.cloudBackups.busy { ProgressView("Saving backup…") }
                if let message = error ?? model.cloudBackups.message {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("iCloud backup")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .confirmationDialog("Back up your signing key to iCloud?", isPresented: $confirmEnable,
                                titleVisibility: .visible) {
                Button("Enable encrypted backup") { enable() }
            } message: {
                Text("Someone who can recover your iCloud backup and its iCloud Keychain key can spend from this wallet. Device authentication is required to enable backup and restore it.")
            }
            .onDisappear { cancel() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { cancel() } }
        }
    }

    private func enable() {
        working = true
        error = nil
        operation = Task { @MainActor in
            defer { working = false }
            do { try await model.enableCloudBackup() }
            catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func cancel() {
        operation?.cancel()
        operation = nil
        working = false
    }
}

struct CloudRestoreView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var operation: Task<Void, Never>?
    @State private var restoring = false
    @State private var restored = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if restored || model.walletID != nil {
                    Section {
                        Text("Your wallet is restored. Keep Winnow open to check for newer payments.")
                        Button("Continue") { model.finishOnboarding(); dismiss() }
                    }
                } else {
                    Section {
                        ForEach(model.cloudBackups.available) { backup in
                            Button {
                                restore(backup.id)
                            } label: {
                                Label(backup.savedAt.formatted(), systemImage: "icloud.and.arrow.down")
                            }
                            .disabled(restoring)
                        }
                        if model.cloudBackups.available.isEmpty, !model.cloudBackups.busy {
                            Text("No backup found for this network yet.")
                        }
                        Button("Check again") {
                            operation = Task { await model.cloudBackups.discover(network: model.network.rawValue) }
                        }.disabled(restoring || model.cloudBackups.busy)
                    } header: {
                        Text("Choose a saved backup")
                    } footer: {
                        Text("Use the same Apple Account and enable Passwords & Keychain. Backups may take time to appear on a new device. Restoring never replaces a wallet already on this phone.")
                    }
                }
                if restoring || model.cloudBackups.busy { ProgressView(restoring ? "Restoring wallet…" : "Checking iCloud…") }
                if let message = error ?? model.cloudBackups.message { Text(message).foregroundStyle(.secondary) }
            }
            .navigationTitle("Restore from iCloud")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await model.cloudBackups.discover(network: model.network.rawValue) }
            .onDisappear { cancel() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { cancel() } }
        }
    }

    private func restore(_ id: UUID) {
        restoring = true
        error = nil
        operation = Task { @MainActor in
            defer { restoring = false }
            do {
                let report = try await model.restoreCloudBackup(id)
                try Task.checkCancellation()
                restored = true
                if let report, !report.matchesBundle {
                    error = "Some payments changed since this backup. Winnow updated the wallet from the network; review the restored balances."
                } else if report == nil {
                    error = "Restored. Network verification will resume when peers are reachable."
                }
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func cancel() {
        operation?.cancel()
        operation = nil
        model.cloudBackups.suspend()
        restoring = false
    }
}
