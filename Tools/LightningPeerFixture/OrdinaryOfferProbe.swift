import Foundation
import LightningCore
import WalletCore

extension PeerFixture {
    static func ordinaryCommand(_ input: [String: String], engine: LightningEngine, peer: Data) async throws -> [String: String] {
        let now = UInt64(Date().timeIntervalSince1970)
        switch input["command"] {
        case "ordinary_request":
            guard let id = Data(hex: input["id"] ?? ""), let amount = UInt64(input["amount"] ?? "") else { throw LightningError.invalidMessage }
            let offer = try LightningOffer(string: input["offer"] ?? "")
            try await engine.requestOrdinaryInvoice(.init(id: id, offer: offer, amountMsat: amount, via: [peer]), now: now)
            return ["id": id.hex, "phase": "requesting"]
        case "ordinary_invoice":
            guard let id = Data(hex: input["id"] ?? ""), let pending = try await engine.ordinaryInvoiceRequests(now: now).first(where: { $0.request.id == id }) else { throw LightningError.invalidMessage }
            guard let invoice = pending.invoice else { return ["phase": pending.expired ? "expired" : "requesting"] }
            return ["phase": "review", "invoice": invoice.string, "hex": invoice.bytes.hex, "hash": invoice.paymentHash.hex, "amount": String(invoice.amountMsat)]
        case "ordinary_pay":
            guard let id = Data(hex: input["id"] ?? ""), let channel = Data(hex: input["channel"] ?? ""),
                  let pending = try await engine.ordinaryInvoiceRequests(now: now).first(where: { $0.request.id == id }), let invoice = pending.invoice else { throw LightningError.invalidMessage }
            FileHandle.standardError.write(Data("Ordinary invoice payinfo: \(invoice.payInfo.map { "min=\($0.minimumMsat) max=\($0.maximumMsat) delta=\($0.expiryDelta) base=\($0.baseMsat) ppm=\($0.proportionalMillionths)" })\n".utf8))
            let route = try Bolt12PaymentRoute(hops: [], pathIndex: 0, introduction: peer)
            let request = LightningEngine.OrdinaryInvoicePayment(id: id, channelID: channel, invoice: invoice,
                feeLimitMsat: UInt64(input["fee"] ?? "") ?? 50_000, maximumDelta: 2016, route: route)
            let payment = try await engine.payOrdinaryInvoice(request, now: now)
            return ["id": id.hex, "phase": payment.phase.rawValue]
        case "ordinary_register":
            guard let id = Data(hex: input["id"] ?? "") else { throw LightningError.invalidMessage }
            let offer = try await engine.registerOrdinaryOffer(.init(id: id, peer: peer, description: "Winnow stock BOLT12 receiving",
                expiresAt: now + 86_400, blinded: input["blinded"] != "false"), now: now)
            return ["offer": offer.string]
        default: throw LightningError.invalidMessage
        }
    }
}
