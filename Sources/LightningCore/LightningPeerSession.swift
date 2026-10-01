import Foundation

/// Foreground transport for one authenticated peer. The engine owns every
/// durable decision; reconnecting rebuilds only Noise and publication cursors.
public actor LightningPeerSession {
    public enum Status: Sendable, Equatable { case stopped, connecting, connected, failed(String) }
    let engine: LightningEngine
    public let peer: Data
    private let host: String, port: UInt16
    private let onEvents: @Sendable ([LightningEngine.Event]) async throws -> Void
    private var connection: LightningConnection?
    private var reader: Task<Void, Never>?, timer: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var sent = Set<UInt64>()
    private var flushing = false
    private var initialChannelPublicationPending = false
    private var stopping = false
    private var starting = false
    private var incoming: [LightningWire.Message] = []
    private var incomingBytes = 0
    private var handlingIncoming = false
    var gossipQuery: LightningGossipQuery?
    var gossipCompletion: CheckedContinuation<LightningRoutingGraph, any Error>?
    var liquidityRequests: [String: CheckedContinuation<Data, any Error>] = [:]
    var peerFeatures: LightningFeatures?
    public private(set) var status: Status = .stopped
    public private(set) var lastPeerWarning: String?

    private let features: LightningFeatures

    public init(engine: LightningEngine, peer: Data, host: String, port: UInt16, features: LightningFeatures = .asyncClient,
                onEvents: @escaping @Sendable ([LightningEngine.Event]) async throws -> Void) {
        self.engine = engine; self.peer = peer; self.host = host; self.port = port; self.features = features; self.onEvents = onEvents
    }
    @discardableResult
    public func start() async throws -> LightningFeatures {
        guard connection == nil, !stopping, !starting else { throw LightningError.invalidState }
        starting = true; defer { starting = false }
        generation &+= 1
        let epoch = generation
        let transport = try await engine.connection(host: host, port: port, peer: peer)
        guard epoch == generation else { throw CancellationError() }
        connection = transport; status = .connecting; sent.removeAll(); lastPeerWarning = nil
        do {
            try await transport.start()
            try await transport.send(self.features.initialization())
            let features = try LightningFeatures.readInitialization(await transport.receive())
            guard epoch == generation else { throw CancellationError() }
            try await engine.peerInitialized(peer, features: features)
            guard epoch == generation else { throw CancellationError() }
            peerFeatures = features
            initialChannelPublicationPending = true
            status = .connected
            reader = Task { await receiveLoop(transport, epoch: epoch) }
            timer = Task { await publicationLoop(epoch: epoch) }
            try await flush()
            guard epoch == generation else { throw CancellationError() }
            return features
        } catch { await finish(epoch: epoch, error: error); throw error }
    }
    public func stop() async {
        guard !stopping else { return }
        generation &+= 1
        guard let transport = connection else { status = .stopped; return }
        stopping = true; defer { stopping = false }
        cancelLiquidityRequests()
        failRouting(LightningInvoiceError.unavailable)
        reader?.cancel(); timer?.cancel()
        await transport.close(); await engine.peerDisconnected(peer)
        connection = nil; reader = nil; timer = nil; status = .stopped
        initialChannelPublicationPending = false
        incoming.removeAll(); incomingBytes = 0
    }
    /// Reentrant callers share a single ordered publisher. Channel messages
    /// replay only after a new authenticated session; onion publication is
    /// acknowledged to the journal only after the transport accepted its bytes.
    public func flush() async throws {
        guard !flushing, status == .connected, let transport = connection else { return }
        let epoch = generation
        flushing = true; defer { flushing = false }
        guard await engine.chainIsCurrent else { return }
        do {
            try await publishChannel(transport, epoch: epoch)
            guard epoch == generation, status == .connected else { throw CancellationError() }
            initialChannelPublicationPending = false
            try await publishOnions(transport, epoch: epoch)
        } catch LightningError.invalidState {
            if await engine.chainIsCurrent { throw LightningError.invalidState }
        }
    }
    func sendLiquidity(_ message: LightningWire.Message) async throws {
        guard status == .connected, let connection else { throw LightningLiquidityError.unavailable }
        try await connection.send(message)
    }
    private func publishChannel(_ transport: LightningConnection, epoch: UInt64) async throws {
        for item in try await engine.pendingMessages(peer: peer) where !sent.contains(item.sequence) {
            guard epoch == generation else { throw CancellationError() }
            try await transport.send(item.message)
            guard epoch == generation else { throw CancellationError() }
            sent.insert(item.sequence)
        }
    }
    private func publishOnions(_ transport: LightningConnection, epoch: UInt64) async throws {
        for item in try await engine.pendingOnionMessages(peer: peer, now: Self.now) {
            guard epoch == generation else { throw CancellationError() }
            try await transport.send(item.message)
            guard epoch == generation else { throw CancellationError() }
            try await engine.onionMessagePublished(sequence: item.sequence)
        }
    }
    private func receiveLoop(_ transport: LightningConnection, epoch: UInt64) async {
        do {
            while !Task.isCancelled && epoch == generation {
                let message = try await transport.receive()
                try Task.checkCancellation()
                guard epoch == generation else { return }
                if Self.requiresVerifiedChain(message.type) {
                    // A chain scan must pause financial processing, not TCP
                    // keepalives. Retain a bounded, ordered queue while still
                    // reading ping/pong and provider notices from the wire.
                    let size = message.payload.count + 2
                    guard incoming.count < 128, incomingBytes + size <= 1_048_576 else {
                        throw LightningLiquidityError.provider("Too many provider messages while verifying the chain.")
                    }
                    incoming.append(message); incomingBytes += size
                    try await drainIncoming(epoch: epoch)
                } else {
                    try await handleChecked(message, transport: transport)
                }
                try await flush()
            }
        } catch { await finish(epoch: epoch, error: error) }
    }
    private func publicationLoop(epoch: UInt64) async {
        do {
            while !Task.isCancelled && epoch == generation {
                try await Task.sleep(for: .milliseconds(250))
                try await drainIncoming(epoch: epoch)
                await checkRoutingTimeout(now: Self.now)
                let events = try await engine.expireInvoiceRequests(now: Self.now)
                if !events.isEmpty { try await onEvents(events) }
                try await flush()
            }
        } catch { await finish(epoch: epoch, error: error) }
    }
    private static func requiresVerifiedChain(_ type: UInt16) -> Bool {
        [32, 33, 34, 35, 36, 38, 39, 128, 130, 131, 132, 133, 134, 135, 136, 513].contains(type)
    }
    private func drainIncoming(epoch: UInt64) async throws {
        // An eager channel_reestablish can acknowledge our queued replay.
        // Keep it queued until that replay reaches this session's transport,
        // including when a chain scan pauses the initial publication.
        guard !handlingIncoming, !initialChannelPublicationPending else { return }
        handlingIncoming = true; defer { handlingIncoming = false }
        while epoch == generation, status == .connected, let message = incoming.first {
            let events: [LightningEngine.Event]?
            do { events = try await engine.receiveWhenCurrent(peer: peer, message: message, now: Self.now) }
            catch LightningError.invalidMessage {
                throw LightningLiquidityError.provider("Invalid or unsupported provider message \(message.type).")
            }
            // The readiness check and state transition share the engine actor.
            // A scan starting between two awaits cannot discard this message.
            guard let events, epoch == generation, status == .connected else { return }
            incoming.removeFirst(); incomingBytes -= message.payload.count + 2
            try await onEvents(events)
        }
    }
    private func handleChecked(_ message: LightningWire.Message, transport: LightningConnection) async throws {
        do { try await handle(message, transport: transport) }
        catch LightningError.invalidMessage {
            throw LightningLiquidityError.provider("Invalid or unsupported provider message \(message.type).")
        }
    }
    private func handle(_ message: LightningWire.Message, transport: LightningConnection) async throws {
        switch message.type {
        case 18:
            var reader = LightningWire.Reader(message.payload)
            let count = try reader.u16(), ignored = try reader.u16()
            _ = try reader.take(Int(ignored)); try reader.requireEnd()
            if count < 65_532 {
                var pong = LightningWire.Writer(); pong.u16(count); pong.append(Data(repeating: 0, count: Int(count)))
                try await transport.send(.init(type: 19, payload: pong.data))
            }
        case LightningLiquidity.messageType:
            guard let response = LightningLiquidity.response(message) else { return }
            liquidityRequests.removeValue(forKey: response.id)?.resume(with: response.result.mapError { $0 as any Error })
        case 256, 257, 261, 262, 263, 264: try await handleGossip(message)
        case 258:
            try await handleGossip(message)
            try await engine.receiveChannelPolicy(peer: peer, message: message)
        case 1, 17: try await handlePeerNotice(message)
        default:
            guard message.type % 2 == 1 else { throw LightningError.invalidMessage }
        }
    }
    func handlePeerNotice(_ message: LightningWire.Message) async throws {
        let notice = try LightningPeerNotice(message)
        guard await engine.recognizesNotice(notice, peer: peer) else { return }
        if notice.isError {
            // bLIP-52: a provider may abandon a channel negotiation and
            // retry; that error does not end the connection.
            if try await engine.rejectOpening(notice, peer: peer) { lastPeerWarning = notice.description; return }
            throw notice
        }
        lastPeerWarning = notice.description
    }
    private func finish(epoch: UInt64, error: Error) async {
        guard epoch == generation else { return }
        await stop()
        if generation == epoch &+ 1 { status = .failed(error.localizedDescription) }
    }
    private static var now: UInt64 { UInt64(Date().timeIntervalSince1970) }
}

extension LightningEngine {
    func receiveWhenCurrent(peer: Data, message: LightningWire.Message, now: UInt64) throws -> [Event]? {
        guard chainIsCurrent else { return nil }
        switch message.type {
        case 258: try receiveChannelPolicy(peer: peer, message: message); return []
        case 513: return try receiveOnionMessage(message, now: now)
        default: return try receive(peer: peer, message: message)
        }
    }
    func connection(host: String, port: UInt16, peer: Data) throws -> LightningConnection {
        try healthy()
        guard chainIsCurrent else { throw LightningError.invalidState }
        return try LightningConnection(host: host, port: port, secret: state.nodeSecret, peer: peer)
    }
}
