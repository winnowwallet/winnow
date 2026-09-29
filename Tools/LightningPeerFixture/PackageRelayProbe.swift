import Foundation
import WalletCore

extension PeerFixture {
    /// Host-only driver of the production Bitcoin pool and broadcaster. The
    /// parent is served first, so Core must reconsider it with the later child.
    static func probePackageRelay(_ args: [String]) async throws {
        guard args.count == 6, let port = UInt16(args[2]), let parent = Data(hex: args[3]), let child = Data(hex: args[4]) else {
            throw WireError.malformed("relay-package host port parent child storage")
        }
        let pool = PeerPool(params: .regtest, peerCount: 1, manualPeers: [.init(host: args[1], port: port)],
            relayPreference: true, seedResolver: .init { _, _, _ in [] })
        await pool.start()
        guard await pool.connectedPeers().count == 1 else { throw PeerError.notConnected }
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: URL(fileURLWithPath: args[5]), rebroadcastBaseInterval: .seconds(3600))
        do {
            let parentID = try await broadcaster.broadcast(parent)
            try await waitForServed([parentID], broadcaster: broadcaster)
            try emit(["stage": "parent-served", "parent": parentID.hex])
            guard readLine() != nil else { throw PeerError.disconnected("probe control closed") }
            let ids = try await broadcaster.broadcastPackage(parent: parent, child: child)
            try await waitForServed(ids, broadcaster: broadcaster)
            try emit(["stage": "package-served", "parent": ids[0].hex, "child": ids[1].hex])
            while let line = readLine() {
                let input = try JSONDecoder().decode([String: String].self, from: Data(line.utf8))
                if input["command"] == "finish" { break }
                guard input["command"] == "replace", let raw = input["transaction"].flatMap(Data.init(hex:)) else {
                    throw WireError.malformed("probe expects replace or finish")
                }
                let id = try await broadcaster.broadcast(raw)
                try await waitForServed([id], broadcaster: broadcaster)
                try emit(["stage": "replacement-served", "transaction": id.hex])
            }
            await broadcaster.shutdown(); await pool.stop()
            try emit(["stage": "finished"])
        } catch {
            await broadcaster.shutdown(); await pool.stop()
            throw error
        }
    }
    private static func waitForServed(_ ids: [Data], broadcaster: TxBroadcaster) async throws {
        let deadline = ContinuousClock.now + .seconds(40)
        var remaining = Set(ids)
        while !remaining.isEmpty {
            for id in remaining where await broadcaster.wasServed(id) { remaining.remove(id) }
            guard ContinuousClock.now < deadline else { throw PeerError.timeout }
            if !remaining.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
        }
    }
}
