import Foundation
import WalletCore

extension LightningPeerSession {
    /// Discovery is read-only. The caller must separately review and authorize
    /// the exact route; this method never queues a payment or spending signature.
    public func invoiceRoute(invoice: String, network: BitcoinNetwork, amountMsat: UInt64,
                             feeLimitMsat: UInt64, maximumDelta: UInt32 = 2016) async throws -> Bolt11PaymentRoute {
        let value = try Bolt11Invoice.decode(invoice, network: network), now = UInt64(Date().timeIntervalSince1970)
        try value.validatePayment(amountMsat: amountMsat, now: now)
        guard status == .connected, await engine.chainHash() == NetworkParams.params(for: network).genesisHash else { throw LightningInvoiceError.unavailable }
        let empty = LightningRoutingGraph(chain: await engine.chainHash())
        if let direct = try? empty.route(from: peer, invoice: value, amountMsat: amountMsat, feeLimitMsat: feeLimitMsat, maximumDelta: maximumDelta) { return direct }
        if let cached = await engine.cachedRouting(), now >= cached.synchronizedAt, now - cached.synchronizedAt < 600,
           let route = try? cached.route(from: peer, invoice: value, amountMsat: amountMsat, feeLimitMsat: feeLimitMsat, maximumDelta: maximumDelta) { return route }
        let graph = try await queryRouting()
        return try graph.route(from: peer, invoice: value, amountMsat: amountMsat, feeLimitMsat: feeLimitMsat, maximumDelta: maximumDelta)
    }
    func queryRouting() async throws -> LightningRoutingGraph {
        let now = UInt64(Date().timeIntervalSince1970)
        guard peerFeatures?.supports(6) == true, gossipQuery == nil, gossipCompletion == nil else { throw LightningInvoiceError.unavailable }
        let height = try await engine.verifiedHeight()
        let chain = await engine.chainHash()
        guard status == .connected, gossipQuery == nil, gossipCompletion == nil else { throw LightningInvoiceError.unavailable }
        let graph = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LightningRoutingGraph, any Error>) in
                gossipCompletion = continuation
                do {
                    gossipQuery = try LightningGossipQuery(chain: chain, height: height, now: now)
                    Task { await self.startGossip() }
                } catch { failRouting(error) }
            }
        } onCancel: { Task { await self.cancelRouting() } }
        try Task.checkCancellation()
        return graph
    }
    private func startGossip() async {
        do {
            guard let query = gossipQuery else { return }
            try await sendLiquidity(query.range())
        } catch { failRouting(error) }
    }
    func handleGossip(_ message: LightningWire.Message) async throws {
        if [261, 263].contains(message.type) { try await sendLiquidity(LightningGossipQuery.emptyResponse(message)); return }
        guard var query = gossipQuery else { return }
        let now = UInt64(Date().timeIntervalSince1970)
        switch message.type {
        case 264:
            guard try query.receiveRange(message, now: now) else { gossipQuery = query; return }
        case 262:
            var r = LightningWire.Reader(message.payload)
            guard !query.awaitingRange, try r.take(32) == query.graph.chain, try r.u8() <= 1 else { throw LightningError.invalidMessage }
            try r.requireEnd(); query.lastProgress = now
        case 256, 257, 258:
            // Unsupported or malformed routing hints are skipped, never applied
            // to wallet funds or allowed to terminate an otherwise valid channel.
            try? query.graph.receive(message, now: now); query.lastProgress = now; gossipQuery = query; return
        default: return
        }
        if let next = try query.next() { gossipQuery = query; try await sendLiquidity(next) }
        else {
            query.graph.synchronizedAt = now; gossipQuery = nil
            await engine.cacheRouting(query.graph)
            let completed = gossipCompletion; gossipCompletion = nil; completed?.resume(returning: query.graph)
        }
    }
    func checkRoutingTimeout(now: UInt64) async {
        if let query = gossipQuery, now >= query.lastProgress, (now - query.lastProgress > 90 || now - query.startedAt > 600) {
            failRouting(LightningInvoiceError.unavailable)
            // A timed-out query cannot be overlapped with a new one on this
            // transport. Reconnection retains every durable funded record.
            await stop()
        }
    }
    private func cancelRouting() { gossipCompletion?.resume(throwing: CancellationError()); gossipCompletion = nil }
    func failRouting(_ error: any Error) {
        gossipCompletion?.resume(throwing: error); gossipCompletion = nil; gossipQuery = nil
    }
}
