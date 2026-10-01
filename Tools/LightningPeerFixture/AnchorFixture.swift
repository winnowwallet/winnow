import Foundation
import LightningCore
import WalletCore

extension PeerFixture {
    static func anchorCommand(_ input: [String: String], engine: LightningEngine, peer: Data) async throws -> [String: String] {
        switch input["command"] {
        case "anchor_quote":
            guard let id = Data(hex: input["id"] ?? ""), let channel = Data(hex: input["channel"] ?? ""),
                  let destination = Data(hex: input["destination"] ?? ""), let text = input["coins"],
                  let rate = Double(input["rate"] ?? ""), let limit = UInt64(input["limit"] ?? "") else { throw LightningError.invalidMessage }
            let coins = try JSONDecoder().decode([WalletUTXO].self, from: Data(text.utf8))
            let quote = try await engine.anchorFeeBumpQuote(id: id, channelID: channel, peer: peer, coins: coins,
                destination: destination, feeRateSatPerVByte: rate, totalFeeLimitSat: limit,
                replacingTxid: input["replacing"].flatMap(Data.init(hex:)))
            return ["quote": String(decoding: try JSONEncoder().encode(quote), as: UTF8.self),
                "transaction": quote.unsignedTransaction.hex, "parent": quote.parentTransaction.hex,
                "fee_sat": String(quote.feeSat), "package_fee_sat": String(quote.packageFeeSat)]
        case "anchor_commit":
            guard let text = input["quote"], let bytes = Data(hex: input["transaction"] ?? "") else { throw LightningError.invalidMessage }
            let quote = try JSONDecoder().decode(AnchorFeeBump.self, from: Data(text.utf8))
            let events = try await engine.commitAnchorFeeBump(quote, peer: peer, walletSignedTransaction: Transaction.decode(bytes))
            guard events.count == 2, case .broadcastClose(_, let parent) = events[0], case .broadcastRecovery(_, let child) = events[1]
            else { throw LightningError.invalidState }
            return ["parent": parent.hex, "child": child.hex]
        default: throw LightningError.invalidMessage
        }
    }
}
