import Foundation

extension LightningEngine {
    public struct OfferPayment: Codable, Sendable, Equatable {
        public let id: Data, channelID: Data, offer: Data
        public let amountMsat: UInt64, feeLimitMsat: UInt64
        public let maximumDelta: UInt32
        public let route: AsyncPaymentRoute
        public init(id: Data, channelID: Data, offer: LightningOffer, amountMsat: UInt64,
                    feeLimitMsat: UInt64, maximumDelta: UInt32 = 2016, route: AsyncPaymentRoute) {
            self.id = id; self.channelID = channelID; self.offer = offer.bytes; self.amountMsat = amountMsat
            self.feeLimitMsat = feeLimitMsat; self.maximumDelta = maximumDelta; self.route = route
        }
    }
    struct AsyncOutgoing: Codable {
        let request: OfferPayment
        let invoiceRequest: Data, preimage: Data
        let requestedAt: UInt64
        var invoice: Data?
        var releasePath: BlindedPath?
        var notified = false
    }
    struct AsyncState: Codable {
        var outgoing: [AsyncOutgoing] = []
        var receives: [AsyncReceive] = []
        var outbox: [OnionOutbound] = []
    }
    public struct OnionOutbound: Codable, Sendable, Equatable {
        public let sequence: UInt64
        public let peer: Data, message: LightningWire.Message
        let key: Data
        let expiresAt: UInt64
        var publishedAt: UInt64?
    }
    var asyncAuthKey: Data { OnionPacket.derive("winnow_async_context_v1", secret: state.nodeSecret) }
    func replyPath(purpose: UInt8, id: Data, through peers: [Data]) throws -> BlindedPath {
        try OnionMessage.path(nodes: peers + [nodeID()], context: Data([purpose]) + id, authenticationKey: asyncAuthKey)
    }
    /// Requests and held notifications remain durable until an authenticated
    /// response, settlement or expiry. TCP acceptance is not delivery: retry
    /// those exact bytes at a bounded interval without creating another HTLC.
    public func pendingOnionMessages(peer: Data, now: UInt64) throws -> [OnionOutbound] {
        try operational(peer)
        return state.async.outbox.filter {
            guard $0.peer == peer, $0.expiresAt >= now else { return false }
            guard let published = $0.publishedAt else { return true }
            return now >= published && now - published >= 10
        }
    }
    public func onionMessagePublished(sequence: UInt64, now: UInt64 = UInt64(Date().timeIntervalSince1970)) throws {
        try healthy()
        guard let index = state.async.outbox.firstIndex(where: { $0.sequence == sequence }) else { return }
        var next = state
        if [1, 2, 5, 8].contains(next.async.outbox[index].key.first) {
            next.async.outbox[index].publishedAt = now
        } else { next.async.outbox.remove(at: index) }
        try persist(next)
    }
    func enqueueOnion(to originalPath: BlindedPath, through: [Data], content: LightningWire.TLV,
                      reply: BlindedPath?, key: Data, expiresAt: UInt64, in next: inout State) throws {
        guard next.async.outbox.count < 1024, next.nextSequence < .max else { throw LightningError.invalidState }
        let path: BlindedPath
        if case .channel(_, let scid) = originalPath.introduction {
            guard let route = next.async.outgoing.first(where: { $0.request.route.shortChannelID == scid })?.request.route else { throw LightningError.invalidMessage }
            path = try route.resolve(originalPath)
        } else { path = originalPath }
        let first: Data
        if let peer = through.first { first = peer }
        else if case .node(let node) = path.introduction { first = node }
        else { throw LightningError.invalidMessage }
        let prefix: [Data]
        if case .node(let intro) = path.introduction, through.last == intro { prefix = Array(through.dropLast()) }
        else { prefix = through }
        let message = try OnionMessage.create(to: path, via: prefix, content: content, reply: reply)
        next.async.outbox.removeAll { $0.key == key }
        next.async.outbox.append(OnionOutbound(sequence: next.nextSequence, peer: first, message: message, key: key, expiresAt: expiresAt))
        next.nextSequence += 1
    }
    public func receiveOnionMessage(_ message: LightningWire.Message, now: UInt64) throws -> [Event] {
        try requireUsableChannels()
        guard chainIsCurrent else { throw LightningError.invalidState }
        guard message.type == 513 else { throw LightningError.invalidMessage }
        do { return try dispatchOnion(message, now: now) }
        catch {
            // BOLT4 onion messages are best effort and independent of channel
            // state. Invalid, obsolete or unsolicited payloads must not stop
            // commitment/revocation processing. An uncertain write still stops
            // the entire engine and must propagate to the transport owner.
            try healthy()
            return []
        }
    }
    private func dispatchOnion(_ message: LightningWire.Message, now: UInt64) throws -> [Event] {
        let peeled = try OnionMessage.peel(message, nodeSecret: state.nodeSecret, authenticationKey: asyncAuthKey)
        if case .invoiceRequest(let content, let reply) = peeled {
            try receiveOrdinaryRequest(content, reply: reply, offerID: nil, now: now); return []
        }
        guard case .receive(let content, let context, let reply) = peeled, context.count == 33 else { throw LightningError.invalidMessage }
        let id = Data(context.dropFirst())
        switch context.first {
        case 1: return try acceptStaticInvoice(content, id: id, now: now)
        case 2: try receiveOfferRegistration(content, reply: reply, id: id, now: now)
        case 3: try releaseHeldPayment(content, reply: reply, id: id, now: now)
        case 4: try replyToInvoiceRequest(content, reply: reply, id: id, now: now)
        case 8: try receiveOrdinaryRequest(content, reply: reply, offerID: id, now: now)
        case 9: try acceptOrdinaryInvoice(content, id: id, now: now)
        default: throw LightningError.invalidMessage
        }
        return []
    }
}
