import Foundation
import LightningCore
import WalletCore

extension PeerFixture {
    /// Disposable, read-only node. This exercises the app's production gossip
    /// session, not a reference daemon's getroute RPC. It never opens or pays.
    static func probeInvoiceRoute(_ args: [String]) async throws {
        guard args.count == 7, let port = UInt16(args[2]), let peer = Data(hex: args[3]),
              let network = BitcoinNetwork(rawValue: args[4]), let height = UInt32(args[5]) else { throw LightningError.invalidMessage }
        let root = FileManager.default.temporaryDirectory.appending(path: "winnow-route-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try LightningEngine(chain: NetworkParams.params(for: network).genesisHash,
            journal: FileLightningJournal(directory: root, key: Data(repeating: 42, count: 32)))
        // Diagnostic only; this process never creates financial state.
        try await engine.chainCaughtUp(height: height)
        let session = LightningPeerSession(engine: engine, peer: peer, host: args[1], port: port, onEvents: { _ in })
        do {
            _ = try await session.start()
            let invoice = try Bolt11Invoice.decode(args[6], network: network)
            guard let amount = invoice.amountMsat else { throw LightningError.invalidAmount }
            let route = try await session.invoiceRoute(invoice: args[6], network: network, amountMsat: amount, feeLimitMsat: 50_000)
            let quote = try route.quote(invoice: invoice, amountMsat: amount, feeLimitMsat: 50_000, height: height, maximumDelta: 2016)
            try emit(["route": String(decoding: JSONEncoder().encode(route.hops), as: UTF8.self),
                      "fee_msat": String(quote.feeMsat), "delta": String(quote.delta)])
            await session.stop()
        } catch { await session.stop(); throw error }
    }
}
