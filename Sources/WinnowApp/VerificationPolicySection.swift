import SwiftUI

struct VerificationPolicySection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDegraded = false

    var body: some View {
        if model.network == .mainnet {
            Section {
                Toggle("Allow one verification source this session", isOn: Binding(
                    get: { model.allowSingleSourceMainnet },
                    set: { enabled in
                        if enabled { confirmDegraded = true }
                        else { Task { await model.setAllowSingleSourceMainnet(false) } }
                    }
                ))
                .accessibilityIdentifier("singleSourceVerificationToggle")
                if model.allowSingleSourceMainnet {
                    Label("Degraded verification is active", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Compact-filter verification")
            } footer: {
                Text("Mainnet normally waits for agreement from two known peer-acquisition sources. Sources do not prove different operators. If you choose one source, a dishonest source can hide payments or supply incorrect filter commitments. This choice ends when you restart the app or switch networks.")
            }
            .alert("Allow one verification source?", isPresented: $confirmDegraded) {
                Button("Use one source", role: .destructive) {
                    Task { await model.setAllowSingleSourceMainnet(true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This lets mainnet sync and recovery advance without corroboration from another acquisition source. A valid block-header chain does not prove compact filters are correct. Continue only if you accept that weaker verification for this session.")
            }
        }
    }
}
