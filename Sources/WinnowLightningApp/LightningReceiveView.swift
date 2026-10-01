import LightningCore
import SwiftUI
import WalletCore

struct LightningReceiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: LightningAppController
    var useBitcoin: (() -> Void)?
    @State private var amount = ""
    @State private var invoice: String?
    @State private var invoiceExpiry: Date?
    @State private var invoiceHash: Data?
    @State private var setup = false
    @State private var busy = false
    @State private var error: String?
    @State private var capacitySetup = false
    @FocusState private var editingAmount: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(controller.networkNotice).font(.footnote)
                    LabeledContent("Provider", value: controller.profile?.name ?? "Choose a provider")
                        .accessibilityIdentifier("lightningReceiveProvider").accessibilityValue(controller.profile?.name ?? "Choose a provider")
                    LabeledContent("Connection", value: controller.connection)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Connection").accessibilityValue(controller.connection)
                        .accessibilityIdentifier("lightningReceiveConnection")
                    LabeledContent("Can receive", value: "\(controller.maximumReceivableSat) sats")
                        .accessibilityIdentifier("lightningReceivable")
                }
                if let invoice, let invoiceExpiry {
                    invoiceSection(invoice, expires: invoiceExpiry)
                } else {
                    amountSection
                    receivingSection
                }
                Section {
                    if let warning = controller.peerWarning { Text(warning).foregroundStyle(.secondary) }
                    if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lightningReceiveError") }
                    Button("Sync and reconnect") { run { await model.syncNow(); await controller.resume(model: model) } }
                        .accessibilityIdentifier("lightningReceiveReconnect")
                    Text("Use a Lightning invoice for a Lightning payment or withdrawal. Use a Bitcoin address for an on-chain payment or withdrawal.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Keep Winnow open while receiving this invoice. It is a single-use invoice; offline async offers are available in Advanced mode.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let useBitcoin { Button("Receive Bitcoin instead", action: useBitcoin) }
                }
            }
            .navigationTitle("Receive Lightning")
            .disabled(busy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .keyboard) { Button("Done") { editingAmount = false }.accessibilityIdentifier("sendKeyboardDone") }
            }
            .navigationDestination(isPresented: $capacitySetup) { LightningLiquidityView(controller: controller) }
            .sheet(isPresented: $setup) { LightningSetupView(controller: controller) }
            .task {
                if amount.isEmpty, let intent = controller.receiveIntent { amount = String(intent.amountSat) }
                while !Task.isCancelled {
                    do { try await controller.refresh(); try await Task.sleep(for: .seconds(1)) }
                    catch is CancellationError { return }
                    catch { self.error = error.localizedDescription; return }
                }
            }
        }
    }
    private var requestedAmount: UInt64? { UInt64(amount).flatMap { $0 > 0 ? $0 : nil } }
    private var canReceiveAmount: Bool {
        guard let requestedAmount else { return false }
        return requestedAmount <= controller.maximumReceivableSat
    }
    private var amountSection: some View {
        Section("How much do you want to receive?") {
            TextField("Amount in sats", text: $amount).keyboardType(.numberPad).focused($editingAmount)
                .accessibilityIdentifier("lightningReceiveAmount")
            if canReceiveAmount {
                Button("Create Lightning invoice") { editingAmount = false; run { try await createInvoice() } }
                    .accessibilityIdentifier("lightningCreateInvoice")
            }
        }
    }
    @ViewBuilder private var receivingSection: some View {
        if !canReceiveAmount && controller.supportsJIT {
            LightningJITReceiveSection(controller: controller, amountSat: requestedAmount, created: show) {
                error = $0.localizedDescription
            }
            Section { Button("Choose provider") { setup = true }.accessibilityIdentifier("lightningReceiveSetup") }
        } else if !canReceiveAmount {
            Section("Set up Lightning receiving") {
                Text("Enter the payment amount first. Winnow checks the provider's minimum capacity and shows its actual setup fee before you approve anything.")
                if let notice = controller.receivingSetupNotice { Text(notice) }
                Button("Get receiving capacity") { editingAmount = false; run {
                    guard let requestedAmount else { throw LightningError.invalidAmount }
                    try controller.setReceiveAmount(requestedAmount, model: model)
                    capacitySetup = true
                } }.disabled(controller.profile?.liquidityProvider == nil || requestedAmount == nil)
                    .accessibilityIdentifier("lightningGetCapacity")
                Button("Choose provider") { setup = true }.accessibilityIdentifier("lightningReceiveSetup")
            }
        }
    }
    private func createInvoice() async throws {
        guard let requestedAmount else { throw LightningError.invalidAmount }
        try controller.setReceiveAmount(requestedAmount, model: model)
        show(try await controller.createReceiveInvoice(amountSat: requestedAmount, model: model))
    }
    private func show(_ created: String) {
        guard let decoded = try? Bolt11Invoice.decode(created, network: controller.network) else { return }
        invoice = created; invoiceHash = decoded.paymentHash; error = nil
        invoiceExpiry = Date(timeIntervalSince1970: TimeInterval(decoded.expiresAt))
    }
    private func invoiceSection(_ invoice: String, expires: Date) -> some View {
        Section("Lightning invoice · \(controller.network.rawValue)") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let received = controller.payments.first { $0.hash == invoiceHash && $0.phase == .settled }
                if let received { receivedNotice(received) }
                else if context.date >= expires { Text("Invoice expired. Create a new invoice.") }
                else { payableInvoice(invoice, expires: expires) }
            }
            Button("New Lightning invoice") { self.invoice = nil; invoiceExpiry = nil; invoiceHash = nil }
        }
    }
    /// An instant receive also says what the provider kept.
    @ViewBuilder private func receivedNotice(_ payment: LightningEngine.Payment) -> some View {
        Text("Payment received").accessibilityIdentifier("lightningInvoicePaid")
        if let fee = payment.feeMsat {
            Text("Received \(payment.amountMsat / 1000) sats · provider kept \((fee + 999) / 1000) sats")
                .font(.footnote).accessibilityIdentifier("lightningInvoiceFeeKept")
        }
    }
    private func payableInvoice(_ invoice: String, expires: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            QRCodeView(content: invoice.uppercased()).frame(width: 240, height: 240)
                .frame(maxWidth: .infinity)
            Text(invoice).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
                .accessibilityIdentifier("lightningReceiveInvoice").accessibilityValue(invoice)
            Text("Expires \(expires.formatted())").font(.caption)
            Button("Copy Lightning invoice") { ClipboardPolicy.interchange.apply(invoice) }
                .accessibilityIdentifier("lightningCopyInvoice")
            ShareLink("Share Lightning invoice", item: invoice).accessibilityIdentifier("lightningShareInvoice")
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { try await action(); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}
