import Foundation

extension LightningPeerSession {
    public func liquidityInfo() async throws -> LightningLiquidity.Info {
        try LightningLiquidity.decode(LightningLiquidity.Info.self, from: await liquidityRPC("lsps1.get_info", params: Data("{}".utf8)))
    }
    public func liquidityOrder(_ request: LightningLiquidity.Purchase) async throws -> LightningLiquidity.Order {
        let params = try LightningLiquidity.encoder().encode(request)
        return try LightningLiquidity.decode(LightningLiquidity.Order.self, from: await liquidityRPC("lsps1.create_order", params: params))
    }
    public func liquidityOrderStatus(id: String) async throws -> LightningLiquidity.Order {
        let params = try JSONEncoder().encode(["order_id": id])
        return try LightningLiquidity.decode(LightningLiquidity.Order.self, from: await liquidityRPC("lsps1.get_order", params: params))
    }
    private func liquidityRPC(_ method: String, params: Data) async throws -> Data {
        // Some LND providers serve LSPS custom messages without extending init
        // features. A bounded request is the capability check for those peers.
        guard status == .connected else { throw LightningLiquidityError.unavailable }
        guard liquidityRequests.count < 8 else { throw LightningError.invalidState }
        let id = UUID().uuidString, message = try LightningLiquidity.message(method: method, params: params, id: id)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                liquidityRequests[id] = continuation
                Task { await publishLiquidity(message, id: id) }
            }
        } onCancel: { Task { await self.cancelLiquidity(id: id, error: CancellationError()) } }
    }
    private func publishLiquidity(_ message: LightningWire.Message, id: String) async {
        do {
            try Task.checkCancellation()
            guard liquidityRequests[id] != nil else { return }
            try await sendLiquidity(message)
            try await Task.sleep(for: .seconds(20))
            cancelLiquidity(id: id, error: LightningLiquidityError.timedOut)
        } catch { cancelLiquidity(id: id, error: error) }
    }
    private func cancelLiquidity(id: String, error: any Error) {
        liquidityRequests.removeValue(forKey: id)?.resume(throwing: error)
    }
    func cancelLiquidityRequests() {
        let requests = liquidityRequests.values; liquidityRequests.removeAll(); peerFeatures = nil
        for request in requests { request.resume(throwing: LightningLiquidityError.unavailable) }
    }
}
