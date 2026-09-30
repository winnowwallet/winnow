import Foundation
import LightningCore
import Network

/// A real localhost BOLT 8 responder: it completes the Noise handshake and
/// the `init` exchange with the app's peer session and counts connections.
/// It makes no channel decisions and ignores whatever follows `init`.
actor LightningLocalPeer {
    enum Failure: Error { case noConnection, closed }
    let secret: Data
    private let listener: NWListener
    private var connection: NWConnection?
    private(set) var connections = 0

    init(secret: Data) throws {
        self.secret = secret
        listener = try NWListener(using: .tcp)
    }

    func listen() async throws -> UInt16 {
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        let listener = self.listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "winnow.test.lightning.local-peer"))
        }
    }

    private func accept(_ connection: NWConnection) {
        connections += 1
        self.connection = connection
        connection.start(queue: DispatchQueue(label: "winnow.test.lightning.local-peer.connection"))
    }

    /// Answers the next connection's handshake and `init`.
    func handshake(features: LightningFeatures = .channelOpening) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while connection == nil {
            guard ContinuousClock.now < deadline else { throw Failure.noConnection }
            try await Task.sleep(for: .milliseconds(10))
        }
        let handshake = try LightningHandshake(role: .responder, localSecret: secret)
        guard let reply = try handshake.receive(await exact(50)).reply else { throw Failure.closed }
        try await write(reply)
        guard let transport = try handshake.receive(await exact(66)).transport else { throw Failure.closed }
        var received: [Data] = []
        while received.isEmpty { received = try transport.receive(await read(maximum: 65_536)) }
        _ = try LightningFeatures.readInitialization(LightningWire.Message(bytes: received[0]))
        try await write(transport.encrypt(features.initialization().bytes))
    }

    func close() {
        connection?.cancel(); connection = nil
        listener.cancel()
    }

    private func exact(_ count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count { bytes.append(try await read(maximum: count - bytes.count)) }
        return bytes
    }

    private func read(maximum: Int) async throws -> Data {
        guard let connection else { throw Failure.noConnection }
        let timeout = Task { try await Task.sleep(for: .seconds(10)); connection.cancel() }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: Failure.closed) }
            }
        }
    }

    private func write(_ bytes: Data) async throws {
        guard let connection else { throw Failure.noConnection }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
