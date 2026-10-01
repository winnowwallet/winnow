import Foundation
import LightningCore
import WalletCore

extension PeerFixture {
    /// Public-node diagnostic for LSPS2: reads the fee menu and, with an
    /// amount, reserves an intercept scid for an invoice nobody is given.
    /// It never sends funds; the reservation expires unused.
    static func probeLSPS2(_ args: [String]) async throws {
        guard [4, 5].contains(args.count), let port = UInt16(args[2]), let peer = Data(hex: args[3]) else {
            throw LightningError.invalidMessage
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "winnow-lsps2-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try LightningEngine(chain: NetworkParams.mainnet.genesisHash,
            journal: FileLightningJournal(directory: root, key: Data(repeating: 42, count: 32)))
        // Diagnostic never supplies funding/signatures; not a mainnet sync receipt.
        try await engine.chainCaughtUp()
        let session = LightningPeerSession(engine: engine, peer: peer, host: args[1], port: port,
                                           features: .jitClient, onEvents: { _ in })
        defer { Task { await session.stop() } }
        let features = try await session.start()
        let now = UInt64(Date().timeIntervalSince1970)
        let menu = try await session.jitMenu(token: "Winnow", now: now)
        try emit(["status": "menu", "peer": peer.hex, "features": features.bits.sorted().map(String.init).joined(separator: ","),
                  "offers": String(menu.offers.count),
                  "terms": menu.offers.map { offer in
                      "min_fee_msat=\(offer.minFeeMsat) ppm=\(offer.params.proportional) "
                          + "payment_msat=\(offer.minPaymentMsat)...\(offer.maxPaymentMsat) "
                          + "min_lifetime=\(offer.params.minLifetime) max_client_to_self_delay=\(offer.params.maxClientToSelfDelay) "
                          + "valid_until=\(offer.params.validUntil)"
                  }.joined(separator: " | ")])
        guard args.count == 5, let amountSat = UInt64(args[4]) else { await session.stop(); return }
        let quote = try menu.cheapest(paymentMsat: amountSat * 1000, now: now)
        let purchase = try await session.jitBuy(quote.offer, paymentSizeMsat: amountSat * 1000)
        let validated = try purchase.validated()
        try emit(["status": "unpaid-reservation-validated", "payment_msat": String(amountSat * 1000),
                  "opening_fee_msat": String(quote.feeMsat), "jit_channel_scid": purchase.jitChannelScid,
                  "scid": String(validated.scid), "lsp_cltv_expiry_delta": String(validated.delta),
                  "client_trusts_lsp": String(purchase.clientTrustsLsp ?? false), "payment": "never authorized or sent"])
        await session.stop()
    }
}
