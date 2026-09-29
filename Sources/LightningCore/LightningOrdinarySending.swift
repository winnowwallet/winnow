import Foundation
import P256K

extension LightningEngine {
    /// Fetching an invoice authorizes no payment. Only payOrdinaryInvoice can
    /// create the HTLC after the caller has reviewed its exact amount and fees.
    public func requestOrdinaryInvoice(_ request: OrdinaryOfferRequest, now: UInt64) throws {
        guard let peer = request.via.first else { throw LightningError.invalidMessage }
        try requireUsableChannels(); try operational(peer)
        if let previous = state.offers?.outgoing.first(where: { $0.request.id == request.id }) {
            guard previous.request == request else { throw LightningError.invalidMessage }; return
        }
        guard request.id.count == 32, request.via.count <= 19, (state.offers?.outgoing.count ?? 0) < 4096 else { throw LightningError.invalidMessage }
        let offer = try LightningOffer(bytes: request.offer)
        try offer.validatePayment(chain: state.chain, now: now, amountMsat: request.amountMsat)
        let path = try ordinaryRequestPath(offer)
        guard let issuer = offer.signingKey ?? path.hops.last?.nodeID else { throw LightningError.invalidMessage }
        let secret = try P256K.Signing.PrivateKey().dataRepresentation
        let invoiceRequest = try InvoiceRequest(offer: offer, chain: state.chain, amountMsat: request.amountMsat, now: now,
            metadata: request.id, payerSecret: secret, humanReadableName: request.humanReadableName)
        var next = state, offers = next.offers ?? OrdinaryOfferState()
        offers.outgoing.append(OrdinaryOutgoing(request: request, invoiceRequest: invoiceRequest.bytes,
            expectedIssuer: issuer, payerSecret: secret, requestedAt: now))
        next.offers = offers
        try enqueueOnion(to: path, through: request.via, content: .init(type: 64, value: invoiceRequest.bytes),
            reply: replyPath(purpose: 9, id: request.id, through: Array(request.via.reversed())), key: Data([8]) + request.id,
            expiresAt: AsyncPaymentRoute.add(now, 300), in: &next)
        try persist(next)
    }
    private func ordinaryRequestPath(_ offer: LightningOffer) throws -> BlindedPath {
        guard let original = offer.paths.first else {
            guard let node = offer.signingKey else { throw LightningError.invalidMessage }
            return try OnionMessage.directPath(node: node)
        }
        guard case .channel(let direction, let scid) = original.introduction else { return original }
        guard let channel = publicRoutingGraph?.channels[scid] else { throw LightningInvoiceError.noRoute }
        return try BlindedPath(introduction: .node(channel.nodes[Int(direction)]), blinding: original.blinding, hops: original.hops)
    }
    func acceptOrdinaryInvoice(_ content: LightningWire.TLV, id: Data, now: UInt64) throws {
        guard content.type == 66, let index = state.offers?.outgoing.firstIndex(where: { $0.request.id == id }) else { throw LightningError.invalidMessage }
        let outgoing = state.offers!.outgoing[index]
        if let saved = outgoing.invoice { guard saved == content.value else { throw LightningError.invalidMessage }; return }
        guard now >= outgoing.requestedAt, now - outgoing.requestedAt <= 300 else { throw LightningError.invalidMessage }
        let invoice = try Bolt12Invoice(bytes: content.value), request = try InvoiceRequest(bytes: outgoing.invoiceRequest)
        try invoice.validate(for: request, expectedIssuer: outgoing.expectedIssuer, chain: state.chain, now: now)
        var next = state
        next.offers!.outgoing[index].invoice = content.value
        next.async.outbox.removeAll { $0.key == Data([8]) + id }
        try persist(next)
    }
    public func cancelOrdinaryInvoiceRequest(id: Data) throws {
        try requireUsableChannels(); try healthy()
        guard let index = state.offers?.outgoing.firstIndex(where: { $0.request.id == id }), state.offers!.outgoing[index].payment == nil else { return }
        var next = state; next.offers!.outgoing.remove(at: index)
        next.async.outbox.removeAll { $0.key == Data([8]) + id }; try persist(next)
    }
    public func ordinaryInvoiceQuote(_ request: OrdinaryInvoicePayment, now: UInt64) throws -> Bolt12PaymentRoute.Quote {
        try requireUsableChannels(); try operational(request.route.peer)
        let invoice = try validatedOrdinaryPayment(request, now: now)
        let quote = try request.route.quote(invoice: invoice, feeLimitMsat: request.feeLimitMsat, height: chainHeight, maximumDelta: request.maximumDelta)
        let index = try activeChannelIndex(request.channelID, peer: request.route.peer)
        var channel = state.channels[index]
        guard !channel.awaitingRevocation, channel.remoteNumber < ChannelKeys.maximumCommitmentNumber else { throw LightningError.invalidState }
        channel.updates.append(ChannelUpdate(change: .add(.init(id: channel.nextLocalHTLC, offered: true,
            amountMsat: quote.amountMsat, paymentHash: invoice.paymentHash, expiry: quote.firstExpiry), onion: Data()), fromLocal: true))
        try channel.includeUpdates(localOwner: false, number: channel.remoteNumber + 1)
        return quote
    }
    private func validatedOrdinaryPayment(_ request: OrdinaryInvoicePayment, now: UInt64) throws -> Bolt12Invoice {
        guard let outgoing = state.offers?.outgoing.first(where: { $0.request.id == request.id }),
              outgoing.invoice == request.invoice, request.feeLimitMsat <= 100_000_000 else { throw LightningError.invalidMessage }
        let invoice = try Bolt12Invoice(bytes: request.invoice)
        guard invoice.paymentPaths.indices.contains(request.route.pathIndex) else { throw LightningError.invalidMessage }
        let path = invoice.paymentPaths[request.route.pathIndex]
        if case .channel = path.introduction {
            guard try publicRoutingGraph?.introduction(path) == request.route.introduction else { throw LightningInvoiceError.noRoute }
        }
        try invoice.validate(for: InvoiceRequest(bytes: outgoing.invoiceRequest), expectedIssuer: outgoing.expectedIssuer, chain: state.chain, now: now)
        return invoice
    }
    @discardableResult
    public func payOrdinaryInvoice(_ request: OrdinaryInvoicePayment, now: UInt64) throws -> Payment {
        try requireUsableChannels(); try operational(request.route.peer)
        if let record = state.payments.first(where: { $0.payment.id == request.id }) {
            guard state.offers?.outgoing.first(where: { $0.request.id == request.id })?.payment == request else { throw LightningError.invalidMessage }
            return record.payment
        }
        try Task.checkCancellation()
        let quote = try ordinaryInvoiceQuote(request, now: now), invoice = try validatedOrdinaryPayment(request, now: now)
        guard !state.payments.contains(where: { $0.payment.hash == invoice.paymentHash }), state.payments.count < 4096,
              let outgoing = state.offers?.outgoing.firstIndex(where: { $0.request.id == request.id }) else { throw LightningError.invalidMessage }
        let index = try activeChannelIndex(request.channelID, peer: request.route.peer)
        var next = state, channel = state.channels[index]
        let htlc = try enqueueHTLC(channel: &channel, in: &next, amountMsat: quote.amountMsat, paymentHash: invoice.paymentHash,
            expiry: quote.firstExpiry, onion: request.route.onion(invoice: invoice, quote: quote), blinding: quote.blinding)
        let payment = Payment(id: request.id, hash: invoice.paymentHash, amountMsat: invoice.amountMsat, incoming: false, phase: .inFlight, feeMsat: quote.feeMsat)
        next.payments.append(PaymentRecord(payment: payment, channelID: channel.id, htlcID: htlc, request: nil))
        next.channels[index] = channel; next.offers!.outgoing[outgoing].payment = request
        try Task.checkCancellation()
        try persist(next); return payment
    }
}
