import Foundation
import WalletCore

extension LightningEngine {
    public struct InvoicePayment: Codable, Sendable, Equatable {
        public let id: Data, peer: Data, channelID: Data
        public let invoice: String, network: String
        public let amountMsat: UInt64, feeLimitMsat: UInt64, maximumDelta: UInt32
        public let route: Bolt11PaymentRoute
        public init(id: Data, peer: Data, channelID: Data, invoice: String, network: BitcoinNetwork,
                    amountMsat: UInt64, feeLimitMsat: UInt64, maximumDelta: UInt32, route: Bolt11PaymentRoute) {
            self.id = id; self.peer = peer; self.channelID = channelID; self.invoice = Bolt11Invoice.normalized(invoice); self.network = network.rawValue
            self.amountMsat = amountMsat; self.feeLimitMsat = feeLimitMsat; self.maximumDelta = maximumDelta; self.route = route
        }
    }
    public func invoiceQuote(_ request: InvoicePayment, now: UInt64) throws -> Bolt11PaymentRoute.Quote {
        try operational(request.peer)
        guard let network = BitcoinNetwork(rawValue: request.network), request.id.count == 32, state.chain == NetworkParams.params(for: network).genesisHash,
              request.feeLimitMsat <= 100_000_000, request.maximumDelta <= 2016 else { throw LightningError.invalidMessage }
        let invoice = try Bolt11Invoice.decode(request.invoice, network: network)
        try invoice.validatePayment(amountMsat: request.amountMsat, now: now)
        guard (request.route.hops.first?.peer ?? invoice.payee) == request.peer else { throw LightningError.invalidMessage }
        let index = try activeChannelIndex(request.channelID, peer: request.peer)
        _ = try Bolt11PaymentRoute(hops: request.route.hops)
        let quote = try request.route.quote(invoice: invoice, amountMsat: request.amountMsat, feeLimitMsat: request.feeLimitMsat,
                                       height: chainHeight, maximumDelta: request.maximumDelta)
        var channel = state.channels[index]
        guard !channel.awaitingRevocation, channel.remoteNumber < ChannelKeys.maximumCommitmentNumber else { throw LightningError.invalidState }
        // Validate the prospective balance, reserves and negotiated HTLC limits
        // without creating a signature, outbox entry or journal mutation.
        channel.updates.append(ChannelUpdate(change: .add(.init(id: channel.nextLocalHTLC, offered: true,
            amountMsat: quote.amountMsat, paymentHash: invoice.paymentHash, expiry: quote.firstExpiry), onion: Data()), fromLocal: true))
        try channel.includeUpdates(localOwner: false, number: channel.remoteNumber + 1)
        return quote
    }
    @discardableResult
    public func payInvoice(_ request: InvoicePayment, now: UInt64) throws -> Payment {
        try operational(request.peer)
        if let record = state.payments.first(where: { $0.payment.id == request.id }) {
            guard record.invoiceRequest == request else { throw LightningError.invalidMessage }; return record.payment
        }
        let quote = try invoiceQuote(request, now: now)
        guard let network = BitcoinNetwork(rawValue: request.network) else { throw LightningError.invalidMessage }
        let invoice = try Bolt11Invoice.decode(request.invoice, network: network)
        guard !state.payments.contains(where: { $0.payment.hash == invoice.paymentHash && ($0.payment.phase != .failed || $0.payment.preimage != nil) }), state.payments.count < 4096 else { throw LightningError.invalidMessage }
        let index = try activeChannelIndex(request.channelID, peer: request.peer)
        var channel = state.channels[index], next = state
        let onion = try request.route.onion(invoice: invoice, quote: quote)
        let htlcID = try enqueueHTLC(channel: &channel, in: &next, amountMsat: quote.amountMsat,
                                     paymentHash: invoice.paymentHash, expiry: quote.firstExpiry, onion: onion)
        let payment = Payment(id: request.id, hash: invoice.paymentHash, amountMsat: request.amountMsat,
                              incoming: false, phase: .inFlight, feeMsat: quote.feeMsat)
        next.payments.append(PaymentRecord(payment: payment, channelID: channel.id, htlcID: htlcID, request: nil, invoiceRequest: request))
        next.channels[index] = channel; try persist(next)
        return payment
    }
    public func verifiedHeight() throws -> UInt32 { try healthy(); guard chainIsCurrent else { throw LightningInvoiceError.unavailable }; return chainHeight }
    func cachedRouting() -> LightningRoutingGraph? { publicRoutingGraph }
    func cacheRouting(_ graph: LightningRoutingGraph) { if graph.chain == state.chain { publicRoutingGraph = graph } }
}
