import LocalAuthentication
import WalletCore
import SwiftUI
import UIKit

/// Beginner onboarding creates or restores a wallet without a phrase checklist.
/// Cloud discovery is automatic; neither discovery nor backup blocks wallet use.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var busy = false
    @State private var error: String?
    @State private var showImport = false
    @State private var showCloudRestore = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your bitcoin, on your phone. Winnow connects directly to Bitcoin and automatically backs up your wallet with iCloud when available.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    if model.walletID != nil {
                        Button("Continue with your wallet") { model.finishOnboarding() }
                            .accessibilityIdentifier("resumeImportedWalletButton")
                    } else {
                        if !model.cloudBackups.available.isEmpty {
                            Button("Restore your iCloud wallet", systemImage: "icloud.and.arrow.down") {
                                showCloudRestore = true
                            }
                            .accessibilityIdentifier("restoreCloudBackupButton")
                            Text("\(model.cloudBackups.available.count) saved backup(s) found.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Create new wallet", systemImage: "plus.circle") { create() }
                            .accessibilityIdentifier("createWalletButton")
                        Button("Restore from a file", systemImage: "square.and.arrow.down") { showImport = true }
                            .accessibilityIdentifier("importWalletButton")
                    }
                } footer: {
                    Text("No iCloud? Your wallet still works. You can save a manual backup instead. Recovery words and backup controls are in Advanced.")
                }
                if model.cloudBackups.busy { ProgressView("Checking iCloud…") }
                if let message = model.cloudBackups.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                if model.showsNetworkPicker {
                    Section {
                        Picker("Network", selection: Binding(
                            get: { model.network },
                            set: { newValue in Task { await model.switchNetwork(to: newValue) } }
                        )) {
                            Text("Mainnet").tag(BitcoinNetwork.mainnet)
                            Text("Signet").tag(BitcoinNetwork.signet)
                        }
                        .disabled(model.e2e?.forcedNetwork != nil || busy)
                        .accessibilityIdentifier("onboardingNetworkPicker")
                    } footer: {
                        Text("Each network has its own wallet. Signet uses test coins with no value.")
                    }
                }
                if busy { ProgressView("Creating your wallet…") }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .disabled(busy)
            .navigationTitle("Winnow")
            .sheet(isPresented: $showCloudRestore) { CloudRestoreView() }
            .sheet(isPresented: $showImport) { ImportBundleView() }
            .task(id: model.network) { await model.discoverCloudBackups() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { cancel() }
                else if phase == .active, !busy {
                    Task { await model.discoverCloudBackups() }
                }
            }
            .onDisappear { cancel() }
        }
    }

    private func create() {
        busy = true
        error = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do { try await model.createWallet() }
            catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func cancel() {
        operation?.cancel()
        operation = nil
        busy = false
    }
}

/// Paste an ImportBundle JSON (WalletCore's format v1); verification scans
/// forward from the bundle's height and its report is shown.
private struct ImportBundleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var json = ""
    @State private var busy = false
    @State private var error: String?
    @State private var report: ImportReport?
    @State private var imported = false
    @State private var importEpoch = SensitivePresentationEpoch()
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                if !imported {
                    Section {
                        TextEditor(text: $json)
                            .font(.system(.caption, design: .monospaced))
                            // Keep real bundles scrollable inside the editor. A
                            // minimum-only height lets TextEditor expand to the
                            // full JSON and can push the import action thousands
                            // of points off-screen.
                            .frame(height: 160)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("importJSONEditor")
                        Button("Paste from clipboard") {
                            json = model.pasteboardText() ?? ""
                        }
                        .accessibilityIdentifier("importPasteButton")
                    } header: {
                        Text("Paste your backup file (JSON)")
                    } footer: {
                        Text("Use the file saved from Back up wallet. Keep your recovery words too. Backups from other wallets may not include every coin type.")
                    }
                }
                if busy {
                    Section { BusyIndicator(text: "Importing and verifying…") }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
                if report != nil || imported
                    || model.walletID != nil {
                    if let report {
                        Section("Verification report") {
                            LabeledContent("Scanned from block", value: "\(report.scannedFromHeight)")
                            if let to = report.scannedToHeight {
                                LabeledContent("Scanned to block", value: "\(to)")
                            }
                            LabeledContent("Claimed UTXOs confirmed", value: "\(report.confirmedUTXOs.count)")
                            LabeledContent("Claimed but spent since", value: "\(report.spentSinceBundle.count)")
                            LabeledContent("Discovered since bundle", value: "\(report.discoveredUTXOs.count)")
                            if !report.matchesBundle {
                                Text("Some claimed UTXOs were already spent — the bundle was stale or wrong. The chain won; check the report above.")
                                    .foregroundStyle(.orange)
                                    .font(.footnote)
                            }
                        }
                        .accessibilityIdentifier("importReportSection")
                    }
                    Section {
                        Button("Continue") {
                            model.finishOnboarding()
                            dismiss()
                        }
                        .accessibilityIdentifier("importContinueButton")
                    }
                } else {
                    Section {
                        Button("Import and verify") { importBundle() }
                            .accessibilityIdentifier("importVerifyButton")
                            .disabled(json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                    }
                }
            }
            .navigationTitle("Import wallet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        clearSensitiveImport()
                        dismiss()
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { clearSensitiveImport() }
            }
            .onDisappear { clearSensitiveImport() }
        }
    }

    private func importBundle() {
        importTask?.cancel()
        let token = importEpoch.begin()
        let payload = json
        busy = true
        error = nil
        importTask = Task { @MainActor in
            do {
                let result = try await model.importWallet(bundleJSON: payload)
                try Task.checkCancellation()
                guard importEpoch.accepts(
                    token, whilePresentationIsAllowed: scenePhase != .background
                ) else { return }
                report = result
                // A seed-bearing bundle must not remain in view state after
                // it has been handed to WalletCore/Keychain.
                json = ""
                imported = true
                if result == nil {
                    error = "Imported, but no peers were reachable for verification yet — the regular sync will verify from the bundle's height."
                }
            } catch is CancellationError {
                // The text is cleared below; an import that already crossed
                // its commit boundary remains discoverable through AppModel.
            } catch {
                if importEpoch.accepts(token, whilePresentationIsAllowed: scenePhase != .background) {
                    self.error = error.localizedDescription
                }
            }
            guard importEpoch.accepts(
                token, whilePresentationIsAllowed: scenePhase != .background
            ) else {
                return
            }
            busy = false
            importTask = nil
        }
    }

    private func clearSensitiveImport() {
        importEpoch.invalidate()
        importTask?.cancel()
        importTask = nil
        json = ""
        busy = false
        error = nil
        report = nil
    }
}
