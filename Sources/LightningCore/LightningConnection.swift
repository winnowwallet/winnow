import Foundation
import Network

/// One actor owns each Noise session and the ordered TCP byte stream. A caller
/// runs one receive loop; overlapping reads are rejected, not silently split
/// between consumers. Pending writes are bounded and ordered by NWConnection.
public actor LightningConnection {
    public let peer: Data
    private let connection: NWConnection
    private let handshake: LightningHandshake
    private var transport: LightningTransport?
    private var incoming = Data()
    private var messages: [Data] = []
    private var reading = false, closed = false
    private var pendingWrites = 0

    public init(host: String, port: UInt16, secret: Data, peer: Data) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port), !host.isEmpty else { throw LightningError.invalidMessage }
        self.peer = peer
        let tcp = NWProtocolTCP.Options(); tcp.connectionTimeout = 15; tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: NWParameters(tls: nil, tcp: tcp))
        handshake = try LightningHandshake(role: .initiator, localSecret: secret, remotePublicKey: peer)
    }
    public func start() async throws {
        guard !closed, transport == nil, !reading else { throw LightningError.invalidState }
        reading = true
        defer { reading = false }
        do {
            connection.start(queue: DispatchQueue(label: "winnow.lightning.tcp"))
            try await write(handshake.start())
            let result = try handshake.receive(await exact(50))
            guard let reply = result.reply, let negotiated = result.transport else { throw LightningError.invalidState }
            try await write(reply)
            transport = negotiated
        } catch { close(); throw error }
    }
    public func send(_ message: LightningWire.Message) async throws {
        guard !closed, let transport else { throw LightningError.closed }
        do { try await write(transport.encrypt(message.bytes)) } catch { close(); throw error }
    }
    public func receive() async throws -> LightningWire.Message {
        guard !closed, let transport, !reading else { throw LightningError.invalidState }
        reading = true
        defer { reading = false }
        do {
            while messages.isEmpty {
                let bytes = incoming.isEmpty ? try await read() : incoming
                incoming = Data()
                messages.append(contentsOf: try transport.receive(bytes))
            }
            return try LightningWire.Message(bytes: messages.removeFirst())
        } catch { close(); throw error }
    }
    public func close() {
        closed = true; connection.cancel(); handshake.close(); transport?.close()
        incoming = Data(); messages.removeAll()
    }
    private func exact(_ count: Int) async throws -> Data {
        while incoming.count < count { incoming.append(try await read()) }
        let bytes = Data(incoming.prefix(count)); incoming = Data(incoming.dropFirst(count))
        return bytes
    }
    private func read() async throws -> Data {
        let connection = self.connection
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: LightningError.closed) }
                    else { continuation.resume(throwing: LightningError.invalidMessage) }
                }
            }
        } onCancel: { connection.cancel() }
    }
    private func write(_ bytes: Data) async throws {
        guard !closed, pendingWrites < 32 else { throw LightningError.closed }
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        let connection = self.connection
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        } onCancel: { connection.cancel() }
    }
}
