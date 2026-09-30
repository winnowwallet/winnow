import Foundation
import Network
import WalletCore
import XCTest
@testable import LightningCore

private final class SessionJournal: LightningJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    init(snapshot: Data? = nil) { bytes = snapshot }
    func load() -> Data? { lock.withLock { bytes } }
    func store(_ snapshot: Data) { lock.withLock { bytes = snapshot } }
}

/// A real localhost BOLT 8 peer, with no Bitcoin funding or external service.
private actor SessionPeer {
    let secret = Data(repeating: 2, count: 32)
    private let listener: NWListener
    private var connection: NWConnection?
    private var transport: LightningTransport?
    private var messages: [Data] = []

    init() throws { listener = try NWListener(using: .tcp) }

    func listen() async throws -> UInt16 {
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        let listener = self.listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "winnow.test.lightning.listener"))
        }
    }
    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: DispatchQueue(label: "winnow.test.lightning.peer"))
    }
    func handshake(features: LightningFeatures = .channelOpening,
                   following: [LightningWire.Message] = [],
                   beforeInitialization: @Sendable () async throws -> Void = {}) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while connection == nil {
            guard ContinuousClock.now < deadline else { throw LightningError.closed }
            try await Task.sleep(for: .milliseconds(10))
        }
        let handshake = try LightningHandshake(role: .responder, localSecret: secret)
        let actOne = try await exact(50)
        try await write(XCTUnwrap(handshake.receive(actOne).reply))
        let actThree = try await exact(66)
        transport = try XCTUnwrap(handshake.receive(actThree).transport)
        _ = try LightningFeatures.readInitialization(await receive())
        try await beforeInitialization()
        // One write makes the eager peer's Init and channel replay available
        // together; it does not depend on a timing delay or another process.
        let transport = try XCTUnwrap(transport)
        let bytes = try ([features.initialization()] + following).reduce(into: Data()) {
            $0.append(try transport.encrypt($1.bytes))
        }
        try await write(bytes)
    }
    func send(_ message: LightningWire.Message) async throws {
        try await write(XCTUnwrap(transport).encrypt(message.bytes))
    }
    func receive() async throws -> LightningWire.Message {
        while messages.isEmpty {
            messages.append(contentsOf: try XCTUnwrap(transport).receive(await read(maximum: 65_536)))
        }
        return try .init(bytes: messages.removeFirst())
    }
    func disconnect() {
        connection?.cancel(); transport?.close()
        connection = nil; transport = nil; messages.removeAll()
    }
    func close() { disconnect(); listener.cancel() }
    private func exact(_ count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count { bytes.append(try await read(maximum: count - bytes.count)) }
        return bytes
    }
    private func read(maximum: Int) async throws -> Data {
        let connection = try XCTUnwrap(connection)
        let timeout = Task { try await Task.sleep(for: .seconds(3)); connection.cancel() }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: LightningError.closed) }
            }
        }
    }
    private func write(_ bytes: Data) async throws {
        let connection = try XCTUnwrap(connection)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

final class PeerSessionTests: XCTestCase, @unchecked Sendable {
    func testChainScanKeepsControlTrafficAliveAndDefersChannelProcessing() async throws {
        let remote = try SessionPeer(), port = try await remote.listen()
        let peer = try ChannelKeys.publicKey(secret: remote.secret)
        let chain = Data(repeating: 7, count: 32)
        let engine = try LightningEngine(chain: chain, journal: SessionJournal())
        try await engine.chainCaughtUp()
        let session = LightningPeerSession(engine: engine, peer: peer, host: "127.0.0.1", port: port, onEvents: { _ in })
        let handshake = Task { try await remote.handshake() }
        do {
            try await session.start(); try await handshake.value
            await engine.chainDisconnected()
            let terms = try ChannelSecrets().terms(capacity: 100_000)
            let open = ChannelNegotiation.Open(chain: chain, temporaryID: Data(repeating: 3, count: 32),
                capacity: 100_000, pushMsat: 0, feePerKW: 1000, terms: terms)
            try await remote.send(open.message())
            var warning = LightningWire.Writer(); warning.append(Data(repeating: 0, count: 32))
            warning.u16(4); warning.append(Data("wait".utf8))
            try await remote.send(.init(type: 1, payload: warning.data))
            var ping = LightningWire.Writer(); ping.u16(2); ping.u16(0)
            try await remote.send(.init(type: 18, payload: ping.data))
            let pong = try await remote.receive()
            XCTAssertEqual(pong.type, 19)
            XCTAssertEqual(pong.payload, Data([0, 2, 0, 0]))
            let pausedChannels = await engine.channels(), warningText = await session.lastPeerWarning
            XCTAssertTrue(pausedChannels.isEmpty, "No channel decision may be made while the chain is unverified")
            XCTAssertEqual(warningText, "Provider warning: wait")
            try await engine.chainCaughtUp()
            let accepted = try await remote.receive()
            XCTAssertEqual(accepted.type, 33, "The queued open must resume after verification, without another inbound message")
            let channels = await engine.channels(), status = await session.status
            XCTAssertEqual(channels.first?.phase, .accepted)
            XCTAssertEqual(status, .connected)
            try await remote.send(.init(type: 17, payload: warning.data))
            let deadline = ContinuousClock.now + .seconds(3)
            while await session.status == .connected, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let failed = await session.status
            XCTAssertEqual(failed, .failed("Provider error: wait"))
            let retained = await engine.channels()
            XCTAssertEqual(retained.first?.id, channels.first?.id)
            await session.stop(); await remote.close()
        } catch {
            await session.stop(); await remote.close(); handshake.cancel(); throw error
        }
    }
}

extension PeerSessionTests {
    func testCanceledRouteQueryDrainsAndKeepsPingAliveBeforeAnotherQuery() async throws {
        let remote = try SessionPeer(), port = try await remote.listen(), peer = try ChannelKeys.publicKey(secret: remote.secret)
        let chain = NetworkParams.regtest.genesisHash
        let engine = try LightningEngine(chain: chain, journal: SessionJournal())
        try await engine.chainCaughtUp(height: 100)
        let session = LightningPeerSession(engine: engine, peer: peer, host: "127.0.0.1", port: port, onEvents: { _ in })
        let features = try LightningFeatures(bits: LightningFeatures.channelOpening.bits.union([7]))
        let handshake = Task { try await remote.handshake(features: features) }
        let now = UInt64(Date().timeIntervalSince1970)
        let invoice = try Bolt11Invoice.encode(network: .regtest, amountMsat: 5000, hash: Data(repeating: 1, count: 32),
            secret: Data(repeating: 2, count: 32), nodeSecret: Data(repeating: 3, count: 32), route: nil, timestamp: now)
        do {
            try await session.start(); try await handshake.value
            let first = Task { try await session.invoiceRoute(invoice: invoice, network: .regtest, amountMsat: 5000, feeLimitMsat: 1000) }
            let query = try await remote.receive(); XCTAssertEqual(query.type, 263)
            do { _ = try await session.invoiceRoute(invoice: invoice, network: .regtest, amountMsat: 5000, feeLimitMsat: 1000); XCTFail("Queries overlapped") } catch {}
            first.cancel(); do { _ = try await first.value; XCTFail() } catch is CancellationError {}
            await engine.chainDisconnected()
            var ping = LightningWire.Writer(); ping.u16(2); ping.u16(0)
            try await remote.send(.init(type: 18, payload: ping.data))
            let pong = try await remote.receive(); XCTAssertEqual(pong.type, 19)
            var reply = LightningWire.Writer(); reply.append(chain); reply.u32(0); reply.u32(101); reply.u8(1); reply.u16(1); reply.u8(0)
            try await remote.send(.init(type: 264, payload: reply.data))
            let deadline = ContinuousClock.now + .seconds(3)
            while await session.gossipQuery != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let remaining = await session.gossipQuery; XCTAssertNil(remaining)
            try await engine.chainCaughtUp(height: 100)
            let second = Task { try await session.invoiceRoute(invoice: invoice, network: .regtest, amountMsat: 5000, feeLimitMsat: 1000) }
            let next = try await remote.receive(); XCTAssertEqual(next.type, 263)
            let deadlineTime = UInt64(Date().timeIntervalSince1970) + 700
            await session.testRoutingProgress(now: deadlineTime)
            await session.checkRoutingTimeout(now: deadlineTime)
            do { _ = try await second.value; XCTFail("Timeout kept continuation alive") } catch {}
            let status = await session.status, channels = await engine.channels(), payments = await engine.payments()
            XCTAssertEqual(status, .stopped); XCTAssertTrue(channels.isEmpty); XCTAssertTrue(payments.isEmpty)
            await remote.close()
        } catch { await session.stop(); await remote.close(); handshake.cancel(); throw error }
    }
}

/// The funded snapshot is created by the same opening, signature and
/// confirmation transitions as ChannelEngineTests.pair(), with zero payments.
private struct SessionRestartFixture: Sendable {
    let engine: LightningEngine
    let peer, channelID: Data
    let reestablish: LightningWire.Message
}

private extension PeerSessionTests {
    func fundedRestartFixture() async throws -> SessionRestartFixture {
        let chain = Data(repeating: 7, count: 32)
        let aliceKey = try ChannelKeys.publicKey(secret: Data(repeating: 1, count: 32))
        let bobKey = try ChannelKeys.publicKey(secret: Data(repeating: 2, count: 32))
        let aliceJournal = SessionJournal(), bobJournal = SessionJournal()
        let alice = try LightningEngine(chain: chain, nodeSecret: Data(repeating: 1, count: 32), journal: aliceJournal)
        let bob = try LightningEngine(chain: chain, nodeSecret: Data(repeating: 2, count: 32), journal: bobJournal)
        for (engine, peer) in [(alice, bobKey), (bob, aliceKey)] {
            try await engine.chainCaughtUp()
            try await engine.peerInitialized(peer, features: .channelOpening)
        }
        let temporary = try await alice.openChannel(peer: bobKey, capacitySat: 100_000, feePerKW: 1000, format: .staticRemoteKey)
        _ = try await bob.receive(peer: aliceKey, message: alice.pendingMessages(peer: bobKey)[0].message)
        let events = try await alice.receive(peer: bobKey, message: bob.pendingMessages(peer: aliceKey)[0].message)
        guard case .fundingRequired(_, _, let script) = try XCTUnwrap(events.first) else { throw LightningError.invalidState }
        let funding = Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: Data(repeating: 9, count: 32), vout: 1),
            scriptSig: Data(), sequence: .max, witness: [Data([1])])], outputs: [.init(value: 100_000, scriptPubKey: script)], locktime: 0)
        try await alice.provideFunding(temporaryID: temporary, peer: bobKey, transaction: funding, output: 0)
        _ = try await bob.receive(peer: aliceKey, message: alice.pendingMessages(peer: bobKey)[0].message)
        _ = try await alice.receive(peer: bobKey, message: bob.pendingMessages(peer: aliceKey)[0].message)
        let aliceChannels = await alice.channels()
        let channelID = try XCTUnwrap(aliceChannels.first?.id)
        for (engine, peer) in [(alice, bobKey), (bob, aliceKey)] {
            _ = try await engine.fundingConfirmed(channelID: channelID, peer: peer, transaction: funding, confirmations: 3)
        }
        let alicePending = try await alice.pendingMessages(peer: bobKey)
        let bobPending = try await bob.pendingMessages(peer: aliceKey)
        let aReady = try XCTUnwrap(alicePending.first { $0.message.type == 36 })
        let bReady = try XCTUnwrap(bobPending.first { $0.message.type == 36 })
        _ = try await alice.receive(peer: bobKey, message: bReady.message)
        _ = try await bob.receive(peer: aliceKey, message: aReady.message)
        let snapshot = try XCTUnwrap(aliceJournal.load())
        let saved = try XCTUnwrap(JSONDecoder().decode(LightningEngine.State.self, from: snapshot).channels.first)
        XCTAssertEqual(saved.phase, .ready); XCTAssertEqual(saved.localNumber, 0); XCTAssertEqual(saved.remoteNumber, 0)
        await bob.peerDisconnected(aliceKey)
        try await bob.peerInitialized(aliceKey, features: .channelOpening)
        let bobReplay = try await bob.pendingMessages(peer: aliceKey)
        let reestablish = try XCTUnwrap(bobReplay.first { $0.message.type == 136 })
        let restored = try LightningEngine(chain: chain, journal: SessionJournal(snapshot: snapshot))
        try await restored.chainCaughtUp()
        return SessionRestartFixture(engine: restored, peer: bobKey, channelID: channelID, reestablish: reestablish.message)
    }

    func assertRestartReplay(_ remote: SessionPeer, fixture: SessionRestartFixture) async throws {
        let first = try await remote.receive()
        XCTAssertEqual(first.type, 136, "Our reestablish must reach the wire before the peer can acknowledge it")
        guard first.type == 136 else { return }
        XCTAssertEqual(Data(first.payload.prefix(32)), fixture.channelID)
        let ready = try await remote.receive()
        XCTAssertEqual(ready.type, 36, "Validated peer reestablishment releases channel_ready after our replay")
        XCTAssertEqual(Data(ready.payload.prefix(32)), fixture.channelID)
        let channels = await fixture.engine.channels()
        XCTAssertEqual(channels.first?.phase, .ready)
        XCTAssertNotNil(channels.first?.signedCommitment)
        let pending = try await fixture.engine.pendingMessages(peer: fixture.peer)
        XCTAssertFalse(pending.contains { $0.message.type == 136 })
    }
}

