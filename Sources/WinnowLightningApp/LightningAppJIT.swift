import Foundation
import LightningCore
import WalletCore

/// Instant receiving (LSPS2): the provider opens a channel with the first
/// payment and keeps its fee out of it. Winnow buys nothing until the person
/// approves that fee.
extension LightningAppController {
    struct JITQuote: Sendable, Equatable {
        let paymentMsat: UInt64, feeMsat: UInt64
        let offer: LightningJIT.Offer
        var feeSat: UInt64 { (feeMsat + 999) / 1000 }
        var receivedSat: UInt64 { (paymentMsat - feeMsat) / 1000 }
        /// Blocks the provider promises to keep the channel open, in days.
        var lifetimeDays: UInt32 { offer.params.minLifetime / 144 }
    }
    var supportsJIT: Bool { profile?.supportsJIT == true }
    /// The smallest payment that can open an instant channel, in sats.
    var smallestJITPaymentSat: UInt64? { jitMenu?.smallestPaymentMsat(now: Self.now).map { ($0 + 999) / 1000 } }

    func prepareJIT(model: AppModel) async throws {
        try requireNetwork(model)
        let epoch = generation
        await resume(model: model)
        try requireNetwork(model, generation: epoch)
        guard chainCurrent else {
            throw LightningLiquidityError.provider("Bitcoin is still syncing. Wait for the chain check before receiving with Lightning.")
        }
        guard let profile, profile.supportsJIT else { throw LightningLiquidityError.unavailable }
        guard let session = liquiditySession, await session.status == .connected else {
            throw LightningLiquidityError.provider(error ?? "The provider is not connected yet. Reconnect and try again.")
        }
        let menu = try await session.jitMenu(token: LightningProviders.provider(profile)?.token ?? "", now: Self.now)
        try requireNetwork(model, generation: epoch)
        jitMenu = menu
    }
    func quoteJIT(amountSat: UInt64) throws -> JITQuote {
        guard let menu = jitMenu else { throw LightningError.invalidState }
        let (paymentMsat, overflow) = amountSat.multipliedReportingOverflow(by: 1000)
        guard !overflow else { throw LightningError.invalidAmount }
        let best = try menu.cheapest(paymentMsat: paymentMsat, now: Self.now)
        return JITQuote(paymentMsat: paymentMsat, feeMsat: best.feeMsat, offer: best.offer)
    }
    /// After Face ID, reserves the channel with the provider and returns the
    /// invoice the payer pays. The fee was shown before approval.
    func approveJIT(_ quote: JITQuote, model: AppModel) async throws -> String {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            guard let engine, let profile, let wallet = model.wallet, let session = liquiditySession else {
                throw LightningError.invalidState
            }
            let epoch = generation
            try await model.authenticateSensitiveAction(reason: "Receive with a \(quote.feeSat)-sat provider fee kept from this payment")
            defer { model.keychainAuthentication.revoke() }
            try Task.checkCancellation(); try requireNetwork(model, generation: epoch)
            let purchase = try await session.jitBuy(quote.offer, paymentSizeMsat: quote.paymentMsat)
            let destination = try await recoveryDestination(wallet: wallet)
            try requireNetwork(model, generation: epoch)
            let terms = LightningEngine.JITTerms(provider: profile.peerKey, offer: quote.offer, purchase: purchase,
                                                 paymentSizeMsat: quote.paymentMsat)
            return try await engine.createJITInvoice(id: Self.freshID(), terms: terms, recoveryDestination: destination,
                                                     recoveryFeeSat: Self.recoveryFeeSat, network: network, now: Self.now)
        }
    }
}
