import Foundation
import LightningCore
import WalletCore

extension LightningAppController {
    struct LiquidityQuote: Codable {
        let profile: LightningProfile
        let request: LightningLiquidity.Purchase
        var order: LightningLiquidity.Order
        let feeSat: UInt64
        var accepted = false
        var requestedReceiveSat: UInt64?
        var cancelledAt: UInt64?
        var invoice: String { order.payment.bolt11?.invoice ?? "" }
        func isPayable(network: BitcoinNetwork, now: UInt64) -> Bool {
            accepted && cancelledAt == nil && (try? order.validate(request: request, network: network, now: now)) == feeSat
        }
        func isActive(network: BitcoinNetwork, now: UInt64) -> Bool {
            (try? order.validate(request: request, network: network, now: now)) == feeSat
        }
    }
    var maximumReceivableSat: UInt64 { (invoiceCapacities.map(\.maximumMsat).max() ?? 0) / 1000 }
    var receivingSetupNotice: String? {
        guard let channel = channels.first(where: { $0.phase != .closed }) else { return nil }
        if channel.trustedUnconfirmed {
            return "Your instant channel is confirming. Until it confirms, you trust the provider with what it holds."
        }
        switch channel.phase {
        case .opening, .accepted:
            return "There is an unfinished channel request. It does not provide receiving capacity yet."
        case .awaitingFundingSignature:
            return "Channel funding is waiting for the provider's signature. Keep Winnow open and reconnect to check progress."
        case .awaitingConfirmation:
            return "Waiting for a confirmed channel and its receiving policy. Keep Winnow open and sync to check progress."
        case .ready:
            return "The channel has no usable receiving capacity yet. Sync and reconnect to check its balance and receiving policy."
        case .closing, .recovering:
            return "The existing channel is closing or recovering. Continue chain checks while its funds return."
        case .closed: return nil
        }
    }

