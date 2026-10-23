import Foundation
import Network
import WalletCore

/// Serves a `SatochipEmulator` on 127.0.0.1 to an app under test, which reads
/// it in place of Core NFC (`WINNOW_E2E_SATOCHIP_PORT`): one hex command APDU
/// per line in, one hex response per line out. Each connection is one tap,
/// so the card's session state resets when a connection opens, as it does
/// when a card is brought to a phone.
public final class SatochipLineServer: @unchecked Sendable {
    public let card: SatochipEmulator
    public private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "satochip-line-server")

    public enum ServerError: Error {
        case notListening
    }

    public init(card: SatochipEmulator) throws {
        self.card = card
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [card, queue] connection in
            card.reset()
            Self.serve(connection, card: card, queue: queue)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw ServerError.notListening
        }
        self.port = port
    }

    public func stop() { listener.cancel() }

    private static func serve(_ connection: NWConnection, card: SatochipEmulator, queue: DispatchQueue) {
        connection.start(queue: queue)
        receive(connection, card: card, buffer: Data())
    }

    private static func receive(_ connection: NWConnection, card: SatochipEmulator, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            var pending = buffer
            if let data { pending.append(data) }
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex ..< newline], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                pending = Data(pending[(newline + 1)...])
                let response = Data(hex: line).map { card.respond(to: $0) } ?? Data([0x67, 0x00])
                connection.send(content: Data((response.hex + "\n").utf8), completion: .idempotent)
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(connection, card: card, buffer: pending)
            }
        }
    }
}
