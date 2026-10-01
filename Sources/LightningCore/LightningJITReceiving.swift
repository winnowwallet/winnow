import Foundation
import P256K
import WalletCore

/// bLIP-52 receiving: one invoice whose route hint names the provider's
/// intercept scid. The provider opens a private channel when the payment
/// arrives; Winnow accepts that channel before it confirms only because it
/// bought it, from that provider, for that payment.
extension LightningEngine {
    struct JITPurchase: Codable {
        let id: Data
        let provider: Data
        let paymentSizeMsat: UInt64, openingFeeMsat: UInt64
        let scid: UInt64
        let invoiceExpiresAt: UInt64
        let recovery: ChannelResolution.Policy
        let clientTrustsLsp: Bool
        var channel: Data? = nil
        var claimed = false
        /// The provider forwards amount minus fee, so it opens a channel at
        /// least that large (bLIP-52 rounds down to whole sats).
        var minimumCapacitySat: UInt64 { (paymentSizeMsat - openingFeeMsat) / 1000 }
        func accepts(_ open: ChannelNegotiation.Open, from peer: Data, now: UInt64) -> Bool {
            peer == provider && channel == nil && !claimed && now <= invoiceExpiresAt + Self.forwardingGrace
                && open.pushMsat == 0 && open.capacity >= minimumCapacitySat
        }
        /// Time for the provider to open the channel once the invoice is paid.
        static let forwardingGrace: UInt64 = 300
    }
    struct ZeroConfGrant: Codable, Equatable {
        let purchase: Data
        let height: UInt32
    }
    struct JITReceive: Codable, Equatable {
        let provider: Data
        let maximumFeeMsat: UInt64
    }
    public struct JITTerms: Sendable {
        public let provider: Data
        public let offer: LightningJIT.Offer
        public let purchase: LightningJIT.Purchase
        public let paymentSizeMsat: UInt64
        public init(provider: Data, offer: LightningJIT.Offer, purchase: LightningJIT.Purchase, paymentSizeMsat: UInt64) {
            self.provider = provider; self.offer = offer; self.purchase = purchase; self.paymentSizeMsat = paymentSizeMsat
        }
    }
    static let maximumJITPurchases = 8

    /// The invoice for a bought just-in-time channel. The recovery policy is
    /// fixed now, so the provider's payment can be accepted the moment its
    /// channel opens.
    public func createJITInvoice(id: Data, terms: JITTerms, recoveryDestination: Data, recoveryFeeSat: UInt64,
                                 network: BitcoinNetwork, now: UInt64) throws -> String {
        try operational(terms.provider)
        guard state.chain == NetworkParams.params(for: network).genesisHash, id.count == 32, now < (1 << 35) - 3600,
              !state.incoming.contains(where: { $0.id == id }), state.incoming.count < 4096,
              chainHeight <= UInt32.max - 2016 else { throw LightningError.invalidMessage }
        let fee = try terms.offer.fee(paymentMsat: terms.paymentSizeMsat)
        let route = try terms.purchase.validated()
        let lifetime = try Self.jitInvoiceLifetime(validUntil: terms.offer.validUntil, now: now)
        let recovery = try Self.jitRecovery(destination: recoveryDestination, feeSat: recoveryFeeSat,
                                            minimumCapacitySat: (terms.paymentSizeMsat - fee) / 1000)
        let request = try ReceiveRequest(id: id, preimage: P256K.Signing.PrivateKey().dataRepresentation,
            secret: P256K.Signing.PrivateKey().dataRepresentation, amountMsat: terms.paymentSizeMsat, expiry: chainHeight + 2016,
            expiresAt: now + lifetime + JITPurchase.forwardingGrace, jit: .init(provider: terms.provider, maximumFeeMsat: fee))
        let purchase = JITPurchase(id: id, provider: terms.provider, paymentSizeMsat: terms.paymentSizeMsat, openingFeeMsat: fee,
            scid: route.scid, invoiceExpiresAt: now + lifetime, recovery: recovery,
            clientTrustsLsp: terms.purchase.clientTrustsLsp ?? false)
        var next = state
        next.incoming.append(request)
        next.jit = Self.retainedPurchases(next.jit ?? [], now: now) + [purchase]
        try persist(next)
        return try Bolt11Invoice.encode(network: network, amountMsat: terms.paymentSizeMsat, hash: ChannelKeys.hash(request.preimage),
            secret: request.secret, nodeSecret: state.nodeSecret,
            route: .init(peer: terms.provider, shortChannelID: route.scid, baseMsat: 0, proportionalMillionths: 0,
                         expiryDelta: route.delta),
            timestamp: now, expirySeconds: lifetime, minimumFinalDelta: 20)
    }
    /// The invoice must expire before the provider's fee terms do (bLIP-52).
    static func jitInvoiceLifetime(validUntil: UInt64, now: UInt64) throws -> UInt64 {
        guard validUntil > now + 90 else { throw LightningError.invalidAmount }
        return min(3600, validUntil - now - 30)
    }
    static func jitRecovery(destination: Data, feeSat: UInt64, minimumCapacitySat: UInt64) throws -> ChannelResolution.Policy {
        guard ChannelTerms.validShutdown(destination, anySegwit: true), feeSat > 0, feeSat < minimumCapacitySat else {
            throw LightningError.invalidAmount
        }
        return .init(destination: destination, feeSat: feeSat)
    }
    /// Keeps purchases still tied to a channel or still payable, at most eight.
    static func retainedPurchases(_ purchases: [JITPurchase], now: UInt64) -> [JITPurchase] {
        let live = purchases.filter { $0.channel != nil || now <= $0.invoiceExpiresAt + JITPurchase.forwardingGrace }
        return Array(live.suffix(maximumJITPurchases - 1))
    }

