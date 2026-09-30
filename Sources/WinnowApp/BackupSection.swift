import WalletCore
import SwiftUI

/// The backup file and the recovery words: one section, shown on the
/// beginner screen's Back up page and inside Advanced mode's Settings. Owns
/// the reveal and export presentations and clears them when the scene
/// leaves the foreground, so a sensitive sheet never survives a background
/// transition on either host.
struct BackupSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var showExport = false
    @State private var showCloudBackup = false
    #if LIGHTNING
    @State private var showLightningBackup = false
    #endif
    @State private var revealedMnemonic: String?
    @State private var revealing = SensitiveAction()

    var body: some View {
        // The sheets and the lifecycle hooks hang on the rows, not on the
        // section: a Form flattens its sections, and a sheet attached to
        // one never presented.
        Section {
            #if LIGHTNING
            // No iCloud here: the encrypted recovery file carries the wallet
            // and the channels' recovery keys.
            Button("Lightning recovery file") { showLightningBackup = true }
                .accessibilityIdentifier("lightningBackup")
                .sheet(isPresented: $showLightningBackup) { LightningBackupView() }
            #else
            if model.advancedMode {
            Button("iCloud backup", systemImage: "icloud") { showCloudBackup = true }
                .disabled(model.walletID == nil)
                .sheet(isPresented: $showCloudBackup) { CloudBackupView() }
            }
            #endif
            Button("Back up wallet") { showExport = true }
                .disabled(model.walletID == nil)
                .accessibilityIdentifier("exportBundleButton")
                .sheet(isPresented: $showExport) {
                    ExportBundleView()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { clearSensitivePresentations() }
                }
                .onDisappear { clearSensitivePresentations() }
            if model.advancedMode {
            Button("Show recovery phrase") { reveal() }
                .disabled(model.walletID == nil || revealing.busy)
                .accessibilityIdentifier("revealPhraseButton")
                .sheet(item: revealedItem) { words in
                    RevealPhraseView(mnemonic: words.text)
                }
            }
            if let revealError = revealing.error {
                Text(revealError).foregroundStyle(.red).font(.footnote)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text("Keep both your recovery words and a backup file. Winnow restores from the file: it brings back your history and shared accounts, and this phone's signing key only if the file includes the words.")
        }
    }

    private struct RevealedItem: Identifiable {
        var id: String { text }
        let text: String
    }

    /// Bridges the optional revealed mnemonic to an Identifiable sheet item.
    private var revealedItem: Binding<RevealedItem?> {
        Binding(
            get: { revealedMnemonic.map(RevealedItem.init) },
            set: { revealedMnemonic = $0?.text }
        )
    }

    private func reveal() {
        revealing.start(presentable: { scenePhase != .background }) {
            try await model.revealMnemonic()
        } apply: { words in
            revealedMnemonic = words
        }
    }

    private func clearSensitivePresentations() {
        revealing.reset()
        revealedMnemonic = nil
        showExport = false
        showCloudBackup = false
    }
}

/// Backup → Show recovery phrase: the words and an explicit, short-lived
/// copy control, available only after device authentication.
struct RevealPhraseView: View {
    let mnemonic: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var capture = ScreenCaptureMonitor()

    private var words: [String] { mnemonic.split(separator: " ").map(String.init) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if capture.isCaptured {
                        PhraseHiddenWhileCaptured()
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                                Text("\(index + 1). \(word)")
                                    .font(.system(.body, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .privacySensitive()
                        .accessibilityIdentifier("revealedPhraseGrid")
                    }
                } footer: {
                    Text("These words are this phone's signing key. Keep them private. Winnow cannot restore from the words alone; save a backup file for your history and shared accounts.")
                }
                Section {
                    RecoveryPhraseCopyButton(
                        phrase: mnemonic, accessibilityID: "settingsCopyPhraseButton")
                } footer: {
                    Text("Copying is less private than paper. The clipboard item stays on this device and expires after two minutes.")
                }
            }
            .navigationTitle("Recovery phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { dismiss() }
            }
        }
    }
}
