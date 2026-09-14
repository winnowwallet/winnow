import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// What one connection may cost in memory and in patience, whatever the peer
/// sends (IR-026, IR-033). A loopback node plays the hostile peer; the
/// client under test is an ordinary `PeerConnection`.
@Suite("Connection bounds")
struct ConnectionBoundsTests {
    private let params = NetworkParams.signet

    private func connected(to node: LoopbackNode, backlogByteLimit: Int = PeerConnection.defaultBacklogByteLimit,
                           pingInterval: Duration = .seconds(60),
                           readIdleTimeout: Duration = .seconds(150)) async throws -> PeerConnection {
        let peer = PeerConnection(endpoint: await node.endpoint, params: params,
                                  backlogByteLimit: backlogByteLimit,
                                  pingInterval: pingInterval, readIdleTimeout: readIdleTimeout)
        try await peer.connect()
        return peer
    }

    @Test("unsolicited blocks and addr are not kept; an announcement is")
    func unsolicitedNotBacklogged() async throws {
        let node = LoopbackNode(params: params)
        try await node.start()
        defer { Task { await node.stop() } }
        let peer = try await connected(to: node)
        defer { Task { await peer.disconnect() } }

        let block = makeSyntheticChain(length: 2).blocks[1]
        for _ in 0 ..< 3 {
            try await node.send(.block(block))
            try await node.send(.addr([]))
        }
        let vector = InventoryVector(type: .witnessTx, hash: Data(repeating: 1, count: 32))
        try await node.send(.inv(InventoryPayload([vector])))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await peer.backlogSize.messages == 1)
        #expect(await peer.isConnected)
    }

    @Test("the backlog is bounded in bytes, not only in messages")
    func backlogByteBudget() async throws {
        let node = LoopbackNode(params: params)
        try await node.start()
        defer { Task { await node.stop() } }
        let limit = 4_000_000
        let peer = try await connected(to: node, backlogByteLimit: limit)
        defer { Task { await peer.disconnect() } }

        // 50,000 vectors is 1.8 MB of payload; three of them exceed the limit.
        let vectors = (0 ..< 50_000).map {
            InventoryVector(type: .witnessTx, hash: Data(repeating: UInt8($0 % 251), count: 32))
        }
        for _ in 0 ..< 3 { try await node.send(.inv(InventoryPayload(vectors))) }
        try await Task.sleep(for: .seconds(1))
        #expect(await peer.backlogSize.bytes <= limit)
        #expect(await peer.backlogSize.messages == 2)
        #expect(await peer.isConnected)
    }

    @Test("a relayed transaction past the standard size is dropped before it is decoded")
    func oversizedTransactionDropped() async throws {
        let node = LoopbackNode(params: params)
        try await node.start()
        defer { Task { await node.stop() } }
        let peer = try await connected(to: node)
        defer { Task { await peer.disconnect() } }
        let seen = EventCollector<String>()
        let events = await peer.events()
        let consumer = Task {
            for try await event in events {
                if case let .message(message) = event { seen.add(message.command) }
            }
        }
        defer { consumer.cancel() }

        let small = makeFakeSegwitTx()
        let big = Transaction(
            version: 2, inputs: small.inputs,
            outputs: [Transaction.Output(value: 1, scriptPubKey: Data(
                repeating: 0x6a, count: PeerConnection.maximumRelayedTransactionBytes))],
            locktime: 0)
        try await node.send(.tx(big))
        try await node.send(.tx(small))
        try await Task.sleep(for: .milliseconds(500))
        #expect(seen.events.filter { $0 == "tx" }.count == 1)
        #expect(await peer.isConnected)
    }

    @Test("a peer that never answers a ping is dropped by the idle deadline")
    func idleDeadlineDropsSilentPeer() async throws {
        let node = LoopbackNode(params: params, answersPings: false)
        try await node.start()
        defer { Task { await node.stop() } }
        // A deadline several pings wide, as in production: a loaded test
        // host must not turn one late pong into a false disconnect.
        let peer = try await connected(to: node, pingInterval: .milliseconds(100),
                                       readIdleTimeout: .seconds(2))
        #expect(await peer.isConnected)
        try await Task.sleep(for: .seconds(3.5))
        #expect(await peer.isConnected == false)
    }

    @Test("a peer that answers pings keeps its seat past the idle deadline")
    func idleDeadlineKeepsLivePeer() async throws {
        let node = LoopbackNode(params: params)
        try await node.start()
        defer { Task { await node.stop() } }
        // A loaded CI host has stalled a loopback pong for over two seconds;
        // the deadline here is the test's own, so give it room (the wallet's
        // is 150 s) and still sleep past it.
        let peer = try await connected(to: node, pingInterval: .milliseconds(200),
                                       readIdleTimeout: .seconds(5))
        defer { Task { await peer.disconnect() } }
        try await Task.sleep(for: .seconds(7))
        #expect(await peer.isConnected)
    }
}
