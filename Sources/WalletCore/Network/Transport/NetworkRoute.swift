import Foundation
import Network
import os

/// Captured per networking generation. An unavailable Tor client is offline,
/// never a request to use direct networking instead.
public enum NetworkRoute: Equatable, Sendable {
    case direct
    case tor(proxy: PeerEndpoint)
    case offline

    public var socksProxy: PeerEndpoint? {
        if case let .tor(proxy) = self { return proxy }
        return nil
    }
    public func permits(_ endpoint: PeerEndpoint) -> Bool {
        let host = endpoint.host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard endpoint.port > 0, !host.hasSuffix(".i2p") else { return false }
        switch self {
        case .offline: return false
        case .direct: return !host.hasSuffix(".onion")
        case let .tor(proxy):
            guard proxy.host == "127.0.0.1", proxy.port > 0 else { return false }
            if host.hasSuffix(".onion") { return CensusCatalog.canonicalHost(host, overlay: .tor) != nil }
            if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || !host.contains(".") && !host.contains(":") { return false }
            // Numeric addresses must be public. DNS names are resolved only by
            // Tor; Arti's local-address rejection remains enabled as well.
            if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) {
                return CensusCatalog.canonicalHost(host, overlay: .clearnet) != nil
            }
            return true
        }
    }
    public func permits(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, url.user == nil, url.password == nil,
              let port = UInt16(exactly: url.port ?? (scheme == "https" ? 443 : 80)) else { return false }
        let unbracketed = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        return permits(PeerEndpoint(host: unbracketed, port: port))
    }
}

/// One ephemeral HTTP session per route. All redirects use the same proxy,
/// are rechecked, and cannot downgrade HTTPS. No cookies or persistent cache.
public final class RoutedHTTPClient: Sendable {
    public struct HTTPFailure: Error, LocalizedError {
        public let statusCode: Int
        public var errorDescription: String? { "The server returned HTTP \(statusCode)." }
    }
    public enum Failure: String, Error, LocalizedError {
        case unavailable, response, tooLarge, redirect
        public var errorDescription: String? { "Network request failed: \(rawValue)." }
    }
    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        let route: NetworkRoute
        init(route: NetworkRoute) { self.route = route }
        /// A redirect may move within the host it was asked of, and never
        /// down from https. Every fetch here names one host on purpose — the
        /// census, an explorer — so an answer that sends the client elsewhere
        /// is refused rather than followed.
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, route.permits(url),
                  !(response.url?.scheme == "https" && url.scheme != "https"),
                  url.host?.lowercased() == response.url?.host?.lowercased() else {
                completionHandler(nil); return
            }
            completionHandler(request)
        }
    }
    public let route: NetworkRoute
    private let session: URLSession
    private struct Requests {
        var closed = false
        var tasks: [UUID: Task<Data, Error>] = [:]
    }
    private let requests = OSAllocatedUnfairLock(initialState: Requests())
    public init(route: NetworkRoute) {
        self.route = route
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A fresh Tor circuit can take longer than a direct HTTP connection.
        // Keep both inactivity and whole-resource limits finite, while allowing
        // the same circuit setup time used by the Bitcoin peer transport.
        config.timeoutIntervalForRequest = route.socksProxy == nil ? 30 : 90
        config.timeoutIntervalForResource = route.socksProxy == nil ? 120 : 180
        if let proxy = route.socksProxy, proxy.port > 0 {
            config.proxyConfigurations = [ProxyConfiguration(socksv5Proxy:
                .hostPort(host: NWEndpoint.Host(proxy.host), port: NWEndpoint.Port(rawValue: proxy.port)!))]
        }
        session = URLSession(configuration: config, delegate: RedirectPolicy(route: route), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func cancel() {
        let pending = requests.withLock { state in
            state.closed = true
            return Array(state.tasks.values)
        }
        for task in pending { task.cancel() }
    }
    public func get(_ url: URL, maximumBytes: Int, accept: String? = nil,
                    progress: (@Sendable (Int) -> Void)? = nil) async throws -> Data {
        guard route.permits(url), maximumBytes > 0 else { throw Failure.unavailable }
        let id = UUID()
        // Admit and register the owned task under the same lock used by
        // cancel(). Invalidate URLSession only at deinit: Foundation raises an
        // Objective-C exception if an old client creates a task after invalidation.
        let pending = try requests.withLock { state in
            guard !state.closed else { throw Failure.unavailable }
            let task = Task { [session] in try await Self.fetch(session, url, maximumBytes, accept, progress) }
            state.tasks[id] = task
            return task
        }
        defer { _ = requests.withLock { $0.tasks.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler {
            try await pending.value
        } onCancel: { pending.cancel() }
    }
    private static func fetch(_ session: URLSession, _ url: URL, _ maximumBytes: Int,
                              _ accept: String?,
                              _ progress: (@Sendable (Int) -> Void)?) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw Failure.response }
        guard http.statusCode == 200 else { throw HTTPFailure(statusCode: http.statusCode) }
        guard response.expectedContentLength <= maximumBytes else { throw Failure.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw Failure.tooLarge }
            data.append(byte)
            if data.count % 65_536 == 0 { try Task.checkCancellation(); progress?(data.count) }
        }
        try Task.checkCancellation()
        progress?(data.count)
        return data
    }
}
