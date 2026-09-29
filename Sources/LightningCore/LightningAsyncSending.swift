import Foundation
import P256K

extension LightningEngine {
    @discardableResult
    public func payOffer(_ request: OfferPayment, now: UInt64) throws -> Payment {
        try operational(request.route.holdingPeer)
        if let previous = state.async.outgoing.first(where: { $0.request.id == request.id }) {
            guard previous.request == request, let payment = state.payments.first(where: { $0.payment.id == request.id }) else { throw LightningError.invalidMessage }
            return payment.payment
        }
        guard request.id.count == 32, !state.payments.contains(where: { $0.payment.id == request.id }),
              state.payments.count < 4096, state.async.outgoing.count < 4096,
              peers[request.route.holdingPeer]?.supports(152) == true,
              (36...2016).contains(request.maximumDelta) else { throw LightningError.invalidMessage }
        _ = try activeChannelIndex(request.channelID, peer: request.route.holdingPeer)
        let offer = try LightningOffer(bytes: request.offer)
        try offer.validatePayment(chain: state.chain, now: now, amountMsat: request.amountMsat)
        guard let path = offer.paths.first else { throw LightningError.invalidMessage }
        let payer = try P256K.Signing.PrivateKey().dataRepresentation, preimage = try P256K.Signing.PrivateKey().dataRepresentation
        let invoiceRequest = try InvoiceRequest(offer: offer, chain: state.chain, amountMsat: request.amountMsat, now: now,
                                                metadata: request.id, payerSecret: payer)
        let outgoing = AsyncOutgoing(request: request, invoiceRequest: invoiceRequest.bytes, preimage: preimage, requestedAt: now)
        let payment = Payment(id: request.id, hash: ChannelKeys.hash(preimage), amountMsat: request.amountMsat, incoming: false, phase: .preparing)
        var next = state
        next.async.outgoing.append(outgoing)
        next.payments.append(PaymentRecord(payment: payment, channelID: request.channelID, htlcID: nil, request: nil))
        try enqueueOnion(to: path, through: [request.route.holdingPeer], content: .init(type: 64, value: invoiceRequest.bytes),
                         reply: replyPath(purpose: 1, id: request.id, through: [request.route.holdingPeer]),
                         key: Data([1]) + request.id, expiresAt: AsyncPaymentRoute.add(now, 300), in: &next)
        try persist(next)
        return payment
    }
    func acceptStaticInvoice(_ content: LightningWire.TLV, id: Data, now: UInt64) throws -> [Event] {
        guard content.type == 70, let outgoingIndex = state.async.outgoing.firstIndex(where: { $0.request.id == id }),
              let paymentIndex = state.payments.firstIndex(where: { $0.payment.id == id }) else { throw LightningError.invalidMessage }
        let outgoing = state.async.outgoing[outgoingIndex], request = outgoing.request
        // A repeated or competing invoice can never enqueue another HTLC.
        guard state.payments[paymentIndex].payment.phase == .preparing else { return [] }
        guard now >= outgoing.requestedAt, now - outgoing.requestedAt <= 300 else { throw LightningError.invalidMessage }
        let invoice = try StaticInvoice(bytes: content.value), offer = try LightningOffer(bytes: request.offer)
        try invoice.validatePayment(for: offer, chain: state.chain, now: now, amountMsat: request.amountMsat)
        try operational(request.route.holdingPeer)
        let channelIndex = try activeChannelIndex(request.channelID, peer: request.route.holdingPeer)
        let quote = try request.route.quote(invoice: invoice, amountMsat: request.amountMsat, feeLimitMsat: request.feeLimitMsat,
                                            height: chainHeight, maximumDelta: request.maximumDelta)
        let onion = try request.route.onion(invoice: invoice, request: InvoiceRequest(bytes: outgoing.invoiceRequest), preimage: outgoing.preimage, quote: quote)
        var next = state, channel = state.channels[channelIndex]
        let htlcID = try enqueueHTLC(channel: &channel, in: &next, amountMsat: quote.amountMsat, paymentHash: ChannelKeys.hash(outgoing.preimage),
                                     expiry: quote.firstExpiry, onion: onion, hold: true)
        next.channels[channelIndex] = channel
        next.payments[paymentIndex].htlcID = htlcID
        next.payments[paymentIndex].payment.phase = .inFlight
        next.payments[paymentIndex].payment.feeMsat = quote.feeMsat
        next.async.outgoing[outgoingIndex].invoice = invoice.bytes
        next.async.outbox.removeAll { $0.key == Data([1]) + id }
        try persist(next)
        return [.paymentChanged(next.payments[paymentIndex].payment)]
    }
    func recordReleasePaths(_ paths: [HTLCReleasePath], channel: ChannelState, in next: inout State) throws {
        for item in paths {
            guard let payment = next.payments.first(where: { !$0.payment.incoming && $0.channelID == channel.id && $0.htlcID == item.id }),
                  let index = next.async.outgoing.firstIndex(where: { $0.request.id == payment.payment.id }) else { throw LightningError.invalidMessage }
            if let existing = next.async.outgoing[index].releasePath {
                guard existing == item.path else { throw LightningError.invalidMessage }
            } else { next.async.outgoing[index].releasePath = item.path }
        }
    }
    func reconcileHeldPayments(in next: inout State) throws -> [Event] {
        var events: [Event] = []
        for index in next.async.outgoing.indices {
            let outgoing = next.async.outgoing[index]
            guard !outgoing.notified, let path = outgoing.releasePath, let raw = outgoing.invoice,
                  let paymentIndex = next.payments.firstIndex(where: { $0.payment.id == outgoing.request.id }),
                  next.payments[paymentIndex].payment.phase == .inFlight else { continue }
            let payment = next.payments[paymentIndex]
            guard let channel = next.channels.first(where: { $0.id == payment.channelID }),
                  channel.updates.contains(where: { update in
                      guard update.irrevocable, case .add(let htlc, _) = update.change else { return false }
                      return htlc.offered && htlc.id == payment.htlcID
                  }) else { continue }
            let invoice = try StaticInvoice(bytes: raw)
            guard let notification = invoice.notificationPaths.first else { throw LightningError.invalidMessage }
            try enqueueOnion(to: notification, through: [outgoing.request.route.holdingPeer], content: AsyncPaymentMessage.held.record(),
                             reply: path, key: Data([5]) + outgoing.request.id,
                             expiresAt: AsyncPaymentRoute.add(invoice.createdAt, UInt64(invoice.relativeExpiry)), in: &next)
            next.async.outgoing[index].notified = true
            next.payments[paymentIndex].payment.phase = .awaitingRecipient
            events.append(.paymentChanged(next.payments[paymentIndex].payment))
        }
        return events
    }
    public func expireInvoiceRequests(now: UInt64) throws -> [Event] {
        try healthy()
        var next = state, events: [Event] = []
        for outgoing in next.async.outgoing where now > outgoing.requestedAt && now - outgoing.requestedAt > 300 {
            guard let index = next.payments.firstIndex(where: { $0.payment.id == outgoing.request.id }),
                  next.payments[index].payment.phase == .preparing else { continue }
            next.payments[index].payment.phase = .failed
            next.async.outbox.removeAll { $0.key == Data([1]) + outgoing.request.id }
            events.append(.paymentChanged(next.payments[index].payment))
        }
        next.async.outbox.removeAll { $0.expiresAt < now }
        if !events.isEmpty || next.async.outbox.count != state.async.outbox.count { try persist(next) }
        return events
    }
}
