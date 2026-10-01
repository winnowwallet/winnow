import Foundation
import LightningCore
import SwiftUI

struct LightningInvoiceSendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: LightningAppController
    @State private var draft = LightningInvoiceDraft()
    @State private var paymentID: Data?
    @State private var scan = false
    @State private var sendOffer = false
    @FocusState private var editing: Bool
    private var decoded: Bolt11Invoice.Decoded? { try? Bolt11Invoice.decode(draft.invoice, network: controller.network) }
    var body: some View {
        NavigationStack {
            Form {
                Text(controller.networkNotice).font(.headline)
                if let id = paymentID {
                    paymentStatus(id)
                } else {
                    invoiceForm
                }
                if let error = draft.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lightningInvoiceSendError") }
            }
            .navigationTitle("Pay Lightning invoice")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("lightningInvoiceSendDone") }
                ToolbarItem(placement: .keyboard) { Button("Done") { editing = false }.accessibilityIdentifier("sendKeyboardDone") }
            }
            .sheet(isPresented: $scan) { PaymentScannerView { draft.invoice = $0; scan = false } }
            .sheet(isPresented: $sendOffer) { LightningOfferSendView(controller: controller) }
            .sheet(item: $draft.review) { item in
                LightningReviewView(controller: controller, review: item, onConfirmed: {
                    if case .invoice(let approved) = item { paymentID = approved.request.id }
                })
            }
            .onChange(of: draft.inputs) { _, _ in draft.invalidate() }
            .onChange(of: model.network) { _, _ in draft.invalidate(); paymentID = nil }
            .onDisappear { draft.cancel() }
            .task {
                while !Task.isCancelled {
                    do { try await controller.refresh(); try await Task.sleep(for: .seconds(1)) }
                    catch is CancellationError { return }
                    catch { draft.report(error); return }
                }
            }
        }
    }
    private func paymentStatus(_ id: Data) -> some View {
        Section("Payment") {
            let payment = controller.payments.first { $0.id == id }
            Text(payment?.phase.displayName ?? "Committing payment")
                .accessibilityIdentifier("lightningInvoicePaymentStatus")
            if let payment { paymentAmounts(payment) }
            if payment?.phase == .failed { Button("Review another attempt") { paymentID = nil } }
            Text("Keep checking the channel while a payment is pending. Only Settled confirms payment.").font(.footnote)
        }
    }
    @ViewBuilder
    private func paymentAmounts(_ payment: LightningEngine.Payment) -> some View {
        LabeledContent("Amount", value: "\(Bolt11Invoice.sats(payment.amountMsat)) sats")
        if let fee = payment.feeMsat { LabeledContent("Fee", value: "\(Bolt11Invoice.sats(fee)) sats") }
        Text(payment.hash.hex).font(.caption.monospaced()).textSelection(.enabled)
    }
    @ViewBuilder
    private var invoiceForm: some View {
        Section("Lightning invoice") {
            TextEditor(text: $draft.invoice).frame(minHeight: 100).autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($editing).accessibilityIdentifier("lightningInvoiceInput")
            Button("Paste invoice") { draft.invoice = model.pasteboardText() ?? "" }.accessibilityIdentifier("lightningPasteInvoice")
            Button("Scan invoice") { editing = false; scan = true }.accessibilityIdentifier("lightningScanInvoice")
            if let value = decoded {
                if let description = value.description { Text(description) }
                LabeledContent("Expires", value: Date(timeIntervalSince1970: Double(value.expiresAt)).formatted())
            }
        }
        Section("Payment limits") {
            if let fixed = decoded?.amountMsat { LabeledContent("Amount", value: "\(Bolt11Invoice.sats(fixed)) sats") }
            else { TextField("Amount in sats", text: $draft.amount).keyboardType(.decimalPad).focused($editing).accessibilityIdentifier("lightningInvoiceAmount") }
            TextField("Maximum fee in sats", text: $draft.fee).keyboardType(.numberPad).focused($editing).accessibilityIdentifier("lightningInvoiceFee")
        }
        Section {
            Button("Pay reusable offer or ₿name") { sendOffer = true }
                .accessibilityIdentifier("lightningInvoiceToOffer")
            Text("Payments spend your Lightning channel balance. Receiving capacity is separate from your available balance.").font(.footnote)
            Button(draft.busy ? "Finding a route…" : "Review payment") {
                editing = false; draft.prepareReview(controller: controller, model: model)
            }
            .disabled(draft.busy || draft.invoice.isEmpty).accessibilityIdentifier("lightningReviewInvoice")
            if draft.busy { ProgressView("Getting routing information from your peer") }
        }
    }
}
