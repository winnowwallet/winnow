import WalletCore
import Foundation
import Network

/// A loopback HTTP/1.1 server for `RoutedHTTPClient` tests: reads one
/// request per connection, records it, and answers with canned bytes —
/// one response for every host, per `Host:` name, or per host/path. Enough of the
/// protocol to prove the client half; nothing here parses a body.
public actor LoopbackHTTPServer {
    private var listener: NWListener?
    public private(set) var port: UInt16 = 0
    /// The `Host` header's name (port stripped) of every request, in
    /// arrival order.
    public private(set) var requestedHosts: [String] = []
    /// Every request head as received.
    public private(set) var httpRequests: [String] = []
    private let response: Data?
    private var responsesByHost: [String: Data]
    private var responsesByPath: [String: [String: Data]] = [:]
    private var connections: [NWConnection] = []

    public init(response: Data? = nil, responsesByHost: [String: Data] = [:]) {
        self.response = response
        self.responsesByHost = responsesByHost
    }

    /// Configure answers before issuing requests; path routing avoids timed response swaps.
    public func respond(to host: String, path: String? = nil, with data: Data) {
        if let path {
            responsesByPath[host, default: [:]][path] = data
        } else {
            responsesByHost[host] = data
        }
    }

    /// `http://127.0.0.1:<port>`, with `path` appended.
    public func url(_ path: String = "/") -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

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
            listener.start(queue: DispatchQueue(label: "loopback-http"))
        }
    }

    private func capturePort() { port = listener?.port?.rawValue ?? 0 }

    public func stop() {
        listener?.cancel()
        for connection in connections { connection.cancel() }
    }

    private func serve(_ client: NWConnection) async {
        connections.append(client)
        client.start(queue: DispatchQueue(label: "loopback-http-client"))
        do {
            var request = Data()
            while request.count < 16_384, !request.suffix(4).elementsEqual([13, 10, 13, 10]) {
                request.append(try await Self.read(client, exactly: 1))
            }
            let head = String(decoding: request, as: UTF8.self)
            httpRequests.append(head)
            let header = head.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("host:") }
                .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) } ?? ""
            let host = header.hasPrefix("[") ? header : String(header.split(separator: ":")[0])
            requestedHosts.append(host)
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            guard let response = responsesByPath[host]?[path] ?? responsesByHost[host] ?? response else {
                client.cancel()
                return
            }
            try await Self.write(client, response)
        } catch {
            client.cancel()
        }
    }

    private static func read(_ connection: NWConnection, exactly count: Int) async throws -> Data {
        var collected = Data()
        while collected.count < count {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - collected.count) { data, _, isComplete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: NWError.posix(.ECONNRESET)) }
                    _ = isComplete
                }
            }
            collected.append(chunk)
        }
        return collected
    }

    private static func write(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
