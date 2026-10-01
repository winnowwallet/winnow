import LightningCore
import SwiftUI

struct LightningFeeBumpView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: LightningAppController
    let channel: LightningEngine.Channel
    @State private var maximumFee = "2000"
    @State private var htlcs: [Data] = []
    @State private var htlc: Data?
    @State private var review: LightningReview?
    @State private var busy = false
    @State private var error: String?
    @FocusState private var editing: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Winnow can spend explicitly approved Bitcoin wallet coins to raise an anchor channel's recovery fee. A commitment bump force closes the channel; it does not rewrite the signed commitment.")
                    Text("The total limit includes the parent and child fees. Coins remain reserved after submission, including across restart.")
                }
                Section("Recovery fee") {
                    Picker("Transaction", selection: $htlc) {
                        Text("Channel commitment").tag(Optional<Data>.none)
                        ForEach(htlcs, id: \.self) { Text("HTLC \($0.hex.prefix(12))").tag(Optional($0)) }
                    }
                    TextField("Maximum total fee in sats", text: $maximumFee).keyboardType(.numberPad).focused($editing)
                        .accessibilityIdentifier("lightningFeeBumpLimit")
                    Button("Review fee bump") { prepare() }.disabled(busy)
                        .accessibilityIdentifier("lightningReviewFeeBump")
                }
                if let error { Text(error).foregroundStyle(.red) }
                if busy { ProgressView() }
            }
            .navigationTitle("Recovery fee bump")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .keyboard) { Button("Done") { editing = false } }
            }
            .sheet(item: $review) { LightningReviewView(controller: controller, review: $0, onConfirmed: { dismiss() }) }
            .task { htlcs = (try? await controller.engine?.feeBumpableHTLCs(channelID: channel.id, peer: channel.peer)) ?? [] }
        }
    }
    private func prepare() {
        guard !busy else { return }; busy = true; editing = false
        Task {
            defer { busy = false }
            do {
                let limit = try feeLimit()
                review = try await .feeBump(controller.reviewFeeBump(channel: channel, maximumFeeSat: limit, model: model, htlcTransactionID: htlc))
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    private func feeLimit() throws -> UInt64 {
        guard let limit = UInt64(maximumFee) else { throw LightningError.invalidAmount }
        return limit
    }
}
