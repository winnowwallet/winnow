import Foundation
import LightningCore
import WalletCore

/// Records callbacks from the production foreground session used by the app.
actor AutomaticPeer {
    var events: [[String: String]] = []
    func record(_ received: [LightningEngine.Event]) { events += received.map { PeerFixture.encode([$0]) } }
    func drain() throws -> String {
        let encoded = try JSONSerialization.data(withJSONObject: events, options: [.sortedKeys])
        events.removeAll(); return String(decoding: encoded, as: UTF8.self)
    }
}

extension PeerFixture {
    static func runAutomatic(engine: LightningEngine, peer: Data, host: String, port: UInt16) async throws {
        let buffer = AutomaticPeer()
        let session = LightningPeerSession(engine: engine, peer: peer, host: host, port: port) { await buffer.record($0) }
        let features = try await session.start()
        try emit(["status": "initialized", "node_id": try await engine.nodeID().hex, "peer_features": features.bytes.hex])
        while let line = readLine() {
            let input = try JSONDecoder().decode([String: String].self, from: Data(line.utf8))
            if case .failed(let reason) = await session.status,
               !["scan_begin", "scan_block", "height", "snapshot", "payment", "events", "force_close"].contains(input["command"]) {
                throw NSError(domain: reason, code: 1)
            }
            let output: [String: String]
            if input["command"] == "events" { output = ["events": try await buffer.drain()] }
            else { output = try await execute(input, engine: engine, connection: nil, peer: peer) }
            try await session.flush()
            try emit(output)
        }
        await session.stop()
    }
    static func asyncCommand(_ input: [String: String], engine: LightningEngine, peer: Data) async throws -> [String: String] {
        let now = UInt64(Date().timeIntervalSince1970)
        switch input["command"] {
        case "scan_begin":
            await engine.chainDisconnected()
            if await engine.chainStatus().rescanRequired {
                guard let genesis = Data(hex: input["genesis"] ?? "") else { throw LightningError.invalidMessage }
                try await engine.blocksDisconnected(to: 0, hash: genesis)
            }
            return ["next": String(await engine.chainStatus().nextHeight)]
        case "scan_block":
            guard let height = UInt32(input["height"] ?? ""), let raw = Data(hex: input["hex"] ?? "") else { throw LightningError.invalidMessage }
            let block = try Block.decode(raw)
            _ = try await engine.scannedBlock(.init(height: height, header: block.header, block: block,
                watchRevision: engine.chainStatus().revision))
            return ["height": String(height)]
        case "height":
            guard let height = UInt32(input["height"] ?? "") else { throw LightningError.invalidMessage }
            try await engine.chainCaughtUp(height: height)
            let events = try await engine.pendingRecoveryBroadcasts().map { encode([$0]) }
            return ["height": String(height), "chain_events": String(decoding: try JSONSerialization.data(withJSONObject: events), as: UTF8.self)]
        case "async_pay":
            guard let id = Data(hex: input["id"] ?? ""), let channel = Data(hex: input["channel"] ?? ""), let intro = Data(hex: input["introduction"] ?? ""),
                  let scid = UInt64(input["scid"] ?? ""), let amount = UInt64(input["amount"] ?? ""), let fee = UInt64(input["fee"] ?? "") else { throw LightningError.invalidMessage }
            let route = try AsyncPaymentRoute(holdingPeer: peer, introduction: intro, shortChannelID: scid, baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 48)
            let request = try LightningEngine.OfferPayment(id: id, channelID: channel, offer: LightningOffer(string: input["offer"] ?? ""),
                amountMsat: amount, feeLimitMsat: fee, maximumDelta: 2016, route: route)
            let payment = try await engine.payOffer(request, now: now)
            return ["id": payment.id.hex, "hash": payment.hash.hex, "phase": payment.phase.rawValue]
        case "async_register":
            guard let id = Data(hex: input["id"] ?? ""), let path = Data(hex: input["path"] ?? ""), let scid = UInt64(input["scid"] ?? ""),
                  let server = try BlindedPath.decodeList(path).first else { throw LightningError.invalidMessage }
            try await engine.registerReceiveOffer(.init(id: id, provider: peer, serverPath: server, inboundShortChannelID: scid,
                baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 48, maximumMsat: 50_000_000), now: now)
            return ["phase": "registering"]
        case "async_offer":
            guard let receive = try await engine.receiveOffers(now: now).first else { return ["phase": "registering"] }
            return ["phase": "ready", "offer": receive.offer.string, "id": receive.id.hex]
        default: throw LightningError.invalidMessage
        }
    }
}
