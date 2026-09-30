import Foundation
import P256K

extension LightningEngine {
    public struct ReceiveOfferConfiguration: Codable, Sendable, Equatable {
        public let id: Data, provider: Data, serverPath: BlindedPath
        public let inboundShortChannelID: UInt64
        public let baseMsat: UInt32, proportionalMillionths: UInt32, expiryDelta: UInt16
        public let maximumMsat: UInt64
        public init(id: Data, provider: Data, serverPath: BlindedPath, inboundShortChannelID: UInt64,
                    baseMsat: UInt32, proportionalMillionths: UInt32, expiryDelta: UInt16, maximumMsat: UInt64) {
            self.id = id; self.provider = provider; self.serverPath = serverPath; self.inboundShortChannelID = inboundShortChannelID
            self.baseMsat = baseMsat; self.proportionalMillionths = proportionalMillionths; self.expiryDelta = expiryDelta; self.maximumMsat = maximumMsat
        }
    }
    struct AsyncReceive: Codable {
        let configuration: ReceiveOfferConfiguration
        let signingSecret: Data, createdAt: UInt64
        var invoice: Data?
        var forwardRequest: BlindedPath?
        var ready = false
    }
    public struct ReceiveOffer: Sendable {
        public let id: Data, offer: LightningOffer
        public let expiresAt: UInt64
    }
    /// Returns only offers acknowledged as persisted by the independent server.
    /// Sharing an offer before that acknowledgement would strand offline payers.
    public func receiveOffers(now: UInt64) throws -> [ReceiveOffer] {
        try state.async.receives.compactMap { receive in
            guard receive.ready, let raw = receive.invoice else { return nil }
            let invoice = try StaticInvoice(bytes: raw), expiry = try AsyncPaymentRoute.add(invoice.createdAt, UInt64(invoice.relativeExpiry))
            guard now <= expiry else { return nil }
            return ReceiveOffer(id: receive.configuration.id, offer: invoice.offer, expiresAt: expiry)
        }
    }
    public func registerReceiveOffer(_ configuration: ReceiveOfferConfiguration, now: UInt64) throws {
        try operational(configuration.provider)
        if let previous = state.async.receives.first(where: { $0.configuration.id == configuration.id }) {
            guard previous.configuration == configuration else { throw LightningError.invalidMessage }; return
        }
        guard configuration.id.count == 32, configuration.maximumMsat > 0, configuration.maximumMsat <= 16_777_215_000,
              state.async.receives.count < 128, configuration.expiryDelta >= 18,
              case .node(let introduction) = configuration.serverPath.introduction, introduction == configuration.provider,
              state.channels.contains(where: { $0.peer == configuration.provider && $0.phase == .ready && $0.fundingIsConfirmed })
        else { throw LightningError.invalidMessage }
        let receive = try AsyncReceive(configuration: configuration, signingSecret: P256K.Signing.PrivateKey().dataRepresentation, createdAt: now)
        var next = state; next.async.receives.append(receive)
        try enqueueOnion(to: configuration.serverPath, through: [], content: AsyncPaymentMessage.offerPathsRequest(slot: UInt16(next.async.receives.count - 1)).record(),
                         reply: replyPath(purpose: 2, id: configuration.id, through: [configuration.provider]),
                         key: Data([2]) + configuration.id, expiresAt: AsyncPaymentRoute.add(now, 300), in: &next)
        try persist(next)
    }
    func receiveOfferRegistration(_ content: LightningWire.TLV, reply: BlindedPath?, id: Data, now: UInt64) throws {
        guard let index = state.async.receives.firstIndex(where: { $0.configuration.id == id }) else { throw LightningError.invalidMessage }
        switch try AsyncPaymentMessage(record: content) {
        case .offerPaths(let paths, let expiry):
            guard let reply, expiry == nil || expiry! > now else { throw LightningError.invalidMessage }
            try serveReceiveOffer(index: index, paths: paths, reply: reply, pathExpiry: expiry, now: now)
        case .persisted:
            guard state.async.receives[index].invoice != nil else { throw LightningError.invalidState }
            if state.async.receives[index].ready { return }
            var next = state; next.async.receives[index].ready = true
            next.async.outbox.removeAll { $0.key == Data([2]) + id }; try persist(next)
        default: throw LightningError.invalidMessage
        }
    }
    private func serveReceiveOffer(index: Int, paths: [BlindedPath], reply: BlindedPath, pathExpiry: UInt64?, now: UInt64) throws {
        var next = state, receive = next.async.receives[index]
        if receive.invoice == nil {
            let built = try buildReceiveInvoice(receive, paths: paths, pathExpiry: pathExpiry, now: now)
            receive.invoice = built.bytes
            receive.forwardRequest = try replyPath(purpose: 4, id: receive.configuration.id, through: [receive.configuration.provider])
            next.async.receives[index] = receive
        }
        guard let raw = receive.invoice, let forward = receive.forwardRequest else { throw LightningError.invalidState }
        try enqueueOnion(to: reply, through: [], content: AsyncPaymentMessage.serve(StaticInvoice(bytes: raw), forwardRequest: forward).record(),
                         reply: replyPath(purpose: 2, id: receive.configuration.id, through: [receive.configuration.provider]),
                         key: Data([2]) + receive.configuration.id, expiresAt: AsyncPaymentRoute.add(now, 300), in: &next)
        try persist(next)
    }
    private func buildReceiveInvoice(_ receive: AsyncReceive, paths: [BlindedPath], pathExpiry: UInt64?, now: UInt64) throws -> StaticInvoice {
        let config = receive.configuration
        let expires = min(try AsyncPaymentRoute.add(now, 86_400), pathExpiry ?? UInt64.max)
        guard UInt64(chainHeight) + 2016 < 500_000_000, expires > now else { throw LightningError.invalidState }
        let offer = try LightningOffer(bytes: Bolt12Encoding.serialize([
            .init(type: 2, value: state.chain), .init(type: 10, value: Data("Winnow receive offer".utf8)),
            .init(type: 14, value: Bolt12Encoding.integer(expires)),
            .init(type: 16, value: paths.map { try $0.encoded() }.reduce(Data(), +)),
            .init(type: 22, value: ChannelKeys.publicKey(secret: receive.signingSecret))]))
        let path = try BlindedPayment.path(provider: config.provider, recipient: nodeID(), shortChannelID: config.inboundShortChannelID,
            offerID: config.id, maximumExpiry: chainHeight + 2016, minimumMsat: 1, baseMsat: config.baseMsat,
            proportionalMillionths: config.proportionalMillionths, delta: config.expiryDelta, authenticationKey: asyncAuthKey)
        guard UInt32(config.expiryDelta) + 18 <= UInt16.max else { throw LightningError.invalidMessage }
        let info = try StaticInvoice.PayInfo(baseMsat: config.baseMsat, proportionalMillionths: config.proportionalMillionths,
            expiryDelta: config.expiryDelta + 18, minimumMsat: 1, maximumMsat: config.maximumMsat, features: LightningFeatures(bytes: Data()))
        return try StaticInvoice(offer: offer, paymentPaths: [path], payInfo: [info],
            notificationPaths: [replyPath(purpose: 3, id: config.id, through: [config.provider])], createdAt: now,
            relativeExpiry: UInt32(expires - now), signingSecret: receive.signingSecret)
    }
    func releaseHeldPayment(_ content: LightningWire.TLV, reply: BlindedPath?, id: Data, now: UInt64) throws {
        guard case .held = try AsyncPaymentMessage(record: content), let reply,
              let receive = state.async.receives.first(where: { $0.configuration.id == id }), receive.ready,
              let raw = receive.invoice else { throw LightningError.invalidMessage }
        let invoice = try StaticInvoice(bytes: raw)
        guard now >= invoice.createdAt, now - invoice.createdAt <= invoice.relativeExpiry else { throw LightningError.invalidMessage }
        let key = try Data([6]) + ChannelKeys.hash(reply.encoded())
        if state.async.outbox.contains(where: { $0.key == key }) { return }
        var next = state
        try enqueueOnion(to: reply, through: [receive.configuration.provider], content: AsyncPaymentMessage.release.record(),
                         reply: nil, key: key, expiresAt: AsyncPaymentRoute.add(now, 300), in: &next)
        try persist(next)
    }
    func replyToInvoiceRequest(_ content: LightningWire.TLV, reply: BlindedPath?, id: Data, now: UInt64) throws {
        guard content.type == 64, let reply, let receive = state.async.receives.first(where: { $0.configuration.id == id }),
              receive.ready, let raw = receive.invoice else { throw LightningError.invalidMessage }
        let request = try InvoiceRequest(bytes: content.value), invoice = try StaticInvoice(bytes: raw)
        try invoice.validatePayment(for: request.offer, chain: state.chain, now: now, amountMsat: request.amountMsat)
        var next = state
        try enqueueOnion(to: reply, through: [receive.configuration.provider], content: .init(type: 70, value: raw), reply: nil,
                         key: Data([7]) + ChannelKeys.hash(content.value), expiresAt: AsyncPaymentRoute.add(now, 300), in: &next)
        try persist(next)
    }
    func validAsyncReceive(_ htlc: ChannelTransactions.HTLC, peeled: OnionPacket.Peeled, blinding: Data, state: State) -> ReceiveRequest? {
        try? validateAsyncReceive(htlc, peeled: peeled, blinding: blinding, state: state)
    }
    private func validateAsyncReceive(_ htlc: ChannelTransactions.HTLC, peeled: OnionPacket.Peeled, blinding: Data, state: State) throws -> ReceiveRequest {
        let received = try BlindedPayment.receive(peeled, blinding: blinding, nodeSecret: state.nodeSecret,
            authenticationKey: asyncAuthKey, htlc: htlc, height: chainHeight)
        guard let saved = state.async.receives.first(where: { $0.configuration.id == received.offerID }), saved.ready,
              let raw = saved.invoice, !state.payments.contains(where: { $0.payment.hash == htlc.paymentHash }) else { throw LightningError.invalidMessage }
        let invoice = try StaticInvoice(bytes: raw)
        try invoice.validatePayment(for: received.request.offer, chain: state.chain,
            now: UInt64(Date().timeIntervalSince1970), amountMsat: received.request.amountMsat)
        guard received.request.chain == state.chain, received.request.amountMsat <= saved.configuration.maximumMsat else { throw LightningError.invalidAmount }
        return ReceiveRequest(id: htlc.paymentHash, preimage: received.preimage, secret: Data(), amountMsat: received.request.amountMsat, expiry: htlc.expiry)
    }
}
