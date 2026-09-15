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
}