extension PeerSessionTests {
    func testEagerPeerReestablishmentCannotAcknowledgeOurUnpublishedReplay() async throws {
        let fixture = try await fundedRestartFixture(), remote = try SessionPeer(), port = try await remote.listen()
        let session = LightningPeerSession(engine: fixture.engine, peer: fixture.peer, host: "127.0.0.1", port: port, onEvents: { _ in })
        let handshake = Task { try await remote.handshake(following: [fixture.reestablish]) }
        do {
            try await session.start(); try await handshake.value
            try await assertRestartReplay(remote, fixture: fixture)
            await session.stop(); await remote.close()
        } catch { await session.stop(); await remote.close(); handshake.cancel(); throw error }
    }

    func testPausedInitialPublicationKeepsPingAliveAndReplaysBeforePeerAcknowledgement() async throws {
        let fixture = try await fundedRestartFixture(), remote = try SessionPeer(), port = try await remote.listen()
        let session = LightningPeerSession(engine: fixture.engine, peer: fixture.peer, host: "127.0.0.1", port: port, onEvents: { _ in })
        var ping = LightningWire.Writer(); ping.u16(2); ping.u16(0)
        let pingMessage = try LightningWire.Message(type: 18, payload: ping.data)
        let handshake = Task {
            try await remote.handshake(following: [fixture.reestablish, pingMessage]) {
                await fixture.engine.chainDisconnected()
            }
        }
        do {
            try await session.start(); try await handshake.value
            // Receiving this pong proves the earlier 136 reached the ordered
            // incoming queue while initial publication was chain-paused.
            let pong = try await remote.receive()
            XCTAssertEqual(pong.type, 19); XCTAssertEqual(pong.payload, Data([0, 2, 0, 0]))
            let current = await fixture.engine.chainIsCurrent
            XCTAssertFalse(current)
            try await fixture.engine.chainCaughtUp()
            try await assertRestartReplay(remote, fixture: fixture)
            await session.stop(); await remote.close()
        } catch { await session.stop(); await remote.close(); handshake.cancel(); throw error }
    }

