import CryptoResearch
import SwiftUI

/// A fixed-public-vector demonstration with no wallet model or user input.
/// Results are display-only and must never become a wallet validation signal.
struct CryptoResearchView: View {
    @State private var report: CryptoResearchReport?
    @State private var failure: String?
    @State private var isRunning = false
    @State private var runID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            warning
            Form {
                introduction
                controls
                if let failure {
                    Section("Run could not complete") {
                        Text(failure)
                            .accessibilityIdentifier("cryptoResearchFailure")
                    }
                }
                if let report { results(report) }
                Section("Read the evidence") {
                    Link("Source, tests and limitations",
                         destination: URL(string: "https://github.com/posix4e/native-secp256k1-swift-test/tree/2ef204167972efc428486e823fc79b1f1bf0e9e7")!)
                    Text("No independent human cryptographic audit. These examples do not establish safety for wallet use.")
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Cryptography research")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: runID) {
            guard let runID else { return }
            await runExamples(id: runID)
        }
        .onDisappear {
            runID = nil
            isRunning = false
        }
    }

    private var warning: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Experimental")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cryptoResearchWarning")
            Text("Public data only. Do not rely on this for keys or payments.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("cryptoResearchWarningDetail")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.orange.opacity(0.15))
    }

    private var introduction: some View {
        Section("Public key experiment") {
            Text("Run 318 bundled examples through an experimental Swift public-key validator and compare the answers with stored reference results.")
            Text("The examples are fixed public data. This screen accepts no keys, recovery phrases or transactions and does not read your wallet.")
                .font(.footnote)
            Text("The wallet continues to use its existing cryptography. This experiment does not sign or verify signatures.")
                .font(.footnote)
        }
    }

    private var controls: some View {
        Section {
            Button(isRunning ? "Running public examples…" : "Run bundled public examples") {
                report = nil
                failure = nil
                isRunning = true
                runID = UUID()
            }
            .disabled(isRunning)
            .accessibilityIdentifier("cryptoResearchRun")
            if isRunning {
                ProgressView("Comparing reference answers")
                Button("Cancel run", role: .cancel) {
                    runID = nil
                    isRunning = false
                }
            }
        }
    }

    @ViewBuilder
    private func results(_ report: CryptoResearchReport) -> some View {
        Section("Results from these examples") {
            Text("\(report.matchedCount) of \(report.totalCount) bundled examples matched")
                .font(.headline)
                .accessibilityIdentifier("cryptoResearchSummary")
            Text("\(report.mismatchCount) mismatches. \(report.validCaseCount) expected valid; \(report.invalidCaseCount) expected invalid.")
            Text("A matching result only describes these examples. It is not a safety certification.")
                .font(.footnote)
                .accessibilityIdentifier("cryptoResearchResultLimit")
            DisclosureGroup("Individual results") {
                ForEach(report.results, id: \.name) { result in
                    caseResult(result)
                }
            }
        }
    }

    private func caseResult(_ result: CryptoResearchCaseResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(result.passed ? "Matched: \(result.name)" : "Mismatch: \(result.name)",
                  systemImage: result.passed ? "checkmark" : "exclamationmark.triangle")
            Text("Expected: \(result.expectedValid ? "valid point" : "rejected"). Observed: \(result.actualValid ? "valid point" : "rejected").")
                .font(.caption)
            if !result.passed {
                Text("Expected even y: \(result.expectedEvenYHex ?? "none")")
                Text("Observed even y: \(result.actualEvenYHex ?? "none")")
            }
        }
        .font(.footnote)
        .textSelection(.enabled)
    }

    @MainActor
    private func runExamples(id: UUID) async {
        do {
            let result = try await CryptoResearchDemo.run()
            try Task.checkCancellation()
            guard runID == id else { return }
            report = result
        } catch is CancellationError {
            // Leaving the screen or cancelling a run publishes no partial result.
        } catch {
            guard runID == id else { return }
            failure = "The bundled example run could not complete. \(error.localizedDescription)"
        }
        if runID == id { isRunning = false }
    }
}
