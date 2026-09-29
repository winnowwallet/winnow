import Foundation
import LightningCore
import SwiftUI

struct LightningInvoiceSendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: LightningAppController
    @State private var invoice = ""
    @State private var amount = ""
    @State private var fee = "50"
    @State private var review: LightningReview?
    @State private var paymentID: Data?
    @State private var scan = false
    @State private var sendOffer = false
    @State private var busy = false
    @State private var error: String?
    @State private var discovery: Task<Void, Never>?
    @FocusState private var editing: Bool
    private var decoded: Bolt11Invoice.Decoded? { try? Bolt11Invoice.decode(invoice, network: controller.network) }
    var body: some View {
        NavigationStack {
            Form {
                Text(controller.networkNotice).font(.headline)
                if let id = paymentID {
                    Section("Payment") {
                        let payment = controller.payments.first { $0.id == id }
                        Text(payment?.phase.displayName ?? "Committing payment")
                            .accessibilityIdentifier("lightningInvoicePaymentStatus")
                        if let payment {
                            LabeledContent("Amount", value: "\(Bolt11Invoice.sats(payment.amountMsat)) sats")
                            if let fee = payment.feeMsat { LabeledContent("Fee", value: "\(Bolt11Invoice.sats(fee)) sats") }
                            Text(payment.hash.hex).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if payment?.phase == .failed { Button("Review another attempt") { paymentID = nil } }
                        Text("Keep checking the channel while a payment is pending. Only Settled confirms payment.").font(.footnote)
                    }
                } else {
                    Section("Lightning invoice") {
                        TextEditor(text: $invoice).frame(minHeight: 100).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .focused($editing).accessibilityIdentifier("lightningInvoiceInput")
                        Button("Paste invoice") { invoice = model.pasteboardText() ?? "" }.accessibilityIdentifier("lightningPasteInvoice")
                        Button("Scan invoice") { editing = false; scan = true }.accessibilityIdentifier("lightningScanInvoice")
                        if let value = decoded {
                            if let description = value.description { Text(description) }
                            LabeledContent("Expires", value: Date(timeIntervalSince1970: Double(value.expiresAt)).formatted())
                        }
                    }
                    Section("Payment limits") {
                        if let fixed = decoded?.amountMsat { LabeledContent("Amount", value: "\(Bolt11Invoice.sats(fixed)) sats") }
                        else { TextField("Amount in sats", text: $amount).keyboardType(.decimalPad).focused($editing).accessibilityIdentifier("lightningInvoiceAmount") }
                        TextField("Maximum fee in sats", text: $fee).keyboardType(.numberPad).focused($editing).accessibilityIdentifier("lightningInvoiceFee")
                    }
                    Section {
                        Button("Pay reusable offer or ₿name") { sendOffer = true }
                            .accessibilityIdentifier("lightningInvoiceToOffer")
                        Text("Payments spend your Lightning channel balance. Receiving capacity is separate from your available balance.").font(.footnote)
                        Button(busy ? "Finding a route…" : "Review payment") { prepareReview() }
                            .disabled(busy || invoice.isEmpty).accessibilityIdentifier("lightningReviewInvoice")
                        if busy { ProgressView("Getting routing information from your peer") }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lightningInvoiceSendError") }
            }
            .navigationTitle("Pay Lightning invoice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("lightningInvoiceSendDone") }
                ToolbarItem(placement: .keyboard) { Button("Done") { editing = false }.accessibilityIdentifier("sendKeyboardDone") }
            }
            .sheet(isPresented: $scan) { PaymentScannerView { invoice = $0; scan = false } }
            .sheet(isPresented: $sendOffer) { LightningOfferSendView(controller: controller) }
            .sheet(item: $review) { item in
                LightningReviewView(controller: controller, review: item, onConfirmed: {
                    if case .invoice(let approved) = item { paymentID = approved.request.id }
                })
            }
            .onChange(of: invoice) { _, _ in invalidate() }
            .onChange(of: amount) { _, _ in invalidate() }
            .onChange(of: fee) { _, _ in invalidate() }
            .onChange(of: model.network) { _, _ in invalidate(); paymentID = nil }
            .onDisappear { discovery?.cancel() }
            .task {
                while !Task.isCancelled {
                    do { try await controller.refresh(); try await Task.sleep(for: .seconds(1)) }
                    catch is CancellationError { return }
                    catch { self.error = error.localizedDescription; return }
                }
            }
        }
    }
    private func invalidate() { discovery?.cancel(); review = nil; error = nil }
    private func prepareReview() {
        guard !busy else { return }
        editing = false; busy = true; error = nil
        let text = invoice, amountText = amount, feeText = fee, network = model.network
        discovery = Task {
            defer { busy = false }
            do {
                let value = try Bolt11Invoice.decode(text, network: controller.network)
                let msat = try value.amountMsat ?? Bolt11Invoice.millisatoshis(amountText)
                guard let maximumFee = UInt64(feeText) else { throw LightningError.invalidAmount }
                let prepared = try await controller.reviewInvoice(text, amountMsat: msat, maximumFeeSat: maximumFee, model: model)
                try Task.checkCancellation()
                guard invoice == text, amount == amountText, fee == feeText, model.network == network else { throw LightningInvoiceError.changed }
                review = .invoice(prepared)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