    func testStoppedInitializationCannotActivateReaderOrContaminateNextGeneration() async throws {
        let fixture = try await fundedRestartFixture(), remote = try SessionPeer(), port = try await remote.listen()
        let session = LightningPeerSession(engine: fixture.engine, peer: fixture.peer, host: "127.0.0.1", port: port, onEvents: { _ in })
        let initialized = expectation(description: "Peer received authenticated client Init")
        let gate = SessionInitializationGate()
        let handshake = Task {
            try await remote.handshake(following: [fixture.reestablish]) {
                initialized.fulfill()
                try await gate.wait()
            }
        }
        let starting = Task { try await session.start() }
        do {
            await fulfillment(of: [initialized], timeout: 3)
            await session.stop()
            do { _ = try await starting.value; XCTFail("Stopped startup returned success") } catch {}
            let stopped = await session.status; XCTAssertEqual(stopped, .stopped)
            await gate.open(); _ = try? await handshake.value
            await remote.disconnect()
            let nextHandshake = Task { try await remote.handshake(following: [fixture.reestablish]) }
            do {
                try await session.start(); try await nextHandshake.value
                try await assertRestartReplay(remote, fixture: fixture)
                let connected = await session.status; XCTAssertEqual(connected, .connected)
            } catch { nextHandshake.cancel(); throw error }
            await session.stop(); await remote.close()
        } catch {
            await gate.open(); await session.stop(); await remote.close()
            starting.cancel(); handshake.cancel(); throw error
        }
    }
}

