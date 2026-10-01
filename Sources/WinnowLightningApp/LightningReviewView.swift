import LightningCore
import SwiftUI
import WalletCore

enum LightningReview: Identifiable {
    case profile(LightningProfile)
    case funding(LightningAppController.FundingReview)
    case payment(LightningAppController.PaymentReview)
    case invoice(LightningAppController.InvoiceReview)
    case feeBump(LightningAppController.FeeBumpReview)
    case ordinaryInvoice(LightningAppController.OrdinaryInvoiceReview)
    case close(LightningAppController.CloseReview)
    var id: String {
        switch self {
        case .profile(let profile): "profile-" + profile.peer
        case .funding(let review): "funding-" + review.request.temporaryID.hex
        case .payment(let review): "payment-" + review.request.id.hex
        case .invoice(let review): "invoice-" + review.request.id.hex
        case .feeBump(let review): "fee-bump-" + review.quote.id.hex
        case .ordinaryInvoice(let review): "ordinary-invoice-" + review.request.id.hex
        case .close(let review): "close-\(review.force)-" + review.channel.id.hex
        }
    }

    @MainActor
    func confirm(controller: LightningAppController, model: AppModel) async throws {
        switch self {
        case .profile(let profile): try await controller.saveProfile(profile, model: model)
        case .funding(let review): try await controller.fund(review, model: model)
        case .payment(let review): try await controller.pay(review, model: model)
        case .invoice(let review): try await controller.payInvoice(review, model: model)
        case .feeBump(let review): try await controller.approveFeeBump(review, model: model)
        case .ordinaryInvoice(let review): try await controller.payOrdinaryInvoice(review, model: model)
        case .close(let review): try await controller.close(review, model: model)
        }
    }
}

