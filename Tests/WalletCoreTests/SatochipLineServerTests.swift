import Foundation
import Network
import Testing
import TestSupport
@testable import WalletCore

/// The loopback card the UI journey hands the app: a whole card session
/// over one connection, and a fresh session on the next.
@Suite("Satochip line server", .timeLimit(.minutes(1)))
struct SatochipLineServerTests {
    /// The app's loopback reader protocol, as a transport: a hex line each way.
    final class LineClient: SatochipTransport, @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()

        init(port: UInt16) async throws {
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let ready = AsyncStream<Bool> { continuation in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: continuation.yield(true)
                    case .failed, .cancelled: continuation.yield(false)
                    default: break
                    }
                }
            }
            connection.start(queue: .global())
            for await ok in ready {
                guard ok else { throw SatochipLineServer.ServerError.notListening }
                break
            }
        }

        func transmit(_ command: Data) async throws -> Satochip.Response {
            connection.send(content: Data((command.hex + "\n").utf8), completion: .idempotent)
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex ..< newline], as: UTF8.self)
                    buffer = Data(buffer[(newline + 1)...])
                    return try Satochip.Response(raw: Data(hex: line)!)
                }
                let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
                    }
                }
                guard !chunk.isEmpty else { throw Satochip.SatochipError.secureChannelLost }
                buffer.append(chunk)
            }
        }
    }

    @Test("a card session runs over the loopback, and each connection is a new tap")
    func sessionOverLoopback() async throws {
        let pin = Data("1234".utf8)
        let server = try SatochipLineServer(card: SatochipEmulator(pin: pin, seed: Data(repeating: 7, count: 32)))
        defer { server.stop() }
        let path: [UInt32] = [86 + HDKey.hardenedOffset, 1 + HDKey.hardenedOffset, HDKey.hardenedOffset]

        var session = Satochip.Session(transport: try await LineClient(port: server.port))
        try await session.connect(pin: pin)
        let key = try await session.participantKey(path: path)
        #expect(key.accountKey == (try HDKey(seed: Data(repeating: 7, count: 32)).derived(path: path).neutered))

        // A second connection is a new tap: the card dropped the first one's
        // channel and PIN, so a command wrapped for it is refused.
        let channelBefore = session
        var next = Satochip.Session(transport: try await LineClient(port: server.port))
        try await next.select()
        var replay = channelBefore
        await #expect(throws: Satochip.SatochipError.secureChannelLost) { try await replay.verifyPIN(pin) }
    }
}
