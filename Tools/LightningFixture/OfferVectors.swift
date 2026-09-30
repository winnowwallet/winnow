import Foundation
import LightningCore
import WalletCore

extension Fixture {
    static func offerVectors() throws -> [String: String] {
        let input = try JSONDecoder().decode([String: String].self, from: FileHandle.standardInput.readDataToEndOfFile())
        guard let string = input["offer"], let invoiceBytes = Data(hex: input["static_invoice"] ?? "") else { throw LightningError.invalidMessage }
        let referenceOffer = try LightningOffer(string: string), referenceInvoice = try StaticInvoice(bytes: invoiceBytes)
        try asyncMessages(input, invoice: referenceInvoice)
        try referenceInvoice.validatePayment(for: referenceOffer, chain: referenceOffer.chains[0], now: 1_800_000_010, amountMsat: 5000)
        let request = try InvoiceRequest(offer: referenceOffer, chain: referenceOffer.chains[0], amountMsat: 5000,
            now: 1_800_000_010, metadata: secret(50), payerSecret: secret(51))
        var fields = try Bolt12Encoding.records(referenceOffer.bytes).filter { $0.type != 22 }
        fields.append(try .init(type: 22, value: key(52)))
        let swiftOffer = try LightningOffer(bytes: Bolt12Encoding.serialize(fields.sorted { $0.type < $1.type }))
        let swiftInvoice = try StaticInvoice(offer: swiftOffer, paymentPaths: referenceInvoice.paymentPaths, payInfo: referenceInvoice.payInfo,
            notificationPaths: referenceInvoice.notificationPaths, createdAt: 1_800_000_010, relativeExpiry: 3600, signingSecret: secret(52))
        let reply = try OnionMessage.path(nodes: [key(51)], context: Data("invoice reply".utf8), authenticationKey: secret(53))
        let message = try OnionMessage.create(to: referenceOffer.paths[0], content: .init(type: 64, value: request.bytes), reply: reply)
        let routed = try OnionMessage.create(to: referenceOffer.paths[0], via: [key(54), key(55)], content: .init(type: 64, value: request.bytes), reply: reply)
        guard case .forward(_, let intermediate) = try OnionMessage.peel(routed, nodeSecret: secret(54), authenticationKey: secret(53)),
              case .forward(_, let forwarded) = try OnionMessage.peel(intermediate, nodeSecret: secret(55), authenticationKey: secret(53)) else { throw LightningError.invalidMessage }
        return ["reference_roundtrip": referenceInvoice.bytes.hex, "invoice_request": request.bytes.hex,
                "payer_key": request.payerKey.hex, "swift_offer": swiftOffer.string, "swift_static_invoice": swiftInvoice.bytes.hex,
                "swift_signing_key": swiftInvoice.signingKey.hex, "onion_request": message.payload.hex,
                "forwarded_request": forwarded.payload.hex, "reply_path": try reply.encoded().hex]
    }
    static func onionReply() throws -> [String: String] {
        let input = try JSONDecoder().decode([String: String].self, from: FileHandle.standardInput.readDataToEndOfFile())
        guard let bytes = Data(hex: input["hex"] ?? ""),
              case .receive(let content, let context, _) = try OnionMessage.peel(.init(type: 513, payload: bytes), nodeSecret: secret(51), authenticationKey: secret(53)),
              content.type == 70, context == Data("invoice reply".utf8) else { throw LightningError.invalidMessage }
        let invoice = try StaticInvoice(bytes: content.value)
        return ["static_invoice": invoice.bytes.hex, "context": String(decoding: context, as: UTF8.self)]
    }
    static func asyncMessages(_ reference: [String: String], invoice: StaticInvoice) throws {
        let samples: [(String, AsyncPaymentMessage)] = [
            ("offer_paths_request", .offerPathsRequest(slot: 7)),
            ("offer_paths", .offerPaths(invoice.offer.paths, expiry: 1_800_003_600)),
            ("serve_static_invoice", .serve(invoice, forwardRequest: invoice.offer.paths[0])),
            ("persisted", .persisted), ("held", .held), ("release", .release)]
        for (name, value) in samples {
            let record = try value.record()
            guard record.value.hex == reference[name], try AsyncPaymentMessage(record: record).record() == record else {
                throw LightningError.invalidMessage
            }
        }
    }
}
