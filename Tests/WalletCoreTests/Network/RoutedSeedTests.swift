import Foundation
import os
import Testing
import TestSupport
@testable import WalletCore

struct RoutedSeedTests {
    @Test func dnsJSONContentNegotiationTravelsThroughTheClient() async throws {
        let body = Data(#"{"Status":0,"Answer":[{"type":1,"data":"8.8.8.8"}]}"#.utf8)
        let reply = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        let server = LoopbackHTTPServer(response: reply)
        try await server.start()
        let client = RoutedHTTPClient()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let resolver = SeedResolver.routed(client: client, endpoint: await server.url("/dns-query"),
                                           systemResolve: { _, _ in calls.withLock { $0 += 1 }; return [] })
        let endpoints = await resolver.resolve(host: "seed.invalid", port: 8333, allowPrivate: false)
        #expect(endpoints == [.init(host: "8.8.8.8", port: 8333)])
        #expect(calls.withLock { $0 } == 0)
        let requests = await server.httpRequests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.lowercased().contains("accept: application/dns-json\r\n") })
        client.cancel(); await server.stop()
    }

    @Test func aFailedResolverFallsBackToSystemDNSOnce() async throws {
        let server = LoopbackHTTPServer(response: Data("HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        try await server.start()
        let client = RoutedHTTPClient()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let resolver = SeedResolver.routed(client: client, endpoint: await server.url("/dns-query"),
                                           systemResolve: { _, _ in
                                               calls.withLock { $0 += 1 }
                                               return [.init(host: "8.8.8.8", port: 8333)]
                                           })
        #expect(await resolver.resolve(host: "seed.invalid", port: 8333, allowPrivate: false)
            == [.init(host: "8.8.8.8", port: 8333)])
        #expect(calls.withLock { $0 } == 1)
        #expect(await server.requestedHosts.count == 2)
        client.cancel(); await server.stop()
    }

    /// The unrouted resolver's own DoH request: dns-json with the name and
    /// type in the query, a 2xx answer read in full, and anything else refused,
    /// whether the size is declared up front or only found while streaming.
    @Test func liveDoHRequestAcceptsOnlyABoundedSuccessfulAnswer() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubDoH.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func get(_ path: String) async throws -> Data {
            try await SeedResolver.dohGET(endpoint: URL(string: "https://doh.test\(path)")!, session: session,
                                          name: "seed.invalid", type: "AAAA")
        }
        #expect(try await get("/ok") == StubDoH.body)
        let request = try #require(StubDoH.requests.withLock { $0.first { $0.url?.path == "/ok" } })
        let query = request.url?.query ?? ""
        #expect(query.contains("name=seed.invalid") && query.contains("type=AAAA"))
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/dns-json")
        for refused in ["/unavailable", "/declared-oversize", "/streamed-oversize"] {
            await #expect(throws: URLError.self, "\(refused)") { _ = try await get(refused) }
        }
    }

    /// The system fallback answers numeric hosts without touching DNS, keeps
    /// the port it was given, and returns nothing for a name it cannot resolve.
    @Test func systemResolverReadsNumericAnswers() {
        #expect(SeedResolver.getaddrinfo(host: "127.0.0.1", port: 8333) == [.init(host: "127.0.0.1", port: 8333)])
        #expect(SeedResolver.getaddrinfo(host: "::1", port: 18333).map(\.host) == ["::1"])
        #expect(SeedResolver.getaddrinfo(host: "", port: 8333).isEmpty)
    }

    /// Every seed is asked once, in any order, and an endpoint two seeds both
    /// return is kept once.
    @Test func seedsResolveTogetherWithoutDuplicates() async {
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let shared = PeerEndpoint(host: "8.8.8.8", port: 8333)
        let resolver = SeedResolver { host, port, _ in
            asked.withLock { $0.append(host) }
            return host == "a.seed" ? [shared, .init(host: "1.1.1.1", port: port)] : [shared]
        }
        #expect(await resolver.resolveSeeds([], port: 8333, allowPrivate: false).isEmpty)
        let endpoints = await resolver.resolveSeeds(["a.seed", "b.seed"], port: 8333, allowPrivate: false)
        #expect(Set(endpoints) == [shared, .init(host: "1.1.1.1", port: 8333)])
        #expect(endpoints.count == 2)
        #expect(asked.withLock { $0 }.sorted() == ["a.seed", "b.seed"])
    }
}
/// Canned DoH answers by path, served without a socket.
private final class StubDoH: URLProtocol {
    static let body = Data(#"{"Status":0,"Answer":[]}"#.utf8)
    static let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let received = request
        Self.requests.withLock { $0.append(received) }
        let oversized = Data(count: SeedResolver.maximumDoHBytes + 1)
        let (status, length, body): (Int, Int?, Data) = switch request.url?.path {
        case "/ok": (200, Self.body.count, Self.body)
        case "/declared-oversize": (200, oversized.count, oversized)
        case "/streamed-oversize": (200, nil, oversized)
        default: (503, 0, Data())
        }
        let headers = length.map { ["Content-Length": String($0)] } ?? [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
