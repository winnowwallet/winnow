import Foundation
import Testing
import TestSupport
@testable import WalletCore

@Suite("Bounded parent and child package relay", .timeLimit(.minutes(2)))
struct TxPackageRelayTests {
    private func pair() -> (Transaction, Transaction) {
        let parent = makeFakeSegwitTx()
        var child = parent
        child.inputs[0].previousOutput = .init(txid: parent.txid, vout: 0)
        child.outputs[0].value -= 100
        return (parent, child)
    }

    /// Core rejects a low-fee parent alone, then asks for it again once it has
    /// the child paying for both. Each distinct signed child allows exactly one
    /// more serving of the parent; repeated requests stay bounded.
    @Test("a rejected parent can be supplied once more after its child, with duplicate requests bounded")
    func reconsiderParent() async throws {
        let node = LoopbackNode(params: .signet)
        try await node.start()
        let pool = PeerPool(params: .signet, peerCount: 1, manualPeers: [await node.endpoint])
        await pool.start()
        let broadcaster = try TxBroadcaster(pool: pool, rebroadcastBaseInterval: .seconds(3600))
        let (parent, child) = pair()
        _ = try await broadcaster.broadcast(parent.serialized(includeWitness: true))
        _ = await node.nextMessage(command: "inv")
        let request = PeerMessage.getdata(.init([.init(type: .witnessTx, hash: parent.txid)]))
        try await node.send(request)
        #expect(await node.nextMessage(command: "tx") == .tx(parent))
        try await node.send(request)
        #expect(await node.nextMessage(command: "tx", timeout: .milliseconds(100)) == nil)

        let ids = try await broadcaster.broadcastPackage(parent: parent.serialized(includeWitness: true),
                                                         child: child.serialized(includeWitness: true))
        #expect(ids == [parent.txid, child.txid])
        #expect(await node.nextMessage(command: "inv") == .inv(.init([.init(type: .tx, hash: child.txid)])),
                "announced as MSG_TX: BIP144's witness flag belongs in getdata")
        _ = await node.nextMessage(command: "inv")
        try await node.send(.getdata(.init([.init(type: .witnessTx, hash: child.txid)])))
        #expect(await node.nextMessage(command: "tx") == .tx(child))
        try await node.send(.getdata(.init([.init(type: .witnessTx, hash: parent.txid),
                                            .init(type: .witnessTx, hash: parent.txid)])))
        #expect(await node.nextMessage(command: "tx") == .tx(parent))
        try await node.send(request)
        #expect(await node.nextMessage(command: "tx", timeout: .milliseconds(100)) == nil)

        var replacement = child
        replacement.outputs[0].value -= 100
        _ = try await broadcaster.broadcast(replacement.serialized(includeWitness: true))
        _ = await node.nextMessage(command: "inv")
        try await node.send(.getdata(.init([.init(type: .witnessTx, hash: replacement.txid)])))
        #expect(await node.nextMessage(command: "tx") == .tx(replacement))
        try await node.send(request)
        #expect(await node.nextMessage(command: "tx") == .tx(parent),
                "a distinct signed child permits one further parent reconsideration")
        try await node.send(request)
        #expect(await node.nextMessage(command: "tx", timeout: .milliseconds(100)) == nil)
        await broadcaster.shutdown()
        await pool.stop()
        await node.stop()
    }

    @Test("the package is durable together and cannot substitute an existing parent's witness")
    func durableAndBound() async throws {
        let url = tempFileURL("package.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pool = PeerPool(params: .signet, peerCount: 0)
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: url)
        let (parent, child) = pair()
        let ids = try await broadcaster.broadcastPackage(parent: parent.serialized(includeWitness: true),
                                                         child: child.serialized(includeWitness: true))
        let reopened = try TxBroadcaster(pool: pool, storageURL: url)
        #expect(Set(await reopened.pendingTxids) == Set(ids))
        var substituted = parent
        substituted.inputs[0].witness[0].append(1)
        await #expect(throws: (any Error).self) {
            try await reopened.broadcastPackage(parent: substituted.serialized(includeWitness: true),
                                                child: child.serialized(includeWitness: true))
        }
        await #expect(throws: (any Error).self) {
            try await reopened.broadcastPackage(parent: child.serialized(includeWitness: true),
                                                child: parent.serialized(includeWitness: true))
        }
        #expect(Set(await reopened.pendingTxids) == Set(ids))
        await broadcaster.shutdown()
        await reopened.shutdown()
    }

    @Test("periodic relay after restart reconstructs dependencies from durable signed bytes")
    func restartPeriodicRelay() async throws {
        let url = tempFileURL("package-restart.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let offline = PeerPool(params: .signet, peerCount: 0)
        let saved = try TxBroadcaster(pool: offline, storageURL: url, rebroadcastBaseInterval: .milliseconds(100))
        let (parent, child) = pair()
        _ = try await saved.broadcastPackage(parent: parent.serialized(includeWitness: true),
                                             child: child.serialized(includeWitness: true))
        await saved.shutdown()
        let node = LoopbackNode(params: .signet)
        try await node.start()
        let pool = PeerPool(params: .signet, peerCount: 1, manualPeers: [await node.endpoint])
        await pool.start()
        let reopened = try TxBroadcaster(pool: pool, storageURL: url, rebroadcastBaseInterval: .seconds(3600))
        let first = try #require(await node.nextMessage(command: "inv"))
        let second = try #require(await node.nextMessage(command: "inv"))
        guard case let .inv(firstInv) = first, case let .inv(secondInv) = second else {
            Issue.record("periodic relay must announce both restored transactions")
            await reopened.shutdown()
            await pool.stop()
            await node.stop()
            return
        }
        #expect(Set((firstInv.vectors + secondInv.vectors).map(\.hash)) == Set([parent.txid, child.txid]))
        try await node.send(.getdata(.init([.init(type: .witnessTx, hash: parent.txid)])))
        #expect(await node.nextMessage(command: "tx") == .tx(parent))
        try await node.send(.getdata(.init([.init(type: .witnessTx, hash: child.txid)])))
        #expect(await node.nextMessage(command: "tx") == .tx(child))
        try await node.send(.getdata(.init([.init(type: .witnessTx, hash: parent.txid)])))
        #expect(await node.nextMessage(command: "tx") == .tx(parent),
                "a restored child still allows its parent one more serving")
        await reopened.shutdown()
        await pool.stop()
        await node.stop()
    }
}
