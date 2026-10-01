import LightningCore
import SwiftUI

struct LightningSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: LightningAppController
    @State private var text = ""
    @State private var review: LightningReview?
    @State private var error: String?
    @FocusState private var editing: Bool
    var body: some View {
        NavigationStack {
            Form {
                if !LightningProviders.available(network: controller.network).isEmpty {
                    Section("Choose a provider") {
                        ForEach(LightningProviders.available(network: controller.network)) { provider in
                            Button(provider.name + (provider.id == LightningProviders.mainnet.first?.id ? " · Recommended" : "")) {
                                review = .profile(provider.profile)
                            }
                            .disabled(controller.channels.contains(where: { $0.phase != .closed }) || controller.liquidityQuote?.accepted == true)
                            .accessibilityIdentifier("lightningProvider.\(provider.id)")
                            if provider.manualSetup { Text("Setup on provider website").font(.caption).foregroundStyle(.secondary) }
                            if provider.jit { Text("Instant: the first payment opens the channel").font(.caption).foregroundStyle(.secondary) }
                            Link("\(provider.name) terms and fees", destination: provider.website).font(.caption)
                        }
                        Text("Connect to one provider. Changing providers can require another channel and setup fee. Existing channels or an approved setup order must finish before changing provider.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Advanced profile import") {
                Text("Paste a \(controller.network.rawValue) provider profile. Verify its node ID and endpoint before connecting. Receive offers and offline payments require a provider supporting the async Lightning protocol.")
                TextEditor(text: $text).frame(height: 160).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .focused($editing)
                    .accessibilityIdentifier("lightningProfileInput")
                Button("Paste profile") { text = model.pasteboardText() ?? "" }.accessibilityIdentifier("lightningPasteProfile")
                if let error { Text(error).foregroundStyle(.red) }
                Button("Review provider") {
                    editing = false
                    do { review = .profile(try LightningProfile.parse(text, network: controller.network)); error = nil }
                    catch { self.error = error.localizedDescription }
                }.accessibilityIdentifier("lightningReviewProfile")
                }
            }
            .navigationTitle("Provider setup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("lightningSetupDone")
                }
                ToolbarItem(placement: .keyboard) {
                    Button("Done") { editing = false }.accessibilityIdentifier("sendKeyboardDone")
                }
            }
            .sheet(item: $review) { LightningReviewView(controller: controller, review: $0) }
        }
    }
}

struct LightningSendView: View {
    private enum Field: Hashable { case offer, amount, fee }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: LightningAppController
    @State private var offer = ""
    @State private var amount = ""
    @State private var fee = "50"
    @State private var review: LightningReview?
    @State private var error: String?
    @State private var submitted = false
    @FocusState private var focusedField: Field?
    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $offer).frame(height: 120).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .offer)
                    .accessibilityIdentifier("lightningOfferInput")
                Button("Paste receive offer") { offer = model.pasteboardText() ?? "" }.accessibilityIdentifier("lightningPasteOffer")
                TextField("Amount in sats", text: $amount).keyboardType(.numberPad)
                    .focused($focusedField, equals: .amount).accessibilityIdentifier("lightningAmount")
                TextField("Maximum fee in sats", text: $fee).keyboardType(.numberPad)
                    .focused($focusedField, equals: .fee).accessibilityIdentifier("lightningFee")
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lightningInputError") }
                Button("Review payment") {
                    focusedField = nil
                    do {
                        guard let amount = UInt64(amount), let fee = UInt64(fee) else { throw LightningError.invalidAmount }
                        review = .payment(try controller.reviewPayment(offer: offer, amountSat: amount, maximumFeeSat: fee)); error = nil
                    } catch { self.error = error.localizedDescription }
                }.accessibilityIdentifier("lightningReviewPayment")
            }
            .navigationTitle("Pay receive offer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("lightningSendDone")
                }
                if focusedField != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") { focusedField = nil }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("lightningOfferHideKeyboard")
                    }
                }
            }
            .sheet(item: $review, onDismiss: {
                if submitted { dismiss() }
            }) { LightningReviewView(controller: controller, review: $0, onConfirmed: { submitted = true }) }
        }
    }
}