    func prepareLiquidity(model: AppModel) async throws {
        try requireNetwork(model)
        guard !liquidityRequestInFlight else { throw LightningError.invalidState }
        liquidityRequestInFlight = true; defer { liquidityRequestInFlight = false }
        let epoch = generation
        await resume(model: model)
        try requireNetwork(model, generation: epoch)
        guard chainCurrent else {
            throw LightningLiquidityError.provider("Bitcoin is still syncing. Wait for the chain check before setting up Lightning receiving.")
        }
        guard let profile, profile.liquidityProvider != nil else { throw LightningLiquidityError.unavailable }
        guard let session = liquiditySession, await session.status == .connected else {
            throw LightningLiquidityError.provider(error ?? "The provider is not connected yet. Reconnect and try again.")
        }
        let info: LightningLiquidity.Info
        if let base = LightningProviders.provider(profile)?.api { info = try await LightningLiquidityHTTP(base: base).info() }
        else { info = try await session.liquidityInfo() }
        try requireNetwork(model, generation: epoch)
        liquidityInfo = info
    }
    func quoteLiquidity(capacitySat: UInt64, model: AppModel) async throws {
        try requireNetwork(model)
        guard !liquidityRequestInFlight, let info = liquidityInfo, let profile,
              let session = liquiditySession, liquidityQuote?.accepted != true else { throw LightningError.invalidState }
        if try hasActiveLiquidityQuote(capacitySat: capacitySat) { return }
        liquidityRequestInFlight = true; defer { liquidityRequestInFlight = false }
        let epoch = generation
        let (request, order) = try await createLiquidityOrder(info: info, capacitySat: capacitySat, session: session, profile: profile)
        try requireNetwork(model, generation: epoch)
        let fee = try order.validate(request: request, network: network, now: Self.now)
        let quote = LiquidityQuote(profile: profile, request: request, order: order, feeSat: fee,
                                   requestedReceiveSat: receiveIntent?.amountSat)
        try storeLiquidityQuote(quote)
        liquidityQuote = quote
    }
    private func hasActiveLiquidityQuote(capacitySat: UInt64) throws -> Bool {
        guard let quote = liquidityQuote, quote.isActive(network: network, now: Self.now) else { return false }
        guard quote.request.lspBalanceSat == String(capacitySat) else {
            throw LightningLiquidityError.provider("An unpaid setup order already exists. Resume it or wait for it to expire before requesting another quote.")
        }
        return true
    }
    private func createLiquidityOrder(info: LightningLiquidity.Info, capacitySat: UInt64, session: LightningPeerSession, profile: LightningProfile) async throws -> (LightningLiquidity.Purchase, LightningLiquidity.Order) {
        guard await session.status == .connected else { throw LightningLiquidityError.unavailable }
        let request = try info.request(capacitySat: capacitySat, token: LightningProviders.provider(profile)?.token ?? "")
        return try await (request, purchaseLiquidityOrder(request, session: session, profile: profile))
    }
    private func purchaseLiquidityOrder(_ request: LightningLiquidity.Purchase, session: LightningPeerSession, profile: LightningProfile) async throws -> LightningLiquidity.Order {
        if let base = LightningProviders.provider(profile)?.api {
            return try await LightningLiquidityHTTP(base: base).order(request, nodeID: liquidityNodeID())
        }
        return try await session.liquidityOrder(request)
    }
    private func liquidityNodeID() throws -> Data {
        guard let node = Data(hex: nodeID) else { throw LightningError.invalidState }
        return node
    }
    func acceptLiquidityQuote(model: AppModel) async throws {
        try await model.exclusively(.spending) {
            try requireNetwork(model)
            guard var quote = liquidityQuote, quote.profile == profile else { throw LightningError.invalidState }
            let epoch = generation
            _ = try quote.order.validate(request: quote.request, network: network, now: Self.now)
            try await model.authenticateSensitiveAction(reason: "Approve the \(quote.feeSat)-sat Lightning setup fee")
            defer { model.keychainAuthentication.revoke() }
            try Task.checkCancellation(); try requireNetwork(model, generation: epoch)
            _ = try quote.order.validate(request: quote.request, network: network, now: Self.now)
            quote.accepted = true
            quote.cancelledAt = nil
            try storeLiquidityQuote(quote); liquidityQuote = quote
        }
    }
    func cancelLiquiditySetup(model: AppModel) throws {
        try requireNetwork(model)
        guard var quote = liquidityQuote, quote.order.payment.bolt11?.state == "EXPECT_PAYMENT" else {
            throw LightningError.invalidState
        }
        quote.accepted = false
        quote.cancelledAt = Self.now
        try storeLiquidityQuote(quote)
        liquidityQuote = quote
    }
    func refreshLiquidityOrder(model: AppModel) async throws {
        try requireNetwork(model)
        guard !liquidityRequestInFlight, var quote = liquidityQuote, let session = liquiditySession else { throw LightningError.invalidState }
        liquidityRequestInFlight = true; defer { liquidityRequestInFlight = false }
        let epoch = generation
        let order = try await liquidityOrderStatus(id: quote.order.orderId, session: session)
        try requireNetwork(model, generation: epoch)
        try validateLiquidityOrderUpdate(order, quote: quote)
        quote.order = order
        if order.orderState == "FAILED" { quote.accepted = false }
        try storeLiquidityQuote(quote); liquidityQuote = quote
        await model.syncNow(); try await refresh()
    }
    private func liquidityOrderStatus(id: String, session: LightningPeerSession) async throws -> LightningLiquidity.Order {
        if let base = LightningProviders.provider(profile)?.api { return try await LightningLiquidityHTTP(base: base).status(id: id) }
        return try await session.liquidityOrderStatus(id: id)
    }
    private func validateLiquidityOrderUpdate(_ order: LightningLiquidity.Order, quote: LiquidityQuote) throws {
        guard order.orderId == quote.order.orderId, order.lspBalanceSat == quote.request.lspBalanceSat,
              order.clientBalanceSat == "0", !order.announceChannel,
              order.requiredChannelConfirmations == quote.request.requiredChannelConfirmations,
              order.fundingConfirmsWithinBlocks == quote.request.fundingConfirmsWithinBlocks,
              order.channelExpiryBlocks == quote.request.channelExpiryBlocks,
              order.payment.bolt11?.invoice == quote.invoice else { throw LightningError.invalidMessage }
    }
    func createReceiveInvoice(amountSat: UInt64, model: AppModel) async throws -> String {
        try requireNetwork(model)
        guard let engine, let profile, connection == "Connected" else { throw LightningError.invalidState }
        return try await engine.createInvoice(id: Self.freshID(), peer: profile.peerKey, amountSat: amountSat, network: network, now: Self.now)
    }
}