struct LightningReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: LightningAppController
    let review: LightningReview
    var onConfirmed: () -> Void = {}
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                details
                Section {
                    Text(controller.networkNotice).font(.footnote)
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lightningReviewError") }
                    Button(busy ? "Confirming…" : "Confirm") { confirm() }
                        .disabled(busy).accessibilityIdentifier("lightningConfirm")
                }
            }
            .navigationTitle("Review Lightning")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(busy).accessibilityIdentifier("lightningCancel")
            } }
            .interactiveDismissDisabled(busy)
        }
    }
    @ViewBuilder private var details: some View {
        switch review {
        case .profile(let profile): profileSection(profile)
        case .funding(let review): fundingSection(review)
        case .payment(let review): paymentSection(review)
        case .invoice(let review): invoiceSection(review)
        case .close(let review): closeSection(review)
        case .feeBump(let review): feeBumpSection(review)
        case .ordinaryInvoice(let review): ordinaryInvoiceSection(review)
        }
    }
    private func profileSection(_ profile: LightningProfile) -> some View {
        Section("Provider") {
            LabeledContent("Name", value: profile.name)
            LabeledContent("Endpoint", value: profile.endpoint)
            Text(profile.peer).font(.caption.monospaced())
            Text("Automatic channel recovery returns funds to this wallet, with a maximum fee of 500 sats per recovery transaction. Opening and payments still require a separate review.")
        }
    }
    private func fundingSection(_ review: LightningAppController.FundingReview) -> some View {
        Section("Channel funding") {
            LabeledContent("Capacity", value: "\(review.request.amountSat) sats")
            LabeledContent("On-chain fee", value: "\(review.preview.fee) sats")
            LabeledContent("Total", value: "\(Int64(review.request.amountSat) + review.preview.fee) sats")
            Text(review.preview.destination).font(.caption.monospaced())
            Text("Winnow reserves the reviewed wallet inputs. Once submitted, funding cannot be canceled merely because the peer disconnects.")
        }
    }
    private func paymentSection(_ review: LightningAppController.PaymentReview) -> some View {
        Section("Send payment") {
            LabeledContent("Amount", value: "\(review.request.amountMsat / 1000) sats")
            LabeledContent("Maximum fee", value: "\(review.request.feeLimitMsat / 1000) sats")
            LabeledContent("Maximum expiry", value: "\(review.request.maximumDelta) blocks")
            DisclosureGroup("Receive offer") {
                Text(review.offerText).font(.caption.monospaced()).textSelection(.enabled)
            }
            Text("Funds may remain committed while the recipient is offline. “Awaiting recipient” means pending; only “Settled” confirms payment.")
        }
    }
    private func invoiceSection(_ review: LightningAppController.InvoiceReview) -> some View {
        Section("Send payment") {
            LabeledContent("Amount", value: "\(Bolt11Invoice.sats(review.request.amountMsat)) sats")
            LabeledContent("Routing fee", value: "\(Bolt11Invoice.sats(review.quote.feeMsat)) sats")
            LabeledContent("Maximum fee", value: "\(Bolt11Invoice.sats(review.request.feeLimitMsat)) sats")
            LabeledContent("Total", value: "\(Bolt11Invoice.sats(review.quote.amountMsat)) sats")
            LabeledContent("Payment timeout", value: "\(review.quote.delta) blocks")
            if let description = review.description { Text(description) }
            DisclosureGroup("Recipient and invoice") {
                Text(review.payee.hex).font(.caption.monospaced())
                Text(review.request.invoice).font(.caption.monospaced()).textSelection(.enabled)
            }
            Text("Invoice expires \(Date(timeIntervalSince1970: Double(review.expiresAt)).formatted()). Keep Winnow open while paying. Pending is not confirmation.")
        }
    }
    @ViewBuilder
    private func closeSection(_ review: LightningAppController.CloseReview) -> some View {
        let force = review.force
        Section(force ? "Force close" : "Cooperative close") {
            Text(force ? "Publish the latest enforceable commitment. Returning funds may require a delay and additional recovery transactions." : "Ask the provider to close this channel and return funds to your Winnow wallet.")
            Text(force ? "The commitment fee is already fixed by the signed channel state. Recovery transactions use the approved 500-sat fee limit." : "The fee uses Winnow’s wallet fee policy and includes space for the provider’s closing output.")
            if !force {
                LabeledContent("Maximum negotiated fee", value: "\(review.feeSat) sats")
                    .accessibilityIdentifier("lightningCloseMaximumFee")
                LabeledContent("Return address") { Text(review.address).font(.caption.monospaced()) }
            }
        }
    }
    private func feeBumpSection(_ review: LightningAppController.FeeBumpReview) -> some View {
        Section("Recovery fee bump") {
            LabeledContent("Parent fee", value: "\(review.quote.parentFeeSat) sats")
            LabeledContent("Child fee", value: "\(review.quote.feeSat) sats")
            LabeledContent("Total package fee", value: "\(review.quote.packageFeeSat) sats")
            LabeledContent("Maximum total fee", value: "\(review.quote.totalFeeLimitSat) sats")
            LabeledContent("Wallet inputs", value: "\(review.quote.selected.count)")
            Text(review.quote.kind == .commitment ? "Approval publishes the current commitment and its fee-paying child. The channel will close." : "Approval adds reserved wallet inputs to the signed HTLC recovery transaction.")
            Text("Signing requires device authentication. Background work can only relay already approved signed transactions.")
        }
    }
    private func ordinaryInvoiceSection(_ review: LightningAppController.OrdinaryInvoiceReview) -> some View {
        Section("Reusable offer payment") {
            if let name = review.name { LabeledContent("DNSSEC name", value: name.display) }
            if let description = review.invoice.offer.description { Text(description) }
            LabeledContent("Amount", value: "\(Bolt11Invoice.sats(review.invoice.amountMsat)) sats")
            LabeledContent("Routing fee", value: "\(Bolt11Invoice.sats(review.quote.feeMsat)) sats")
            LabeledContent("Maximum fee", value: "\(Bolt11Invoice.sats(review.request.feeLimitMsat)) sats")
            LabeledContent("Total", value: "\(Bolt11Invoice.sats(review.quote.amountMsat)) sats")
            LabeledContent("Payment timeout", value: "\(review.quote.delta) blocks")
            DisclosureGroup("Signed invoice") { Text(review.invoice.string).font(.caption.monospaced()).textSelection(.enabled) }
            Text("The invoice signature binds the recipient, payment hash, amount and your request. Keep Winnow open until payment settles.")
        }
    }
    private func confirm() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await review.confirm(controller: controller, model: model)
                onConfirmed()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
