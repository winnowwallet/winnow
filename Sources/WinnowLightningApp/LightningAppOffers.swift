import Foundation
import LightningCore

extension LightningAppController {
    struct OrdinaryInvoiceReview {
        let request: LightningEngine.OrdinaryInvoicePayment
        let profile: LightningProfile
        let quote: Bolt12PaymentRoute.Quote
        let invoice: Bolt12Invoice
        let name: BIP353Name?
        let nameValidUntil: UInt64?
    }
    private func ordinaryPaymentConnection(_ model: AppModel) async throws -> (LightningEngine, LightningPeerSession, LightningProfile) {
        try requireNetwork(model)
        guard let engine, let session = liquiditySession, let profile, await session.status == .connected,
              recoveryStatus == nil else { throw LightningInvoiceError.unavailable }
        return (engine, session, profile)
    }
    func reviewOrdinaryOffer(_ input: String, amountMsat: UInt64, maximumFeeSat: UInt64, model: AppModel) async throws -> OrdinaryInvoiceReview {
        let epoch = generation
        let (engine, session, profile) = try await ordinaryPaymentConnection(model)
        guard maximumFeeSat <= 100_000 else { throw LightningError.invalidAmount }
        let (offer, resolved) = try await resolveOrdinaryDestination(input, chain: engine.chainHash())
        let via = try await session.ordinaryOfferPath(offer: offer)
        try Task.checkCancellation(); try requireNetwork(model, generation: epoch)
        let request = LightningEngine.OrdinaryOfferRequest(id: Self.freshID(), offer: offer, amountMsat: amountMsat, via: via, humanReadableName: resolved?.name)
        try await engine.requestOrdinaryInvoice(request, now: Self.now)
        do {
            try Task.checkCancellation(); try requireNetwork(model, generation: epoch)
            try await session.flush()
            let invoice = try await waitForOrdinaryInvoice(request.id, engine: engine, session: session, model: model, epoch: epoch)
            return try await ordinaryReview(invoice, id: request.id, profile: profile, session: session, engine: engine,
                maximumFeeSat: maximumFeeSat, name: resolved?.name, nameValidUntil: resolved?.validUntil, model: model, epoch: epoch)
        } catch {
            try? await engine.cancelOrdinaryInvoiceRequest(id: request.id)
            throw error
        }
    }
    private func resolveOrdinaryDestination(_ input: String, chain: Data) async throws -> (LightningOffer, BIP353PaymentInstructions?) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("@") else { return (try LightningOffer(string: text), nil) }
        let resolved = try await BIP353Resolver().resolve(BIP353Name(text), chain: chain, now: Self.now)
        return (resolved.offer, resolved)
    }
    private func waitForOrdinaryInvoice(_ id: Data, engine: LightningEngine, session: LightningPeerSession,
                                        model: AppModel, epoch: UInt64) async throws -> Bolt12Invoice {
        while true {
            try Task.checkCancellation(); try requireNetwork(model, generation: epoch)
            let status = try await pendingOrdinaryInvoice(id, engine: engine, session: session)
            if let invoice = status.invoice { return invoice }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
    private func pendingOrdinaryInvoice(_ id: Data, engine: LightningEngine, session: LightningPeerSession) async throws -> LightningEngine.OrdinaryInvoiceStatus {
        guard await session.status == .connected else { throw LightningInvoiceError.unavailable }
        guard let status = try await engine.ordinaryInvoiceRequests(now: Self.now).first(where: { $0.request.id == id }), !status.expired else {
            throw LightningInvoiceError.unavailable
        }
        return status
    }
    private func ordinaryReview(_ invoice: Bolt12Invoice, id: Data, profile: LightningProfile, session: LightningPeerSession, engine: LightningEngine,
                                maximumFeeSat: UInt64, name: BIP353Name?, nameValidUntil: UInt64?, model: AppModel, epoch: UInt64) async throws -> OrdinaryInvoiceReview {
        let route = try await session.ordinaryInvoiceRoute(invoice: invoice, feeLimitMsat: maximumFeeSat * 1000)
        try Task.checkCancellation(); try requireNetwork(model, generation: epoch)
        guard self.profile == profile, maximumFeeSat <= 100_000,
              let channel = channels.first(where: { $0.peer == route.peer && $0.phase == .ready }) else { throw LightningInvoiceError.changed }
        let request = LightningEngine.OrdinaryInvoicePayment(id: id, channelID: channel.id, invoice: invoice, feeLimitMsat: maximumFeeSat * 1000, route: route)
        let quote = try await engine.ordinaryInvoiceQuote(request, now: Self.now)
        try validateOrdinaryContext(profile, model: model, epoch: epoch)
        return OrdinaryInvoiceReview(request: request, profile: profile, quote: quote, invoice: invoice, name: name, nameValidUntil: nameValidUntil)
    }
    func reviewSavedOrdinaryInvoice(_ status: LightningEngine.OrdinaryInvoiceStatus, maximumFeeSat: UInt64, model: AppModel) async throws -> OrdinaryInvoiceReview {
        let epoch = generation, (engine, session, profile) = try await ordinaryPaymentConnection(model)
        guard let invoice = status.invoice, maximumFeeSat <= 100_000, status.request.humanReadableName == nil else { throw LightningInvoiceError.changed }
        return try await ordinaryReview(invoice, id: status.request.id, profile: profile, session: session, engine: engine,
            maximumFeeSat: maximumFeeSat, name: nil, nameValidUntil: nil, model: model, epoch: epoch)
    }
    func payOrdinaryInvoice(_ review: OrdinaryInvoiceReview, model: AppModel) async throws {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            let epoch = generation
            guard let engine, profile == review.profile else { throw LightningInvoiceError.changed }
            try await model.authenticateSensitiveAction(reason: "Approve this \(network.rawValue) Lightning offer payment and maximum fee")
            defer { model.keychainAuthentication.revoke() }
            try Task.checkCancellation(); try requireNetwork(model, generation: epoch)
            try await recheckOrdinaryInvoice(review, engine: engine)
            try validateOrdinaryApproval(review, model: model, epoch: epoch)
            _ = try await engine.payOrdinaryInvoice(review.request, now: Self.now)
            try await refresh()
        }
    }
    private func recheckOrdinaryInvoice(_ review: OrdinaryInvoiceReview, engine: LightningEngine) async throws {
        try validateOrdinaryName(review)
        guard profile == review.profile else { throw LightningInvoiceError.changed }
        let current = try await engine.ordinaryInvoiceQuote(review.request, now: Self.now)
        guard current == review.quote else { throw LightningInvoiceError.changed }
    }
    private func validateOrdinaryName(_ review: OrdinaryInvoiceReview) throws {
        guard let validUntil = review.nameValidUntil else { return }
        guard Self.now < validUntil else { throw LightningInvoiceError.changed }
    }
    private func validateOrdinaryContext(_ expected: LightningProfile, model: AppModel, epoch: UInt64) throws {
        try Task.checkCancellation(); try requireNetwork(model, generation: epoch)
        guard profile == expected else { throw LightningInvoiceError.changed }
    }
    private func validateOrdinaryApproval(_ review: OrdinaryInvoiceReview, model: AppModel, epoch: UInt64) throws {
        try validateOrdinaryContext(review.profile, model: model, epoch: epoch)
        try validateOrdinaryName(review)
    }
    func registerOrdinaryOffer(model: AppModel) async throws {
        let (engine, _, profile) = try await ordinaryPaymentConnection(model)
        _ = try await engine.registerOrdinaryOffer(.init(id: Self.freshID(), peer: profile.peerKey,
            description: "Payment to Winnow", expiresAt: Self.now + 30 * 86400), now: Self.now)
        try await refresh()
    }
    func cancelOrdinaryRequest(_ id: Data) async { try? await engine?.cancelOrdinaryInvoiceRequest(id: id) }
}
