import LightningCore
import SwiftUI

struct LightningLiquidityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let controller: LightningAppController
    @State private var capacity = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var editingCapacity: Bool
    var body: some View {
        Form {
            Section {
                Text(controller.profile?.name ?? "Choose a provider").font(.headline)
                Text("The provider supplies receiving capacity. Your keys stay on this device. Its setup invoice pays for a channel; that payment is a fee, not a deposit into your wallet.")
                    .font(.footnote)
                if let intent = controller.receiveIntent {
                    LabeledContent("Payment you want to receive", value: "\(intent.amountSat) sats")
                        .accessibilityIdentifier("lightningRequestedReceive")
                }
            }
            if let quote = controller.liquidityQuote {
                quoteSection(quote)
            }
            if let provider = LightningProviders.provider(controller.profile), provider.manualSetup {
                Section("Set up on the provider's website") {
                    Text("LNServer uses website setup. Copy this wallet's node ID, choose a private channel, and review the fee on LNServer before paying. Winnow does not pay the fee for you.")
                    Text(controller.nodeID).font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("lightningSetupNodeID").accessibilityValue(controller.nodeID)
                    Button("Copy wallet node ID") { ClipboardPolicy.interchange.apply(controller.nodeID) }
                    Link("Open LNServer setup", destination: provider.website)
                    Button("Sync and check receiving capacity") { run { await model.syncNow(); await controller.resume(model: model) } }
                }
            } else if controller.liquidityQuote?.accepted != true {
                Section("Receiving capacity") {
                    if let info = controller.liquidityInfo {
                        LabeledContent("Provider minimum", value: "\(info.minimumCapacitySat) sats")
                        TextField("Capacity in sats", text: $capacity).keyboardType(.numberPad)
                            .focused($editingCapacity)
                            .accessibilityIdentifier("lightningInboundCapacity")
                        Text("The provider minimum can be larger than your payment. Capacity is a limit on what can arrive, not an amount you must send.").font(.footnote)
                        Button("Get setup fee quote") { editingCapacity = false; run {
                            guard let sats = UInt64(capacity) else { throw LightningError.invalidAmount }
                            try await controller.quoteLiquidity(capacitySat: sats, model: model)
                        } }.accessibilityIdentifier("lightningQuoteCapacity")
                    } else {
                        Button("Check provider options") { run {
                            try await controller.prepareLiquidity(model: model)
                            try proposedCapacity()
                        } }.disabled(!controller.chainCurrent).accessibilityIdentifier("lightningProviderOptions")
                        if !controller.chainCurrent {
                            Text("Bitcoin is still syncing. Provider setup becomes available after Winnow verifies the chain.")
                                .accessibilityIdentifier("lightningSetupWaitingForChain")
                        }
                    }
                }
            }
            Section {
                if busy { ProgressView("Checking provider…") }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lightningLiquidityError") }
                Text("Channels require at least three block confirmations. Keep Winnow open while setup completes. This beta has no external watchtower; background checks run when iOS allows them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Set up receiving")
        .disabled(busy)
        .toolbar { ToolbarItem(placement: .keyboard) { Button("Done") { editingCapacity = false }.accessibilityIdentifier("sendKeyboardDone") } }
        .task { if controller.liquidityInfo != nil { try? proposedCapacity() } }
    }
    @ViewBuilder private func quoteSection(_ quote: LightningAppController.LiquidityQuote) -> some View {
        Section("Review setup fee") {
            LabeledContent("Setup fee", value: "\(quote.feeSat) sats").accessibilityIdentifier("lightningSetupFee")
            LabeledContent("Channel capacity", value: "\(quote.request.lspBalanceSat) sats")
            LabeledContent("Minimum lease", value: "\(quote.request.channelExpiryBlocks) blocks")
            LabeledContent("Confirmations", value: "\(quote.request.requiredChannelConfirmations)")
            Text("This purchases capacity to receive payments. The capacity is not your wallet balance.").font(.footnote)
            receivingCapacityStatus()
            pausedSetupStatus(quote)
            LabeledContent("Provider order", value: quote.order.orderId)
            orderExpiry(quote)
            setupPayment(quote)
            pauseSetup(quote)
        }
    }
    @ViewBuilder private func receivingCapacityStatus() -> some View {
        if controller.maximumReceivableSat >= (controller.receiveIntent?.amountSat ?? 1) {
            Text("Receiving capacity is ready. Return to Receive Lightning to create your payment invoice.")
                .accessibilityIdentifier("lightningReceivingReady")
            Button("Continue to receive invoice") { dismiss() }
        }
    }
    @ViewBuilder private func pausedSetupStatus(_ quote: LightningAppController.LiquidityQuote) -> some View {
        if quote.cancelledAt != nil {
            Text("Setup paused. Winnow has not paid this fee. The unpaid provider order is retained until it expires; paying a previously shared setup invoice can still activate it.")
                .accessibilityIdentifier("lightningSetupCancelled")
        }
    }
    @ViewBuilder private func orderExpiry(_ quote: LightningAppController.LiquidityQuote) -> some View {
        if let expiry = quote.order.payment.bolt11?.expiresAt { LabeledContent("Order expires", value: expiry) }
    }
    @ViewBuilder private func setupPayment(_ quote: LightningAppController.LiquidityQuote) -> some View {
        if quote.accepted {
            LabeledContent("Setup status", value: quote.order.orderState).accessibilityIdentifier("lightningSetupStatus")
            TimelineView(.periodic(from: .now, by: 1)) { context in setupInvoice(quote, now: UInt64(context.date.timeIntervalSince1970)) }
            Button("Check setup payment and sync") { run { try await controller.refreshLiquidityOrder(model: model) } }
                .accessibilityIdentifier("lightningCheckSetup")
        } else {
            Text("Winnow will show the payment invoice after you approve this fee. Approval does not send funds.").font(.footnote)
            Button("Approve \(quote.feeSat)-sat setup fee") { run { try await controller.acceptLiquidityQuote(model: model) } }
                .accessibilityIdentifier("lightningApproveSetupFee")
        }
    }
    @ViewBuilder private func setupInvoice(_ quote: LightningAppController.LiquidityQuote, now: UInt64) -> some View {
        if quote.isPayable(network: controller.network, now: now) {
            Text("Pay this setup invoice from another Lightning wallet. You will create a separate receive invoice after the channel is confirmed.")
            QRCodeView(content: quote.invoice.uppercased()).frame(width: 240, height: 240).frame(maxWidth: .infinity)
            Text(quote.invoice).font(.caption.monospaced()).lineLimit(3)
                .accessibilityIdentifier("lightningSetupInvoice").accessibilityValue(quote.invoice)
            Button("Copy setup fee invoice") { ClipboardPolicy.interchange.apply(quote.invoice) }
                .accessibilityIdentifier("lightningCopySetupInvoice")
            ShareLink("Share setup fee invoice", item: quote.invoice)
        } else { Text("This invoice is paid, expired, or unavailable. Check the order status and sync before creating another setup order.") }
    }
    @ViewBuilder private func pauseSetup(_ quote: LightningAppController.LiquidityQuote) -> some View {
        if quote.order.payment.bolt11?.state == "EXPECT_PAYMENT" {
            Button("Pause setup", role: .cancel) { run { try controller.cancelLiquiditySetup(model: model); dismiss() } }
                .accessibilityIdentifier("lightningCancelSetup")
        }
    }
    private func proposedCapacity() throws {
        guard let info = controller.liquidityInfo else { throw LightningError.invalidState }
        let requested = try controller.receiveIntent?.capacity(using: info) ?? info.minimumCapacitySat
        capacity = String(requested)
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { try await action(); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}
