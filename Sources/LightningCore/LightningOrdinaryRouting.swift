import Foundation

extension LightningRoutingGraph {
    func ordinaryRoute(from peer: Data, invoice: Bolt12Invoice, feeLimitMsat: UInt64, maximumDelta: UInt32) throws -> Bolt12PaymentRoute {
        for index in invoice.paymentPaths.indices {
            guard let introduction = try? introduction(invoice.paymentPaths[index]) else { continue }
            let hops = try? search(from: peer, target: introduction) { prefix in
                let route = try Bolt12PaymentRoute(hops: prefix, pathIndex: index, introduction: introduction)
                let quote = try route.quote(invoice: invoice, feeLimitMsat: feeLimitMsat, height: 0, maximumDelta: maximumDelta)
                return (quote.amountMsat, quote.delta)
            }
            if let hops { return try Bolt12PaymentRoute(hops: hops, pathIndex: index, introduction: introduction) }
        }
        throw LightningInvoiceError.noRoute
    }
    func introduction(_ path: BlindedPath) throws -> Data {
        switch path.introduction {
        case .node(let node): return node
        case .channel(let direction, let scid):
            guard let channel = channels[scid] else { throw LightningInvoiceError.noRoute }
            return channel.nodes[Int(direction)]
        }
    }
    func offerPath(from peer: Data, offer: LightningOffer) throws -> [Data] {
        guard let target = try offer.paths.first.map(introduction) ?? offer.signingKey else { throw LightningInvoiceError.noRoute }
        let hops = try search(from: peer, target: target, enforcePaymentBounds: false) { (UInt64($0.count + 1), 0) }
        return hops.isEmpty ? [peer] : hops.map(\.peer)
    }
}
extension LightningPeerSession {
    public func ordinaryInvoiceRoute(invoice: Bolt12Invoice, feeLimitMsat: UInt64,
                                     maximumDelta: UInt32 = 2016) async throws -> Bolt12PaymentRoute {
        guard status == .connected, invoice.chain == (await engine.chainHash()) else { throw LightningInvoiceError.unavailable }
        let empty = LightningRoutingGraph(chain: invoice.chain)
        if let route = try? empty.ordinaryRoute(from: peer, invoice: invoice, feeLimitMsat: feeLimitMsat, maximumDelta: maximumDelta) { return route }
        if let cached = await engine.cachedRouting(), fresh(cached),
           let route = try? cached.ordinaryRoute(from: peer, invoice: invoice, feeLimitMsat: feeLimitMsat, maximumDelta: maximumDelta) { return route }
        return try await queryRouting().ordinaryRoute(from: peer, invoice: invoice, feeLimitMsat: feeLimitMsat, maximumDelta: maximumDelta)
    }
    public func ordinaryOfferPath(offer: LightningOffer) async throws -> [Data] {
        guard status == .connected else { throw LightningInvoiceError.unavailable }
        let empty = LightningRoutingGraph(chain: await engine.chainHash())
        if let route = try? empty.offerPath(from: peer, offer: offer) { return route }
        if let cached = await engine.cachedRouting(), fresh(cached), let route = try? cached.offerPath(from: peer, offer: offer) { return route }
        return try await queryRouting().offerPath(from: peer, offer: offer)
    }
    private func fresh(_ graph: LightningRoutingGraph) -> Bool {
        let now = UInt64(Date().timeIntervalSince1970)
        return now >= graph.synchronizedAt && now - graph.synchronizedAt < 600
    }
}
