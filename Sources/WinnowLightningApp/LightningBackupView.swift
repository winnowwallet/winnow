import SwiftUI
import UniformTypeIdentifiers
import WalletCore

struct LightningBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= CloudWalletBackup.maximumBytes else { throw ICloudBackupError.invalidBackup }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct LightningBackupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var prepared: PortableLightningBackup.Prepared?
    @State private var savedPhrase = false
    @State private var importing = false
    @State private var exporting = false
    @State private var importedFile: Data?
    @State private var phrase = ""
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @State private var capture = ScreenCaptureMonitor()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("An encrypted recovery file includes the Bitcoin signing key and independent Lightning channel keys. Save its separate 24-word phrase away from the file.")
                    Text("Restored channels remain in recovery mode. Winnow asks counterparties to close and scans for returned funds. An unavailable peer can delay recovery; a backup does not protect an offline channel.")
                }
                if let prepared { exportSection(prepared) }
                else if model.walletID != nil {
                    Section { Button("Prepare encrypted recovery file") { run { try await prepare() } }
                        .accessibilityIdentifier("lightningPrepareBackup") }
                }
                Section("Restore a recovery file") {
                    Button("Choose encrypted recovery file") { importing = true }.accessibilityIdentifier("lightningImportBackup")
                    if importedFile != nil {
                        if capture.isCaptured { Text("Stop screen recording to enter the recovery phrase.") }
                        else {
                        TextField("Separate 24-word file recovery phrase", text: $phrase, axis: .vertical)
                            .autocorrectionDisabled().textInputAutocapitalization(.never).privacySensitive()
                            .accessibilityIdentifier("lightningBackupPhrase")
                        }
                        Button("Restore in recovery mode") { run { try await restore() } }.disabled(capture.isCaptured)
                            .accessibilityIdentifier("lightningRestoreBackup")
                    }
                }
                if let status = model.lightning?.recoveryStatus {
                    Section("Recovery progress") {
                        LabeledContent("Backup saved", value: status.savedAt.formatted())
                        LabeledContent("Counterparties responding", value: "\(status.respondingPeers)")
                        Text("Connect to each original channel peer in Lightning settings and keep syncing. Spending and old commitment broadcasts stay disabled.")
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let message { Text(message).accessibilityIdentifier("lightningBackupResult") }
                if busy { ProgressView() }
            }
            .navigationTitle("Lightning recovery")
            .disabled(busy)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .fileExporter(isPresented: $exporting, document: prepared.map { LightningBackupDocument($0.file) }, contentType: .json,
                          defaultFilename: "Winnow-Lightning-Recovery-\(model.network.rawValue)") { result in
                switch result {
                case .success: message = "Encrypted file saved. Keep its separate recovery phrase; the Bitcoin wallet phrase alone cannot restore Lightning channels."
                case .failure(let error): self.error = error.localizedDescription
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do { importedFile = try readFile(result.get()); error = nil }
                catch { self.error = error.localizedDescription }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .background { clearSecrets() } }
            .onDisappear { clearSecrets() }
        }
    }
    private func exportSection(_ prepared: PortableLightningBackup.Prepared) -> some View {
        Section("Separate file recovery phrase") {
            if capture.isCaptured { Text("Stop screen recording to view the recovery phrase.") }
            else { Text(prepared.phrase).font(.body.monospaced()).privacySensitive().accessibilityIdentifier("lightningFileRecoveryPhrase") }
            RecoveryPhraseCopyButton(phrase: prepared.phrase, accessibilityID: "lightningCopyBackupPhrase")
                .disabled(capture.isCaptured)
            Toggle("I saved these 24 words separately", isOn: $savedPhrase)
            Button("Save encrypted recovery file") { exporting = true }.disabled(!savedPhrase)
                .accessibilityIdentifier("lightningExportBackup")
        }
    }
    private func prepare() async throws {
        let contents = try await model.portableLightningBackupContents()
        try Task.checkCancellation()
        prepared = try PortableLightningBackup.prepare(contents)
    }
    private func readFile(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= CloudWalletBackup.maximumBytes else { throw ICloudBackupError.invalidBackup }
        return try Data(contentsOf: url)
    }
    private func restore() async throws {
        guard let importedFile else { throw ICloudBackupError.invalidBackup }
        let contents = try PortableLightningBackup.restore(importedFile, phrase: phrase, network: model.network)
        _ = try await model.restorePortableLightningBackup(contents)
        phrase = ""; self.importedFile = nil
        message = "Lightning is in recovery mode. Connect to the channel's counterparty and wait for it to close. Winnow will scan for returned funds; this backup cannot resume payments or publish an old commitment."
    }
    private func clearSecrets() {
        operation?.cancel(); operation = nil; prepared = nil; phrase = ""; importedFile = nil; savedPhrase = false; exporting = false
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        operation = Task {
            defer { busy = false }
            do { try await action(); error = nil } catch { report(error) }
        }
    }
    private func report(_ failure: Error) {
        guard !(failure is CancellationError) else { return }
        error = failure.localizedDescription
    }
}
