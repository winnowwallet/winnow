import CoreNFC
import Foundation
import Network
import WalletCore

/// Hands a Satochip held to the phone to `body` for one tap, then lets go.
/// Everything the card holds for a session (channel, PIN, derived key) ends
/// with the tap, so `body` runs a whole `Satochip.Session` from `connect`.
protocol SatochipReader: Sendable {
    func withCard<T: Sendable>(_ prompt: String,
                               _ body: @escaping @Sendable (any SatochipTransport) async throws -> T) async throws -> T
}

enum SatochipReaderError: LocalizedError, Equatable {
    case unavailable
    case cancelled
    case notASatochip
    case lostCard(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "This iPhone cannot read NFC cards."
        case .cancelled: "The card was not read."
        case .notASatochip: "That card is not a Satochip."
        case let .lostCard(reason): "The card connection ended: \(reason)"
        }
    }
}

/// The Satochip over Core NFC: an ISO 7816 tag session. The applet's AID is
/// listed in Info.plist, which Core NFC requires before it selects it.
final class CoreNFCSatochipReader: NSObject, SatochipReader, @unchecked Sendable {
    func withCard<T: Sendable>(_ prompt: String,
                               _ body: @escaping @Sendable (any SatochipTransport) async throws -> T) async throws -> T {
        guard NFCTagReaderSession.readingAvailable else { throw SatochipReaderError.unavailable }
        let tap = Tap<T>(prompt: prompt, body: body)
        return try await withCheckedThrowingContinuation { continuation in
            tap.start(continuation)
        }
    }

    /// One reader session: find a tag, connect, run the body, close.
    private final class Tap<T: Sendable>: NSObject, NFCTagReaderSessionDelegate, @unchecked Sendable {
        private let prompt: String
        private let body: @Sendable (any SatochipTransport) async throws -> T
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var session: NFCTagReaderSession?

        init(prompt: String, body: @escaping @Sendable (any SatochipTransport) async throws -> T) {
            self.prompt = prompt
            self.body = body
        }

        func start(_ continuation: CheckedContinuation<T, any Error>) {
            lock.withLock { self.continuation = continuation }
            DispatchQueue.main.async {
                guard let session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: nil) else {
                    self.finish(.failure(SatochipReaderError.unavailable))
                    return
                }
                session.alertMessage = self.prompt
                self.lock.withLock { self.session = session }
                session.begin()
            }
        }

        /// Resumes the caller once, whatever ends the tap first.
        private func finish(_ result: Result<T, any Error>) {
            let pending = lock.withLock { () -> CheckedContinuation<T, any Error>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }

        func tagReaderSessionDidBecomeActive(_: NFCTagReaderSession) {}

        func tagReaderSession(_: NFCTagReaderSession, didInvalidateWithError error: any Error) {
            let code = (error as? NFCReaderError)?.code
            if code == .readerSessionInvalidationErrorUserCanceled || code == .readerSessionInvalidationErrorSessionTimeout {
                finish(.failure(SatochipReaderError.cancelled))
            } else {
                finish(.failure(SatochipReaderError.lostCard(error.localizedDescription)))
            }
        }

        func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
            guard let first = tags.first, case let .iso7816(tag) = first else {
                session.invalidate(errorMessage: SatochipReaderError.notASatochip.localizedDescription)
                finish(.failure(SatochipReaderError.notASatochip))
                return
            }
            let reader = Unchecked(session)
            let transport = NFCTransport(tag: Unchecked(tag))
            session.connect(to: first) { error in
                if let error {
                    reader.value.invalidate(errorMessage: "Hold the card still and try again.")
                    self.finish(.failure(SatochipReaderError.lostCard(error.localizedDescription)))
                    return
                }
                Task {
                    do {
                        let value = try await self.body(transport)
                        reader.value.alertMessage = "Done."
                        reader.value.invalidate()
                        self.finish(.success(value))
                    } catch {
                        reader.value.invalidate(errorMessage: error.localizedDescription)
                        self.finish(.failure(error))
                    }
                }
            }
        }
    }

    /// Command APDUs to the tag. Core NFC's tag is not Sendable; a tap uses
    /// it from one task at a time.
    private struct NFCTransport: SatochipTransport {
        let tag: Unchecked<NFCISO7816Tag>

        func transmit(_ command: Data) async throws -> Satochip.Response {
            guard let apdu = NFCISO7816APDU(data: command) else {
                throw Satochip.SatochipError.malformedResponse("command APDU")
            }
            let (data, sw1, sw2) = try await tag.value.sendCommand(apdu: apdu)
            return Satochip.Response(data: data, statusWord: UInt16(sw1) << 8 | UInt16(sw2))
        }
    }
}

/// A value used from one task at a time that its framework does not mark Sendable.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

#if DEBUG
/// True for the first caller only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// E2E builds only: a card served on 127.0.0.1 by the UI test runner (the
/// Satochip emulator, or the applet simulator's bridge), one hex APDU per
/// line each way. A tap is one connection; the server resets the card's
/// session state when a connection opens, as bringing a card to the phone does.
struct LoopbackSatochipReader: SatochipReader {
    let port: UInt16

    func withCard<T: Sendable>(_: String,
                               _ body: @escaping @Sendable (any SatochipTransport) async throws -> T) async throws -> T {
        let connection = try await LineConnection.open(port: port)
        defer { connection.close() }
        return try await body(connection)
    }

    final class LineConnection: SatochipTransport, @unchecked Sendable {
        private let connection: NWConnection
        private var buffer = Data()

        private init(_ connection: NWConnection) {
            self.connection = connection
        }

        static func open(port: UInt16) async throws -> LineConnection {
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let opened = LineConnection(connection)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let once = Once()
                connection.stateUpdateHandler = { state in
                    let result: Result<Void, any Error>?
                    switch state {
                    case .ready: result = .success(())
                    case let .failed(error), let .waiting(error): result = .failure(error)
                    case .cancelled: result = .failure(SatochipReaderError.cancelled)
                    default: result = nil
                    }
                    if let result, once.claim() { continuation.resume(with: result) }
                }
                connection.start(queue: .global())
            }
            return opened
        }

        func close() { connection.cancel() }

        func transmit(_ command: Data) async throws -> Satochip.Response {
            try await send(Data((command.hex + "\n").utf8))
            let line = try await readLine()
            guard let raw = Data(hex: line) else { throw Satochip.SatochipError.malformedResponse("loopback response") }
            return try Satochip.Response(raw: raw)
        }

        private func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
        }

        private func readLine() async throws -> String {
            while true {
                if let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex ..< newline]
                    buffer = Data(buffer[(newline + 1)...])
                    return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                        if let error { return continuation.resume(throwing: error) }
                        if let data, !data.isEmpty { return continuation.resume(returning: data) }
                        continuation.resume(throwing: SatochipReaderError.lostCard(isComplete ? "closed" : "no data"))
                    }
                }
                buffer.append(chunk)
            }
        }
    }
}
#endif
