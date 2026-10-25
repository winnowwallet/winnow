import Foundation
import Network
import WalletCore

/// A BIP 77 directory on loopback for tests: one HTTP/1.1 server that is
/// OHTTP relay, OHTTP gateway and mailbox store at once. A relay-form POST
/// (`/{directory url}/`, or `/`) is decapsulated with the directory's own
/// secp256k1 key; the inner `POST /{id}` stores a message and the inner
/// `GET /{id}` returns one (200) or, after `pollTimeout`, nothing (202). The
/// answer is re-encapsulated and padded to BIP 77's 8,192 bytes. Every inner
/// request is recorded for assertions. `FakePayjoinReceiver` reads and
/// writes mailboxes directly, in process, without HTTP.
public actor FakePayjoinDirectory {
    public typealias Curve = HPKE.Secp256k1
    public typealias Cipher = HPKE.ChaChaPolyAEAD

    public struct InnerRequest: Equatable, Sendable {
        public var method: String
        public var path: String
        public var body: Data
    }

    private var listener: NWListener?
    public private(set) var port: UInt16 = 0
    private let gatewayKey: Curve.PrivateKey
    public let keyConfig: OHTTP.KeyConfig
    public private(set) var innerRequests: [InnerRequest] = []
    public private(set) var outerRequestHeads: [String] = []
    private var mailboxes: [String: [Data]] = [:]
    private var connections: [NWConnection] = []
    /// How long an inner GET on an empty mailbox waits before 202.
    public var pollTimeout: Duration
    /// When false, every GET answers 202 whatever the mailbox holds: a
    /// receiver that never replies.
    public var deliversReplies = true
    /// Outer HTTP status for every relay request, to play a broken relay.
    public var outerStatus = 200

    public init(pollTimeout: Duration = .milliseconds(300)) throws {
        gatewayKey = try Curve.generatePrivateKey()
        keyConfig = OHTTP.KeyConfig(keyID: 1, kemID: Curve.id, publicKey: Curve.serialize(gatewayKey.publicKey),
                                    symmetricAlgorithms: [.init(kdfID: HPKE.kdfID, aeadID: Cipher.id)])
        self.pollTimeout = pollTimeout
    }

    /// `http://127.0.0.1:<port>/`, the directory origin; also the relay.
    public var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    /// The `OH` bytes the receiver publishes for this directory.
    public var bip77KeyBytes: Data { (try? PayjoinParameters.bip77Bytes(of: keyConfig)) ?? Data() }

    public func setPollTimeout(_ timeout: Duration) { pollTimeout = timeout }
    public func setDeliversReplies(_ delivers: Bool) { deliversReplies = delivers }
    public func setOuterStatus(_ status: Int) { outerStatus = status }

    // MARK: - Mailboxes (also used in process by the fake receiver)

    public func post(mailbox id: String, _ message: Data) {
        mailboxes[id.uppercased(), default: []].append(message)
    }

    /// The oldest message in a mailbox, removed.
    public func take(mailbox id: String) -> Data? {
        guard var queue = mailboxes[id.uppercased()], !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        mailboxes[id.uppercased()] = queue
        return first
    }

    /// Waits up to `timeout` for a message in `id`.
    public func await(mailbox id: String, timeout: Duration) async -> Data? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let message = take(mailbox: id) { return message }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return take(mailbox: id)
    }

    // MARK: - Server

    public func start() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            Task { await self.serve(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task { await self.capturePort(); once.resume() }
                case let .failed(error): once.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "fake-payjoin-directory"))
        }
    }

    private func capturePort() { port = listener?.port?.rawValue ?? 0 }

    public func stop() {
        listener?.cancel()
        for connection in connections { connection.cancel() }
    }

    private func serve(_ client: NWConnection) async {
        connections.append(client)
        client.start(queue: DispatchQueue(label: "fake-payjoin-directory-client"))
        do {
            let (head, body) = try await Self.readRequest(client)
            outerRequestHeads.append(head)
            let response = await handleOuter(head: head, body: body)
            try await Self.write(client, response)
        } catch {
            // A client that hung up mid-request needs no answer.
        }
        client.cancel()
    }

    private func handleOuter(head: String, body: Data) async -> Data {
        let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "POST", outerStatus == 200 else {
            return Self.httpResponse(status: outerStatus == 200 ? 404 : outerStatus, body: Data())
        }
        guard let (inner, context) = try? OHTTP.decapsulateRequest(body, config: keyConfig, privateKey: gatewayKey,
                                                                   Curve.self, Cipher.self),
              let request = try? OHTTP.Request(decoding: inner)
        else { return Self.httpResponse(status: 400, body: Data()) }
        innerRequests.append(InnerRequest(method: request.method, path: request.path, body: request.body))
        let innerResponse = await handleInner(request)
        let encoded = innerResponse.encoded
        let padded = encoded + Data(count: max(0, PayjoinSession.encapsulatedBytes - 32 - 16 - encoded.count))
        guard let encapsulated = try? context.encapsulate(padded) else {
            return Self.httpResponse(status: 500, body: Data())
        }
        return Self.httpResponse(status: 200, body: encapsulated, contentType: PayjoinSession.responseMediaType)
    }

    private func handleInner(_ request: OHTTP.Request) async -> OHTTP.Response {
        let id = request.path.split(separator: "/").last.map(String.init) ?? ""
        guard id.count == 13 else { return OHTTP.Response(status: 404) }
        switch request.method {
        case "POST":
            post(mailbox: id, request.body)
            return OHTTP.Response(status: 200)
        case "GET":
            guard deliversReplies, let message = await `await`(mailbox: id, timeout: pollTimeout) else {
                return OHTTP.Response(status: 202)
            }
            return OHTTP.Response(status: 200, body: message)
        default:
            return OHTTP.Response(status: 405)
        }
    }

    static func httpResponse(status: Int, body: Data, contentType: String = "application/octet-stream") -> Data {
        let reason = status == 200 ? "OK" : "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func readRequest(_ connection: NWConnection) async throws -> (head: String, body: Data) {
        var buffer = Data()
        while buffer.count < 65_536, buffer.range(of: Data([13, 10, 13, 10])) == nil {
            buffer.append(try await read(connection, upTo: 4_096))
        }
        guard let headEnd = buffer.range(of: Data([13, 10, 13, 10])) else { throw NWError.posix(.EBADMSG) }
        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        let length = head.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        var body = Data(buffer[headEnd.upperBound...])
        while body.count < length {
            body.append(try await read(connection, upTo: length - body.count))
        }
        return (head, body.prefix(length))
    }

    private static func read(_ connection: NWConnection, upTo count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: NWError.posix(.ECONNRESET)) }
            }
        }
    }

    private static func write(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
