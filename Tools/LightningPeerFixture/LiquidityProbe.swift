import Foundation
import CryptoKit
import LightningCore
import WalletCore

extension PeerFixture {
    /// Public-node diagnostic. Optional quote creates only an unpaid order.
    /// It never sends funds; any order expires while this temporary peer stops.
    static func probeLSP(_ args: [String]) async throws {
        guard [4, 5].contains(args.count), let port = UInt16(args[2]), let peer = Data(hex: args[3]) else { throw LightningError.invalidMessage }
        let root = FileManager.default.temporaryDirectory.appending(path: "winnow-lsp-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try LightningEngine(chain: NetworkParams.mainnet.genesisHash,
            journal: FileLightningJournal(directory: root, key: Data(repeating: 42, count: 32)))
        // Diagnostic never supplies funding/signatures; not a mainnet sync receipt.
        try await engine.chainCaughtUp()
        let session = LightningPeerSession(engine: engine, peer: peer, host: args[1], port: port, onEvents: { _ in })
        do {
            let features = try await session.start()
            FileHandle.standardError.write(Data("Authenticated provider features: \(features.bits.sorted())\n".utf8))
            let info: LightningLiquidity.Info
            if args.count == 5, let base = URL(string: args[4]) { info = try await LightningLiquidityHTTP(base: base).info() }
            else { info = try await session.liquidityInfo() }
            try emit(["status": "compatible", "peer": peer.hex, "features": features.bytes.hex,
                "minimum_capacity_sat": String(info.minimumCapacitySat),
                "minimum_confirmations": String(info.minRequiredChannelConfirmations)])
            if args.first == "probe-lsp-quote" {
                let purchase = try info.request(capacitySat: info.minimumCapacitySat, token: args.count == 5 ? "Winnow" : "")
                let order: LightningLiquidity.Order
                if args.count == 5, let base = URL(string: args[4]) {
                    order = try await LightningLiquidityHTTP(base: base).order(purchase, nodeID: engine.nodeID())
                } else { order = try await session.liquidityOrder(purchase) }
                let fee = try order.validate(request: purchase, network: .mainnet, now: UInt64(Date().timeIntervalSince1970))
                try emit(["status": "unpaid-quote-validated", "fee_sat": String(fee), "order_id": order.orderId,
                    "minimum_confirmations": String(purchase.requiredChannelConfirmations), "payment": "never authorized or sent"])
            }
            if args.first == "probe-lsp-opening" {
                _ = try await engine.openChannel(peer: peer, capacitySat: 100_000, feePerKW: 1000)
                try await session.flush()
            }
            if ["probe-lsp-stability", "probe-lsp-opening"].contains(args.first) {
                let duration = args.first == "probe-lsp-opening" ? 10 : 60
                var lastWarning: String?
                var rejectedAndReconnected = false
                for second in 1...duration {
                    try await Task.sleep(for: .seconds(1))
                    let status = await session.status
                    if let warning = await session.lastPeerWarning, warning != lastWarning {
                        FileHandle.standardError.write(Data("\(warning)\n".utf8))
                        lastWarning = warning
                    }
                    guard status == .connected else {
                        if args.first == "probe-lsp-opening", !rejectedAndReconnected,
                           case .failed(let reason) = status,
                           await engine.channels().allSatisfy({ $0.phase == .closed }) {
                            try emit(["status": "unfunded-request-rejected", "reason": reason])
                            await session.stop(); try await session.start()
                            _ = try await session.liquidityInfo()
                            rejectedAndReconnected = true
                            continue
                        }
                        throw LightningLiquidityError.provider("Disconnected after \(second) seconds: \(status)")
                    }
                }
                try emit(["status": rejectedAndReconnected ? "rejected-unfunded-request-and-reconnected" : "connected-for-\(duration)-seconds",
                    "payment": "never authorized or sent",
                    "channel_phase": await engine.channels().first?.phase.rawValue ?? "none"])
            }
            await session.stop()
        } catch {
            FileHandle.standardError.write(Data("Provider session status: \(await session.status)\n".utf8))
            await session.stop(); throw error
        }
    }
}
