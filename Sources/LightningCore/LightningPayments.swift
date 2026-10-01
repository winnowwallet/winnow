import Foundation
import P256K

extension LightningEngine {
    public enum PaymentPhase: String, Codable, Sendable { case preparing, inFlight, awaitingRecipient, recovering, settled, failed }
    public struct Payment: Codable, Sendable, Equatable {
        public let id: Data, hash: Data
        public let amountMsat: UInt64
        public let incoming: Bool
        public var phase: PaymentPhase
        public var preimage: Data?
        public var feeMsat: UInt64?
    }
    /// The initial direct-channel adapter. BOLT12 routing supplies a separate
    /// authenticated request before using this same durable payment machinery.
    public struct DirectPayment: Codable, Sendable, Equatable {
        public let id: Data, peer: Data, channelID: Data, paymentHash: Data, paymentSecret: Data
        public let amountMsat: UInt64, feeLimitMsat: UInt64
        public let expiry: UInt32
        public init(id: Data, peer: Data, channelID: Data, paymentHash: Data, paymentSecret: Data,
                    amountMsat: UInt64, feeLimitMsat: UInt64, expiry: UInt32) {
            self.id = id; self.peer = peer; self.channelID = channelID; self.paymentHash = paymentHash
            self.paymentSecret = paymentSecret; self.amountMsat = amountMsat; self.feeLimitMsat = feeLimitMsat; self.expiry = expiry
        }
    }
    struct PaymentRecord: Codable {
        var payment: Payment
        let channelID: Data
        var htlcID: UInt64?
        let request: DirectPayment?
        var chainResolution: PaymentChainResolution?
        var invoiceRequest: InvoicePayment? = nil
    }
    struct ReceiveRequest: Codable {
        let id: Data, preimage: Data, secret: Data
        let amountMsat: UInt64
        let expiry: UInt32
        var expiresAt: UInt64? = nil
    }
    public struct ReceiveInvoice: Sendable {
        public let id: Data, paymentHash: Data, paymentSecret: Data
        public let amountMsat: UInt64
        public let expiry: UInt32
    }
    public func payments() -> [Payment] { state.payments.map(\.payment) }
    @discardableResult
    public func payDirect(_ request: DirectPayment) throws -> Payment {
        try operational(request.peer)
        if let existing = state.payments.first(where: { $0.payment.id == request.id }) {
            guard existing.request == request else { throw LightningError.invalidMessage }
            return existing.payment
        }
        guard request.id.count == 32, request.paymentHash.count == 32, request.expiry > chainHeight,
              !state.payments.contains(where: { $0.payment.hash == request.paymentHash }), state.payments.count < 4096
        else { throw LightningError.invalidMessage }
        let index = try activeChannelIndex(request.channelID, peer: request.peer)
        var channel = state.channels[index], next = state
        let payload = try PaymentPayload(amountMsat: request.amountMsat, expiry: request.expiry, secret: request.paymentSecret)
        let onion = try OnionPacket.create(hops: [.init(publicKey: request.peer, payload: payload.bytes)], associatedData: request.paymentHash)
        // A direct channel has no forwarding fee, so any nonnegative fee limit
        // is satisfied. Never invent an indirect route behind this API.
        let id = try enqueueHTLC(channel: &channel, in: &next, amountMsat: request.amountMsat,
            paymentHash: request.paymentHash, expiry: request.expiry, onion: onion)
        let payment = Payment(id: request.id, hash: request.paymentHash, amountMsat: request.amountMsat, incoming: false, phase: .inFlight)
        next.payments.append(PaymentRecord(payment: payment, channelID: channel.id, htlcID: id, request: request))
        next.channels[index] = channel
        try persist(next)
        return payment
    }
    public func registerReceive(id: Data, amountMsat: UInt64, expiry: UInt32, expiresAt: UInt64? = nil) throws -> ReceiveInvoice {
        try requireUsableChannels()
        guard id.count == 32, amountMsat > 0, amountMsat <= 16_777_215_000, expiry > chainHeight,
              state.incoming.count < 4096 else { throw LightningError.invalidMessage }
        if let existing = state.incoming.first(where: { $0.id == id }) {
            guard existing.amountMsat == amountMsat, existing.expiry == expiry, existing.expiresAt == expiresAt else { throw LightningError.invalidMessage }
            return invoice(existing)
        }
        let request = try ReceiveRequest(id: id, preimage: P256K.Signing.PrivateKey().dataRepresentation,
            secret: P256K.Signing.PrivateKey().dataRepresentation, amountMsat: amountMsat, expiry: expiry, expiresAt: expiresAt)
        var next = state; next.incoming.append(request)
        try persist(next)
        return invoice(request)
    }
    private func invoice(_ request: ReceiveRequest) -> ReceiveInvoice {
        ReceiveInvoice(id: request.id, paymentHash: ChannelKeys.hash(request.preimage), paymentSecret: request.secret,
                       amountMsat: request.amountMsat, expiry: request.expiry)
    }
    func reconcilePayments(in next: inout State) throws -> [Event] {
        var events: [Event] = []
        for index in next.payments.indices {
            var record = next.payments[index]
            guard [.inFlight, .awaitingRecipient].contains(record.payment.phase), let channel = next.channels.first(where: { $0.id == record.channelID }) else { continue }
            for update in channel.updates where update.irrevocable {
                switch update.change {
                case .fulfill(let id, let offered, let preimage) where id == record.htlcID && offered != record.payment.incoming:
                    record.payment.phase = .settled; record.payment.preimage = preimage
                case .fail(let id, let offered, _) where id == record.htlcID && offered != record.payment.incoming:
                    record.payment.phase = .failed
                default: break
                }
            }
            if record.payment != next.payments[index].payment {
                if record.invoiceRequest != nil && record.payment.phase == .failed { publicRoutingGraph = nil }
                next.payments[index] = record; events.append(.paymentChanged(record.payment))
                next.async.outbox.removeAll { $0.key == Data([5]) + record.payment.id }
            }
        }
        events += try reconcileHeldPayments(in: &next)
        try claimIncoming(in: &next)
        return events
    }
    private func claimIncoming(in next: inout State) throws {
        for index in next.channels.indices {
            var channel = next.channels[index]
            guard [.ready, .closing].contains(channel.phase), !channel.awaitingRevocation else { continue }
            for update in channel.updates where update.irrevocable {
                guard case .add(let htlc, let onion) = update.change, !htlc.offered,
                      !channel.hasRemoval(id: htlc.id, offered: false) else { continue }
                try claim(htlc, onion: onion, channel: &channel, state: &next)
            }
            try signPending(&channel, in: &next)
            next.channels[index] = channel
        }
    }
    private func claim(_ htlc: ChannelTransactions.HTLC, onion: Data, channel: inout ChannelState, state: inout State) throws {
        let blinding = channel.incomingBlinding[htlc.id]
        let peeled: OnionPacket.Peeled?
        if let blinding { peeled = try? BlindedPayment.peel(onion: onion, blinding: blinding, nodeSecret: state.nodeSecret, hash: htlc.paymentHash) }
        else { peeled = try? OnionPacket.peel(onion, secret: state.nodeSecret, associatedData: htlc.paymentHash) }
        guard let peeled else {
            try failIncoming(htlc, onion: onion, sharedSecret: nil, channel: &channel, state: &state)
            return
        }
        let request = blinding.map {
            validOrdinaryReceive(htlc, peeled: peeled, blinding: $0, state: state)
                ?? validAsyncReceive(htlc, peeled: peeled, blinding: $0, state: state)
        } ?? validReceive(htlc, peeled: peeled, state: state)
        guard let request else {
            try failIncoming(htlc, onion: onion, sharedSecret: peeled.sharedSecret, channel: &channel, state: &state)
            return
        }
        channel.updates.append(ChannelUpdate(change: .fulfill(id: htlc.id, offered: false, preimage: request.preimage), fromLocal: true))
        if !channel.learnedPreimages.contains(request.preimage) { channel.learnedPreimages.append(request.preimage) }
        var writer = LightningWire.Writer(); writer.append(channel.id); writer.u64(htlc.id); writer.append(request.preimage)
        try Self.enqueue(.init(type: 130, payload: writer.data), channel: channel, in: &state)
        let payment = Payment(id: request.id, hash: htlc.paymentHash, amountMsat: request.amountMsat, incoming: true, phase: .inFlight)
        state.payments.append(PaymentRecord(payment: payment, channelID: channel.id, htlcID: htlc.id, request: nil))
    }
    private func validReceive(_ htlc: ChannelTransactions.HTLC, peeled: OnionPacket.Peeled, state: State) -> ReceiveRequest? {
        guard peeled.next == nil, let request = state.incoming.first(where: { ChannelKeys.hash($0.preimage) == htlc.paymentHash }),
              !state.payments.contains(where: { $0.payment.hash == htlc.paymentHash }), htlc.expiry <= request.expiry,
              request.expiresAt.map({ $0 > UInt64(Date().timeIntervalSince1970) }) ?? true,
              let payload = try? PaymentPayload(bytes: peeled.payload) else { return nil }
        do {
            try payload.validate(expectedSecret: request.secret, expectedAmount: request.amountMsat, receivedAmount: htlc.amountMsat,
                receivedExpiry: htlc.expiry, height: chainHeight, minimumDelta: 18)
            return request
        } catch { return nil }
    }
    private func failIncoming(_ htlc: ChannelTransactions.HTLC, onion: Data, sharedSecret: Data?,
                              channel: inout ChannelState, state: inout State) throws {
        var writer = LightningWire.Writer(); writer.append(channel.id); writer.u64(htlc.id)
        let type: UInt16
        let reason: Data
        if let sharedSecret {
            var detail = LightningWire.Writer(); detail.u64(htlc.amountMsat); detail.u32(chainHeight)
            reason = try OnionPacket.failure(sharedSecret: sharedSecret, code: 0x400f, data: detail.data)
            writer.u16(UInt16(reason.count)); writer.append(reason); type = 131
        } else {
            let code: UInt16 = onion.first == 0 ? 0xc005 : 0xc004
            reason = ChannelKeys.hash(onion); writer.append(reason); writer.u16(code); type = 135
        }
        channel.updates.append(ChannelUpdate(change: .fail(id: htlc.id, offered: false, reason: reason), fromLocal: true))
        try Self.enqueue(.init(type: type, payload: writer.data), channel: channel, in: &state)
    }
}