    /// Binds an inbound open to the oldest purchase it satisfies. A
    /// zero-conf channel_type without a purchase is refused, not downgraded.
    func jitGrant(_ open: ChannelNegotiation.Open, peer: Data, in next: inout State) throws -> (grant: ZeroConfGrant, recovery: ChannelResolution.Policy)? {
        let now = UInt64(Date().timeIntervalSince1970)
        guard let index = next.jit?.firstIndex(where: { $0.accepts(open, from: peer, now: now) }) else {
            guard !open.terms.options.contains(.zeroConf) else { throw LightningError.invalidMessage }
            return nil
        }
        next.jit?[index].channel = open.temporaryID
        let purchase = next.jit![index]
        return (ZeroConfGrant(purchase: purchase.id, height: chainHeight), purchase.recovery)
    }
    /// A purchase whose channel never reached funding can be bought again.
    static func releasePurchases(boundTo channels: [ChannelState], in next: inout State) {
        let temporary = Set(channels.map(\.temporaryID))
        for index in (next.jit ?? []).indices where next.jit![index].channel.map(temporary.contains) == true {
            next.jit![index].channel = nil
        }
    }
    /// BOLT 2: a fundee forgets a channel the funder never funded. On
    /// reconnection such a channel can only replay a stale accept_channel.
    func forgetUnsignedInbound(peer: Data) throws {
        let stale = state.channels.filter { $0.peer == peer && !$0.isFunder && $0.phase == .accepted && $0.fundingTxid == nil }
        guard !stale.isEmpty else { return }
        var next = state
        for channel in stale { Self.close(unsigned: channel, in: &next) }
        Self.releasePurchases(boundTo: stale, in: &next)
        try persist(next)
    }
    static func close(unsigned channel: ChannelState, in next: inout State) {
        guard let index = next.channels.firstIndex(where: { $0.peer == channel.peer && $0.temporaryID == channel.temporaryID }) else { return }
        next.channels[index].phase = .closed
        next.outbox.removeAll { $0.peer == channel.peer && ($0.channelID == channel.id || $0.channelID == channel.temporaryID) }
    }
    /// A bought channel whose funding never appears and which holds nothing
    /// of ours is forgotten after two weeks of blocks (BOLT 2's 2016).
    static func forgetUnfundedZeroConf(height: UInt32, in next: inout State) throws {
        for index in next.channels.indices {
            let channel = next.channels[index]
            guard let grant = channel.zeroConf, !channel.fundingIsConfirmed, channel.phase != .closed,
                  UInt64(height) >= UInt64(grant.height) + 2016,
                  try channel.view(localOwner: true, number: channel.localNumber).localMsat == 0 else { continue }
            next.channels[index].phase = .closed
            next.outbox.removeAll { $0.peer == channel.peer && $0.channelID == channel.id }
        }
    }

    static func readyMessage(_ channel: ChannelState) throws -> LightningWire.Message {
        var writer = LightningWire.Writer(); writer.append(channel.id); writer.append(try channel.secrets.point(1))
        if let alias = channel.localAlias {
            var value = LightningWire.Writer(); value.u64(alias)
            try writer.tlvs([.init(type: 1, value: value.data)])
        }
        return try .init(type: 36, payload: writer.data)
    }
    static func alias(_ fields: [LightningWire.TLV]) throws -> UInt64? {
        guard let field = fields.first(where: { $0.type == 1 }) else { return nil }
        var reader = LightningWire.Reader(field.value)
        let alias = try reader.u64(); try reader.requireEnd()
        guard alias != 0 else { throw LightningError.invalidMessage }
        return alias
    }
    static func newAlias() -> UInt64 { UInt64.random(in: 1...UInt64.max) }

    /// What the provider kept from a just-in-time payment, or nil if this
    /// HTLC must be refused. Ordinary invoices ignore extra_fee.
    static func deduction(_ htlc: ChannelTransactions.HTLC, request: ReceiveRequest, channel: ChannelState) -> UInt64? {
        guard let jit = request.jit else { return 0 }
        let fee = channel.incomingExtraFee?[htlc.id] ?? 0
        guard channel.peer == jit.provider, fee <= jit.maximumFeeMsat else { return nil }
        return fee
    }
    static func recordExtraFee(_ fields: [LightningWire.TLV], id: UInt64, in channel: inout ChannelState) throws {
        guard let field = fields.first(where: { $0.type == 65537 }) else { return }
        var reader = LightningWire.Reader(field.value)
        let fee = try reader.u64(); try reader.requireEnd()
        channel.incomingExtraFee = (channel.incomingExtraFee ?? [:]).merging([id: fee]) { $1 }
    }
    static func markClaimed(_ request: ReceiveRequest, in next: inout State) {
        guard request.jit != nil, let index = next.jit?.firstIndex(where: { $0.id == request.id }) else { return }
        next.jit?[index].claimed = true
    }
}
