import Foundation
import P256K

extension LightningEngine {
    public func registerOrdinaryOffer(_ configuration: OrdinaryOfferConfiguration, now: UInt64) throws -> LightningOffer {
        try requireUsableChannels(); try operational(configuration.peer)
        if let previous = state.offers?.receives.first(where: { $0.configuration.id == configuration.id }) {
            guard previous.configuration == configuration else { throw LightningError.invalidMessage }
            return try LightningOffer(bytes: previous.offer)
        }
        guard configuration.id.count == 32, !configuration.description.isEmpty, configuration.description.utf8.count <= 256,
              configuration.expiresAt > now, configuration.expiresAt - now <= 31_536_000,
              (state.offers?.receives.count ?? 0) < 128, !(try invoiceCapacities(peer: configuration.peer)).isEmpty else { throw LightningError.invalidMessage }
        var fields: [LightningWire.TLV] = [.init(type: 2, value: state.chain), .init(type: 4, value: configuration.id),
            .init(type: 10, value: Data(configuration.description.utf8)),
            .init(type: 14, value: Bolt12Encoding.integer(configuration.expiresAt)), .init(type: 22, value: try nodeID())]
        if let amount = configuration.minimumMsat { fields.append(.init(type: 8, value: Bolt12Encoding.integer(amount))) }
        if configuration.blinded {
            fields.append(try .init(type: 16, value: replyPath(purpose: 8, id: configuration.id, through: [configuration.peer]).encoded()))
        }
        let offer = try LightningOffer(bytes: Bolt12Encoding.serialize(fields.sorted { $0.type < $1.type }))
        var next = state, offers = next.offers ?? OrdinaryOfferState()
        offers.receives.append(OrdinaryReceiveOffer(configuration: configuration, offer: offer.bytes)); next.offers = offers
        try persist(next); return offer
    }
    public func ordinaryReceiveOffers(now: UInt64) throws -> [LightningOffer] {
        try requireUsableChannels(); try healthy()
        return try (state.offers?.receives ?? []).filter { $0.configuration.expiresAt > now }.map { try LightningOffer(bytes: $0.offer) }
    }
    func receiveOrdinaryRequest(_ content: LightningWire.TLV, reply: BlindedPath?, offerID: Data?, now: UInt64) throws {
        guard content.type == 64, let reply else { throw LightningError.invalidMessage }
        let request = try InvoiceRequest(bytes: content.value)
        guard let receive = state.offers?.receives.first(where: { $0.offer == request.offer.bytes }),
              receive.configuration.blinded == (offerID != nil), offerID == nil || offerID == receive.configuration.id else { throw LightningError.invalidMessage }
        try request.offer.validatePayment(chain: state.chain, now: now, amountMsat: request.amountMsat)
        guard request.chain == state.chain else { throw LightningError.invalidMessage }
        let fingerprint = try Bolt12Encoding.serialize(Bolt12Encoding.records(request.bytes).filter(Bolt12Invoice.requestField))
        let saved = state.offers?.issued.first(where: { $0.request == fingerprint && $0.expiresAt >= now })
        let capacities = saved == nil ? try invoiceCapacities(peer: receive.configuration.peer) : []
        var next = state
        let invoice = try saved.map { try Bolt12Invoice(bytes: $0.invoice) } ?? issueOrdinaryInvoice(request, fingerprint: fingerprint, capacities: capacities, now: now, in: &next)
        try enqueueOnion(to: reply, through: [receive.configuration.peer], content: .init(type: 66, value: invoice.bytes),
            reply: nil, key: Data([9]) + ChannelKeys.hash(fingerprint), expiresAt: AsyncPaymentRoute.add(now, 300), in: &next)
        try persist(next)
    }
    private func issueOrdinaryInvoice(_ request: InvoiceRequest, fingerprint: Data, capacities: [InvoiceCapacity], now: UInt64, in next: inout State) throws -> Bolt12Invoice {
        guard let capacity = capacities.first(where: { $0.minimumMsat <= request.amountMsat && $0.maximumMsat >= request.amountMsat }),
              next.incoming.count < 4096, (next.offers?.issued.count ?? 0) < 4096, UInt64(chainHeight) + 2016 < 500_000_000,
              UInt32(capacity.route.expiryDelta) + 18 <= UInt16.max else { throw LightningError.invalidAmount }
        let expiresAt = min(try AsyncPaymentRoute.add(now, 3600), request.offer.expiry ?? .max)
        guard expiresAt > now else { throw LightningError.invalidAmount }
        let preimage = try P256K.Signing.PrivateKey().dataRepresentation, token = try P256K.Signing.PrivateKey().dataRepresentation
        let hash = ChannelKeys.hash(preimage)
        let path = try OrdinaryBlindedPayment.path(provider: capacity.route.peer, recipient: nodeID(), route: capacity.route,
            token: token, maximumExpiry: chainHeight + 2016, minimumMsat: request.amountMsat)
        let info = try StaticInvoice.PayInfo(baseMsat: capacity.route.baseMsat, proportionalMillionths: capacity.route.proportionalMillionths,
            expiryDelta: capacity.route.expiryDelta + 18, minimumMsat: capacity.minimumMsat,
            maximumMsat: capacity.maximumMsat, features: LightningFeatures(bytes: Data()))
        let invoice = try Bolt12Invoice(request: request, paths: [path], payInfo: [info], paymentHash: hash,
            createdAt: now, relativeExpiry: UInt32(expiresAt - now), signingSecret: next.nodeSecret)
        next.incoming.append(ReceiveRequest(id: hash, preimage: preimage, secret: token, amountMsat: request.amountMsat,
            expiry: chainHeight + 2016, expiresAt: expiresAt))
        next.offers!.issued.append(OrdinaryIssuedInvoice(request: fingerprint, invoice: invoice.bytes, expiresAt: expiresAt))
        return invoice
    }
    func validOrdinaryReceive(_ htlc: ChannelTransactions.HTLC, peeled: OnionPacket.Peeled, blinding: Data, state: State) -> ReceiveRequest? {
        guard let request = state.incoming.first(where: { ChannelKeys.hash($0.preimage) == htlc.paymentHash }),
              state.offers?.issued.contains(where: { (try? Bolt12Invoice(bytes: $0.invoice).paymentHash) == htlc.paymentHash }) == true,
              !state.payments.contains(where: { $0.payment.hash == htlc.paymentHash }),
              request.expiresAt.map({ $0 >= UInt64(Date().timeIntervalSince1970) }) ?? false else { return nil }
        do {
            try OrdinaryBlindedPayment.receive(peeled: peeled, blinding: blinding, nodeSecret: state.nodeSecret, request: request, htlc: htlc, height: chainHeight)
            return request
        } catch { return nil }
    }
}