/// An explicit bounded gate for cancellation, entirely within the test peer.
/// Startup ordering tests need no production hook or artificial sleep.
private actor SessionInitializationGate {
    private var opened = false
    private var waiting: CheckedContinuation<Void, any Error>?
    private var expiry: Task<Void, Never>?

    func wait() async throws {
        if opened { return }
        try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            expiry = Task {
                do { try await Task.sleep(for: .seconds(3)); expire() } catch {}
            }
        }
    }
    func open() {
        opened = true; expiry?.cancel(); expiry = nil
        waiting?.resume(); waiting = nil
    }
    private func expire() {
        waiting?.resume(throwing: LightningError.closed); waiting = nil; expiry = nil
    }
}

private extension LightningPeerSession {
    func testRoutingProgress(now: UInt64) { gossipQuery?.lastProgress = now }
}

extension PeerSessionTests {
    func testOrdinaryOfferAndInvoiceRoutesUseFreshCacheAndFailAfterDisconnect() async throws {
        let remote = try SessionPeer(), port = try await remote.listen(), peer = try ChannelKeys.publicKey(secret: remote.secret)
        let chain = NetworkParams.regtest.genesisHash, now = UInt64(Date().timeIntervalSince1970)
        let target = try ChannelKeys.publicKey(secret: Data(repeating: 3, count: 32))
        let recipient = try ChannelKeys.publicKey(secret: Data(repeating: 4, count: 32))
        let path = try OnionMessage.path(nodes: [target, recipient], context: Data(repeating: 5, count: 32), authenticationKey: Data(repeating: 6, count: 32))
        let offer = try LightningOffer(bytes: Bolt12Encoding.serialize([.init(type: 2, value: chain), .init(type: 10, value: Data("Cached routing".utf8)),
            .init(type: 16, value: path.encoded()), .init(type: 22, value: recipient)]))
        let request = try InvoiceRequest(offer: offer, chain: chain, amountMsat: 5000, now: now, metadata: Data(repeating: 7, count: 32), payerSecret: Data(repeating: 8, count: 32))
        let info = try StaticInvoice.PayInfo(baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 58, minimumMsat: 1000, maximumMsat: 100_000, features: .init(bytes: Data()))
        let invoice = try Bolt12Invoice(request: request, paths: [path], payInfo: [info], paymentHash: Data(repeating: 9, count: 32), createdAt: now, signingSecret: Data(repeating: 4, count: 32))
        let engine = try LightningEngine(chain: chain, journal: SessionJournal())
        try await engine.chainCaughtUp(height: 100)
        let session = LightningPeerSession(engine: engine, peer: peer, host: "127.0.0.1", port: port, onEvents: { _ in })
        let handshake = Task { try await remote.handshake() }
        do {
            try await session.start(); try await handshake.value
            let direct = try LightningOffer(bytes: Bolt12Encoding.serialize([.init(type: 2, value: chain), .init(type: 22, value: peer)]))
            let directPath = try await session.ordinaryOfferPath(offer: direct); XCTAssertEqual(directPath, [peer])
            var graph = LightningRoutingGraph(chain: chain); graph.synchronizedAt = now
            graph.channels[456] = .init(nodes: [peer, target], policies: [0: .init(hop: .init(peer: peer, shortChannelID: 456, baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 40), timestamp: UInt32(now), minimum: 1000, maximum: 100_000, disabled: false)])
            await engine.cacheRouting(graph)
            let via = try await session.ordinaryOfferPath(offer: offer); XCTAssertEqual(via, [peer])
            let route = try await session.ordinaryInvoiceRoute(invoice: invoice, feeLimitMsat: 2000)
            XCTAssertEqual(route.hops.map(\.shortChannelID), [456])
            XCTAssertEqual(try route.quote(invoice: invoice, feeLimitMsat: 2000, height: 100, maximumDelta: 144).feeMsat, 2000)
            do { _ = try await session.ordinaryInvoiceRoute(invoice: invoice, feeLimitMsat: 1999); XCTFail("Fee cap must hold across cached routing") } catch {}
            graph.synchronizedAt = now - 601; await engine.cacheRouting(graph)
            do { _ = try await session.ordinaryOfferPath(offer: offer); XCTFail("Stale gossip needs a fresh query") } catch {}
            let payments = await engine.payments(); XCTAssertTrue(payments.isEmpty)
            await session.stop(); await remote.close()
            do { _ = try await session.ordinaryOfferPath(offer: offer); XCTFail("Disconnected session cannot resolve routes") } catch {}
            do { _ = try await session.ordinaryInvoiceRoute(invoice: invoice, feeLimitMsat: 2000); XCTFail() } catch {}
        } catch { await session.stop(); await remote.close(); handshake.cancel(); throw error }
    }
}
