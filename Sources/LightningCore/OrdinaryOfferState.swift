import Foundation

extension LightningEngine {
    public struct OrdinaryOfferConfiguration: Codable, Sendable, Equatable {
        public let id: Data, peer: Data
        public let description: String
        public let minimumMsat: UInt64?, expiresAt: UInt64
        public let blinded: Bool
        public init(id: Data, peer: Data, description: String, minimumMsat: UInt64? = nil, expiresAt: UInt64, blinded: Bool = true) {
            self.id = id; self.peer = peer; self.description = description; self.minimumMsat = minimumMsat
            self.expiresAt = expiresAt; self.blinded = blinded
        }
    }
    struct OrdinaryReceiveOffer: Codable { let configuration: OrdinaryOfferConfiguration; let offer: Data }
    public struct OrdinaryOfferRequest: Codable, Sendable, Equatable {
        public let id: Data, offer: Data, amountMsat: UInt64
        public let via: [Data]
        public let humanReadableName: BIP353Name?
        public init(id: Data, offer: LightningOffer, amountMsat: UInt64, via: [Data], humanReadableName: BIP353Name? = nil) {
            self.id = id; self.offer = offer.bytes; self.amountMsat = amountMsat; self.via = via; self.humanReadableName = humanReadableName
        }
    }
    public struct OrdinaryInvoicePayment: Codable, Sendable, Equatable {
        public let id: Data, channelID: Data
        public let invoice: Data
        public let feeLimitMsat: UInt64, maximumDelta: UInt32
        public let route: Bolt12PaymentRoute
        public init(id: Data, channelID: Data, invoice: Bolt12Invoice, feeLimitMsat: UInt64, maximumDelta: UInt32 = 2016, route: Bolt12PaymentRoute) {
            self.id = id; self.channelID = channelID; self.invoice = invoice.bytes; self.feeLimitMsat = feeLimitMsat
            self.maximumDelta = maximumDelta; self.route = route
        }
    }
    struct OrdinaryOutgoing: Codable {
        let request: OrdinaryOfferRequest, invoiceRequest: Data, expectedIssuer: Data, payerSecret: Data, requestedAt: UInt64
        var invoice: Data?
        var payment: OrdinaryInvoicePayment?
    }
    struct OrdinaryIssuedInvoice: Codable { let request: Data, invoice: Data; let expiresAt: UInt64 }
    struct OrdinaryOfferState: Codable {
        var receives: [OrdinaryReceiveOffer] = []
        var outgoing: [OrdinaryOutgoing] = []
        var issued: [OrdinaryIssuedInvoice] = []
    }
    public struct OrdinaryInvoiceStatus: Sendable {
        public let request: OrdinaryOfferRequest, requestedAt: UInt64
        public let invoice: Bolt12Invoice?
        public let expired: Bool
    }
    public func ordinaryInvoiceRequests(now: UInt64) throws -> [OrdinaryInvoiceStatus] {
        try healthy()
        return try (state.offers?.outgoing ?? []).map { outgoing in
            OrdinaryInvoiceStatus(request: outgoing.request, requestedAt: outgoing.requestedAt,
                invoice: try outgoing.invoice.map(Bolt12Invoice.init(bytes:)),
                expired: now > outgoing.requestedAt && now - outgoing.requestedAt > 300 && outgoing.invoice == nil)
        }
    }
    static func validateOrdinaryOffers(_ offers: OrdinaryOfferState?) throws {
        guard let offers else { return }
        guard offers.receives.count <= 128, offers.outgoing.count <= 4096, offers.issued.count <= 4096 else { throw LightningError.storageFailed }
        for receive in offers.receives { _ = try LightningOffer(bytes: receive.offer) }
        for outgoing in offers.outgoing {
            _ = try InvoiceRequest(bytes: outgoing.invoiceRequest)
            _ = try outgoing.invoice.map(Bolt12Invoice.init(bytes:))
        }
    }
}
