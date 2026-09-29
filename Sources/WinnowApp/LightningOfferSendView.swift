import LightningCore
import SwiftUI

struct LightningOfferSendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: LightningAppController
    @State private var destination = ""
    @State private var amount = ""
    @State private var fee = "50"
    @State private var review: LightningReview?
    @State private var paymentID: Data?
    @State private var scan = false
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    @FocusState private var editing: Bool
    var body: some View {
        NavigationStack {
            Form {
                Text(controller.networkNotice).font(.footnote)
                if let paymentID { paymentSection(paymentID) }
                else {
                    Section("Reusable offer or ₿name") {
                        TextEditor(text: $destination).frame(minHeight: 100).autocorrectionDisabled().textInputAutocapitalization(.never).focused($editing)
                            .accessibilityIdentifier("lightningOfferInput")
                        Button("Paste offer or name") { destination = model.pasteboardText() ?? "" }
                        Button("Scan offer") { editing = false; scan = true }
                        Text("Use a standard BOLT12 offer or a ₿user@domain BIP353 name. Name records are checked with DNSSEC on this device.").font(.footnote)
                    }
                    Section("Payment limits") {
                        TextField("Amount in sats", text: $amount).keyboardType(.decimalPad).focused($editing).accessibilityIdentifier("lightningOfferAmount")
                        TextField("Maximum fee in sats", text: $fee).keyboardType(.numberPad).focused($editing)
                        Button(busy ? "Requesting invoice…" : "Review offer payment") { prepare() }.disabled(busy || destination.isEmpty)
                            .accessibilityIdentifier("lightningReviewOffer")
                        if busy { ProgressView("Waiting for the recipient's signed invoice") }
                        Text("Requesting an invoice does not pay it. Review the returned amount, recipient and routing fee before confirming.").font(.footnote)
                    }
                    pendingSection
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lightningOfferError") }
            }
            .navigationTitle("Pay reusable offer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .keyboard) { Button("Done") { editing = false } }
            }
            .sheet(isPresented: $scan) { PaymentScannerView { destination = $0; scan = false } }
            .sheet(item: $review) { item in
                LightningReviewView(controller: controller, review: item, onConfirmed: {
                    if case .ordinaryInvoice(let approved) = item { paymentID = approved.request.id }
                })
            }
            .onChange(of: destination) { _, _ in invalidate() }
            .onChange(of: amount) { _, _ in invalidate() }
            .onChange(of: fee) { _, _ in invalidate() }
            .onChange(of: model.network) { _, _ in invalidate(); paymentID = nil }
            .onDisappear { operation?.cancel() }
            .task { await monitor() }
        }
    }
    private func paymentSection(_ id: Data) -> some View {
        Section("Payment") {
            Text(controller.payments.first(where: { $0.id == id })?.phase.displayName ?? "Committing payment")
                .accessibilityIdentifier("lightningOfferPaymentStatus")
        }
    }
    private var pendingSection: some View {
        Section("Saved invoice requests") {
            ForEach(controller.ordinaryRequests.filter { status in !controller.payments.contains(where: { $0.id == status.request.id }) }, id: \.request.id) { status in
                if status.invoice != nil && status.request.humanReadableName == nil {
                    Button("Review saved invoice") { resume(status) }
                } else { Text(status.expired ? "Invoice request expired" : "Request pending; name payments require a fresh name check") }
                Button("Cancel invoice request") { Task { await controller.cancelOrdinaryRequest(status.request.id); try? await controller.refresh() } }
            }
        }
    }
    private func invalidate() { operation?.cancel(); review = nil; error = nil }
    private func prepare() {
        guard !busy else { return }; editing = false; busy = true; error = nil
        let input = destination, amountText = amount, feeText = fee
        operation = Task {
            defer { busy = false }
            do {
                let limit = try feeLimit(from: feeText)
                let result = try await controller.reviewOrdinaryOffer(input, amountMsat: Bolt11Invoice.millisatoshis(amountText), maximumFeeSat: limit, model: model)
                try Task.checkCancellation()
                try validateReviewInput(input, amountText: amountText, feeText: feeText)
                review = .ordinaryInvoice(result)
            } catch { report(error) }
        }
    }
    private func feeLimit(from text: String) throws -> UInt64 {
        guard let limit = UInt64(text) else { throw LightningError.invalidAmount }
        return limit
    }
    private func validateReviewInput(_ input: String, amountText: String, feeText: String) throws {
        guard destination == input, amount == amountText, fee == feeText else { throw LightningInvoiceError.changed }
    }
    private func report(_ failure: Error) {
        guard !(failure is CancellationError) else { return }
        error = failure.localizedDescription
    }
    private func resume(_ status: LightningEngine.OrdinaryInvoiceStatus) {
        guard !busy else { return }; busy = true
        operation = Task {
            defer { busy = false }
            do {
                let limit = try feeLimit(from: fee)
                review = try await .ordinaryInvoice(controller.reviewSavedOrdinaryInvoice(status, maximumFeeSat: limit, model: model))
            } catch { report(error) }
        }
    }
    private func monitor() async {
        while !Task.isCancelled {
            do { try await controller.refresh(); try await Task.sleep(for: .seconds(1)) }
            catch { report(error); return }
        }
    }
}
