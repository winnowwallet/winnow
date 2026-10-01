import Foundation
import WalletCore

extension LightningEngine {
    struct InvoicePolicy: Codable {
        let peer: Data, shortChannelID: UInt64, timestamp: UInt32
        let baseMsat: UInt32, proportionalMillionths: UInt32
        let expiryDelta: UInt16, disabled: Bool
        let minimumMsat: UInt64, maximumMsat: UInt64?
        func route(through scid: UInt64) -> Bolt11Invoice.Route {
            .init(peer: peer, shortChannelID: scid, baseMsat: baseMsat,
                  proportionalMillionths: proportionalMillionths, expiryDelta: expiryDelta)
        }
    }
    /// Authenticated private-channel policy, never an invented route or fee.
    public func receiveChannelPolicy(peer: Data, message: LightningWire.Message) throws {
        // Signed policy metadata is control traffic; financial invoice/channel
        // actions still require a verified chain in their own entry points.
        try healthy(); guard peers[peer] != nil else { throw LightningError.invalidState }
        guard message.type == 258 else { throw LightningError.invalidMessage }
        // No private routing policy can apply before funding is identified.
        // Old rejected requests must not turn general gossip into a failure.
        guard state.channels.contains(where: { $0.peer == peer && $0.phase != .closed && $0.fundingTxid != nil }) else { return }
        guard let policy = try? parsePolicy(peer: peer, message: message) else { return }
        try storeInvoicePolicy(policy, from: peer)
    }
    private func storeInvoicePolicy(_ policy: InvoicePolicy, from peer: Data) throws {
        let scid = policy.shortChannelID, timestamp = policy.timestamp
        if persistedPolicy(scid: scid, isNewerThan: timestamp) { return }
        if let previous = invoicePolicies[scid], previous.timestamp > timestamp { return }
        guard invoicePolicies[scid] != nil || invoicePolicies.count < 128 else { return }
        invoicePolicies[scid] = policy
        if let index = state.channels.firstIndex(where: { $0.peer == peer && routingIdentifiers($0).contains(scid) }) {
            var next = state; next.channels[index].invoicePolicy = policy; try persist(next)
        }
    }
    private func parsePolicy(peer: Data, message: LightningWire.Message) throws -> InvoicePolicy? {
        var reader = LightningWire.Reader(message.payload)
        let signature = try reader.take(64), chain = try reader.take(32), scid = try reader.u64()
        let timestamp = try reader.u32(), messageFlags = try reader.u8(), channelFlags = try reader.u8()
        let delta = try reader.u16(), minimum = try reader.u64(), base = try reader.u32(), proportional = try reader.u32()
        let maximum = messageFlags & 1 == 1 ? try reader.u64() : nil
        // Future signed policy extensions are included in the signature.
        // Ignore general gossip and our own direction, while checking policies
        // used for invoices against the authenticated peer's signature.
        guard chain == state.chain, channelFlags & 1 == (peer.lexicographicallyPrecedes(try nodeID()) ? 0 : 1) else { return nil }
        let digest = ChannelKeys.hash(ChannelKeys.hash(Data(message.payload.dropFirst(64))))
        guard ChannelKeys.verify(signature: try ChannelKeys.derSignature(signature), digest: digest, publicKey: peer) else { return nil }
        return InvoicePolicy(peer: peer, shortChannelID: scid, timestamp: timestamp, baseMsat: base,
            proportionalMillionths: proportional, expiryDelta: delta, disabled: channelFlags & 2 != 0,
            minimumMsat: minimum, maximumMsat: maximum)
    }
    private func persistedPolicy(scid: UInt64, isNewerThan timestamp: UInt32) -> Bool {
        state.channels.contains { ($0.invoicePolicy?.shortChannelID == scid) && ($0.invoicePolicy?.timestamp ?? 0) >= timestamp }
    }
    func shortChannelID(_ channel: ChannelState) throws -> UInt64 {
        guard let output = channel.fundingOutput,
              let observed = state.scan.transactions.first(where: { (try? Transaction.decode($0.raw).txid) == channel.fundingTxid }),
              let index = observed.transactionIndex, observed.height < 1 << 24, index < 1 << 24 else { throw LightningError.invalidState }
        return UInt64(observed.height) << 40 | UInt64(index) << 16 | UInt64(output)
    }
    /// Every scid a peer's channel_update may name for this channel: the real
    /// one once mined, and either channel_ready alias before or after.
    func routingIdentifiers(_ channel: ChannelState) -> Set<UInt64> {
        var identifiers = Set([channel.localAlias, channel.remoteAlias].compactMap { $0 })
        if let scid = try? shortChannelID(channel) { identifiers.insert(scid) }
        return identifiers
    }
    /// The scid a payer's route hint names: the peer's alias for a private
    /// alias channel or before funding confirms (BOLT 2), else the real one.
    func routeSCID(_ channel: ChannelState) -> UInt64? {
        if let alias = channel.remoteAlias, channel.local.options.contains(.scidAlias) || !channel.fundingIsConfirmed {
            return alias
        }
        return try? shortChannelID(channel)
    }
    /// The newest authenticated policy the peer signed for any of this
    /// channel's identifiers.
    func channelPolicy(_ channel: ChannelState) -> InvoicePolicy? {
        let identifiers = routingIdentifiers(channel)
        let candidates = invoicePolicies.values.filter { $0.peer == channel.peer && identifiers.contains($0.shortChannelID) }
            + [channel.invoicePolicy].compactMap { $0 }.filter { identifiers.contains($0.shortChannelID) }
        return candidates.max { $0.timestamp < $1.timestamp }
    }
    public struct InvoiceCapacity: Sendable {
        public let channelID: Data, route: Bolt11Invoice.Route
        public let minimumMsat: UInt64, maximumMsat: UInt64
    }
    public func invoiceCapacities(peer: Data) throws -> [InvoiceCapacity] {
        try healthy()
        guard chainIsCurrent else { return [] }
        try persistInvoicePolicies()
        return try state.channels.compactMap { channel in
            guard channel.peer == peer else { return nil }
            return try invoiceCapacity(channel)
        }
    }
    private func invoiceCapacity(_ channel: ChannelState) throws -> InvoiceCapacity? {
        guard channel.phase == .ready, channel.fundingUsable, channel.recovery != nil, let scid = routeSCID(channel),
              let policy = channelPolicy(channel), !policy.disabled, policy.expiryDelta > 0 else { return nil }
        let balance = try channel.view(localOwner: true, number: channel.localNumber)
        let recoveryReserve = UInt64(balance.feePerKW) * channel.local.format.commitmentWeight
            + channel.local.format.anchorReserveSat * 1000
        let reserve = channel.local.reserveSat * 1000 + (channel.isFunder ? 0 : recoveryReserve)
        let maximum = min(balance.remoteMsat > reserve ? balance.remoteMsat - reserve : 0,
                          channel.local.maximumHTLCMsat, policy.maximumMsat ?? .max)
        return InvoiceCapacity(channelID: channel.id, route: policy.route(through: scid),
            minimumMsat: max(1, channel.local.minimumHTLCMsat, policy.minimumMsat), maximumMsat: maximum)
    }
    private func persistInvoicePolicies() throws {
        var next = state, changed = false
        for index in next.channels.indices {
            guard let policy = channelPolicy(next.channels[index]),
                  (next.channels[index].invoicePolicy?.timestamp ?? 0) < policy.timestamp else { continue }
            next.channels[index].invoicePolicy = policy; changed = true
        }
        if changed { try persist(next) }
    }
    public func prepareInvoiceRouting() throws {
        try healthy()
        // A bought channel's unconfirmed funding has no position to find yet.
        let missingPosition = state.channels.contains { channel in
            channel.fundingTxid != nil && (try? shortChannelID(channel)) == nil && channel.phase != .closed
                && (channel.zeroConf == nil || channel.fundingIsConfirmed)
        }
        if missingPosition && !state.scan.rescanRequired {
            var next = state; next.scan.rescanRequired = true; try persist(next)
        }
    }
    public func createInvoice(id: Data, peer: Data, amountSat: UInt64, network: BitcoinNetwork, now: UInt64) throws -> String {
        try operational(peer)
        guard now < (1 << 35) - 3600, state.chain == NetworkParams.params(for: network).genesisHash,
              amountSat > 0, amountSat <= 16_777_215 else { throw LightningError.invalidAmount }
        guard let capacity = try invoiceCapacities(peer: peer).first(where: {
            ($0.minimumMsat...max($0.minimumMsat, $0.maximumMsat)).contains(amountSat * 1000) && $0.maximumMsat >= amountSat * 1000
        }) else { throw LightningError.invalidAmount }
        guard chainHeight <= UInt32.max - 2016 else { throw LightningError.invalidState }
        let invoice = try registerReceive(id: id, amountMsat: amountSat * 1000, expiry: chainHeight + 2016, expiresAt: now + 3600)
        return try Bolt11Invoice.encode(network: network, amountMsat: invoice.amountMsat, hash: invoice.paymentHash,
            secret: invoice.paymentSecret, nodeSecret: state.nodeSecret, route: capacity.route, timestamp: now)
    }
}
