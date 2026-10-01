import LightningCore
import SwiftUI

/// Instant receiving: the fee the provider keeps, what arrives, and the trust
/// involved, all shown before anything is bought.
struct LightningJITReceiveSection: View {
    @Environment(AppModel.self) private var model
    let controller: LightningAppController
    let amountSat: UInt64?
    let created: (String) -> Void
    let failed: (Error) -> Void
    @State private var quote: LightningAppController.JITQuote?
    @State private var busy = false

    var body: some View {
        Section("Receive instantly") {
            Text("The first payment opens your Lightning channel. The provider keeps a fee from it; nothing is paid up front.")
            if let smallest = controller.smallestJITPaymentSat {
                Text("Smallest first payment: \(smallest) sats").font(.footnote).accessibilityIdentifier("lightningJITMinimum")
            }
            if let quote { terms(quote) }
            else {
                Button("Show the provider's fee") { load() }
                    .disabled(amountSat == nil || busy).accessibilityIdentifier("lightningJITTerms")
            }
            if busy { ProgressView() }
        }
        .onChange(of: amountSat) { _, _ in quote = nil }
    }
    @ViewBuilder private func terms(_ quote: LightningAppController.JITQuote) -> some View {
        LabeledContent("Provider keeps", value: "\(quote.feeSat) sats").accessibilityIdentifier("lightningJITFee")
        LabeledContent("You receive", value: "\(quote.receivedSat) sats").accessibilityIdentifier("lightningJITReceived")
        Text("\(controller.profile?.name ?? "The provider") opens a private channel for this payment and keeps it open for at least \(quote.lifetimeDays) days. Winnow accepts the channel before it confirms, so until then you trust the provider with this payment.")
            .font(.footnote).foregroundStyle(.secondary)
        Text("Keep Winnow open while the payer pays.").font(.footnote).foregroundStyle(.secondary)
        Button("Approve fee and show invoice") { approve(quote) }.disabled(busy).accessibilityIdentifier("lightningJITApprove")
    }
    private func load() {
        guard let amountSat else { return }
        run {
            if controller.jitMenu == nil { try await controller.prepareJIT(model: model) }
            quote = try controller.quoteJIT(amountSat: amountSat)
        }
    }
    private func approve(_ quote: LightningAppController.JITQuote) {
        run { created(try await controller.approveJIT(quote, model: model)) }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { try await action() }
            catch {
                // Terms may have expired; the next attempt fetches fresh ones.
                controller.jitMenu = nil; quote = nil
                failed(error)
            }
        }
    }
}
