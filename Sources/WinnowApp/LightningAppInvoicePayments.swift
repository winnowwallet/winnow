import Foundation
import LightningCore

extension LightningAppController {
    struct InvoiceReview {
        let request: LightningEngine.InvoicePayment
        let profile: LightningProfile
        let quote: Bolt11PaymentRoute.Quote
        let description: String?, payee: Data, expiresAt: UInt64
    }
    func reviewInvoice(_ invoice: String, amountMsat: UInt64, maximumFeeSat: UInt64, model: AppModel) async throws -> InvoiceReview {
        try requireNetwork(model)
        let epoch = generation, decoded = try Bolt11Invoice.decode(invoice, network: network)
        try decoded.validatePayment(amountMsat: amountMsat, now: Self.now)
        guard maximumFeeSat <= 100_000, let engine, let profile,
              let channel = channels.first(where: { $0.peer == profile.peerKey && $0.phase == .ready }),
              let session = liquiditySession, await session.status == .connected else { throw LightningInvoiceError.unavailable }
        let route = try await session.invoiceRoute(invoice: invoice, network: network, amountMsat: amountMsat, feeLimitMsat: maximumFeeSat * 1000)
        try Task.checkCancellation(); try requireNetwork(model, generation: epoch)
        guard self.profile == profile else { throw LightningInvoiceError.changed }
        let request = LightningEngine.InvoicePayment(id: Self.freshID(), peer: profile.peerKey, channelID: channel.id,
            invoice: invoice, network: network, amountMsat: amountMsat, feeLimitMsat: maximumFeeSat * 1000, maximumDelta: 2016, route: route)
        return try await InvoiceReview(request: request, profile: profile, quote: engine.invoiceQuote(request, now: Self.now),
                                       description: decoded.description, payee: decoded.payee, expiresAt: decoded.expiresAt)
    }
    func payInvoice(_ review: InvoiceReview, model: AppModel) async throws {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            let epoch = generation
            guard let engine, profile == review.profile else { throw LightningInvoiceError.changed }
            try await model.authenticateSensitiveAction(reason: "Approve this \(network.rawValue) Lightning invoice payment and maximum fee")
            defer { model.keychainAuthentication.revoke() }
            try Task.checkCancellation(); try requireNetwork(model, generation: epoch)
            guard profile == review.profile else { throw LightningInvoiceError.changed }
            let current = try await engine.invoiceQuote(review.request, now: Self.now)
            guard current.feeMsat == review.quote.feeMsat, current.amountMsat == review.quote.amountMsat,
                  current.delta == review.quote.delta else { throw LightningInvoiceError.changed }
            _ = try await engine.payInvoice(review.request, now: Self.now)
            try await refresh()
        }
    }
}
