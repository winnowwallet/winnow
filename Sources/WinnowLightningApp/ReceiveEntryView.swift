import SwiftUI

/// Both wallet modes share the same choice. The ordinary Bitcoin-only target
/// retains its existing address screen and labeling flow.
struct ReceiveEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Method?
    private enum Method { case bitcoin, lightning }
    var body: some View {
        if let controller = model.lightning {
            switch selection {
            case .bitcoin: ReceiveView()
            case .lightning: LightningReceiveView(controller: controller, useBitcoin: { selection = .bitcoin })
            case nil:
                NavigationStack {
                    List {
                        Button { selection = .lightning } label: {
                            Label { VStack(alignment: .leading) {
                                Text("Lightning")
                                Text("Invoice for a Lightning withdrawal or payment").font(.caption).foregroundStyle(.secondary)
                            } } icon: { Image(systemName: "bolt.fill") }
                        }.accessibilityIdentifier("receiveLightning")
                        Button { selection = .bitcoin } label: {
                            Label { VStack(alignment: .leading) {
                                Text("Bitcoin")
                                Text("Address for a Bitcoin withdrawal or on-chain payment").font(.caption).foregroundStyle(.secondary)
                            } } icon: { Image(systemName: "bitcoinsign.circle") }
                        }.accessibilityIdentifier("receiveBitcoin")
                    }
                    .navigationTitle("Receive")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                }
            }
        } else { ReceiveView() }
    }
}
