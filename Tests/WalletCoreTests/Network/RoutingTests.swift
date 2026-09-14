import Foundation
import Testing
import TestSupport
@testable import WalletCore

struct RoutingTests {
    @Test func transportPolicy() {
        let tor = NetworkRoute.tor(proxy: .init(host: "127.0.0.1", port: 9050))
        for host in ["localhost", "device.local", "127.0.0.1", "10.0.0.1", "::1", "fc00::1", "name.i2p"] {
            #expect(!tor.permits(.init(host: host, port: 80)))
        }
        #expect(tor.permits(.init(host: "example.com", port: 443)))
        #expect(tor.permits(.init(host: "8.8.8.8", port: 443)))
        #expect(tor.permits(URL(string: "https://[2606:4700::1111]/")!))
        #expect(!tor.permits(URL(string: "https://[::1]/")!))
        #expect(!NetworkRoute.direct.permits(.init(host: CensusCatalogTests().onion, port: 8333)))
        #expect(!NetworkRoute.offline.permits(URL(string: "https://example.com")!))
        #expect(!tor.permits(URL(string: "https://user:password@example.com")!))
    }

    @Test func httpUsesProxyForUnresolvableName() async throws {
        let proxy = FakeSocksProxy(upstreamPort: nil, httpResponse:
            Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".utf8))
        try await proxy.start()
        let client = RoutedHTTPClient(route: .tor(proxy: await proxy.endpoint))
        do {
            let body = try await client.get(URL(string: "http://must-be-resolved-by-tor.invalid/proof")!, maximumBytes: 8)
            #expect(body == Data("OK".utf8))
            #expect(await proxy.requestedHosts == ["must-be-resolved-by-tor.invalid"])
        } catch { client.cancel(); await proxy.stop(); throw error }
        client.cancel(); await proxy.stop()
    }

    @Test func refusalAndOfflineDoNotFallBack() async throws {
        let proxy = FakeSocksProxy(upstreamPort: nil, refuseWith: 4)
        try await proxy.start()
        let client = RoutedHTTPClient(route: .tor(proxy: await proxy.endpoint))
        await #expect(throws: (any Error).self) {
            try await client.get(URL(string: "http://proxy-only.invalid")!, maximumBytes: 8)
        }
        #expect(await proxy.requestedHost == "proxy-only.invalid")
        client.cancel(); await proxy.stop()
        let offline = RoutedHTTPClient(route: .offline)
        await #expect(throws: RoutedHTTPClient.Failure.unavailable) {
            try await offline.get(URL(string: "https://example.com")!, maximumBytes: 8)
        }
        offline.cancel()
    }

    @Test func redirectCannotEscapeToLocalAddress() async throws {
        let proxy = FakeSocksProxy(upstreamPort: nil, httpResponse: Data(
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/private\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        try await proxy.start()
        let client = RoutedHTTPClient(route: .tor(proxy: await proxy.endpoint))
        await #expect(throws: RoutedHTTPClient.HTTPFailure.self) {
            try await client.get(URL(string: "http://redirect.invalid")!, maximumBytes: 8)
        }
        #expect(await proxy.requestedHosts == ["redirect.invalid"])
        client.cancel(); await proxy.stop()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WINNOW_LIVE_TOR_PORT"] != nil))
    func liveFoundationHTTPSViaArti() async throws {
        let port = try #require(UInt16(ProcessInfo.processInfo.environment["WINNOW_LIVE_TOR_PORT"] ?? ""))
        let client = RoutedHTTPClient(route: .tor(proxy: .init(host: "127.0.0.1", port: port)))
        defer { client.cancel() }
        let data = try await client.get(URL(string: "https://check.torproject.org/api/ip")!, maximumBytes: 4096)
        let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(result["IsTor"] as? Bool == true)
    }

    /// Every fetch names one host on purpose, so a redirect to another host
    /// — even over the same proxy and scheme — is refused, and the other
    /// host is never asked.
    @Test func redirectOffTheAskedHostIsRefused() async throws {
        let proxy = FakeSocksProxy(upstreamPort: nil, httpResponsesByHost: [
            "first.invalid": Data("HTTP/1.1 302 Found\r\nLocation: http://second.invalid/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
            "second.invalid": Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".utf8)
        ])
        try await proxy.start()
        let client = RoutedHTTPClient(route: .tor(proxy: await proxy.endpoint))
        await #expect(throws: RoutedHTTPClient.HTTPFailure.self) {
            try await client.get(URL(string: "http://first.invalid/")!, maximumBytes: 8)
        }
        #expect(await proxy.requestedHosts == ["first.invalid"])
        client.cancel(); await proxy.stop()
    }

    @Test(arguments: [
        "Content-Length: 9\r\n\r\n123456789",
        "Transfer-Encoding: chunked\r\n\r\n9\r\n123456789\r\n0\r\n\r\n"
    ]) func oversizedHTTPBodiesAreBounded(framing: String) async throws {
        let proxy = FakeSocksProxy(upstreamPort: nil, httpResponse: Data(("HTTP/1.1 200 OK\r\n" + framing).utf8))
        try await proxy.start()
        let client = RoutedHTTPClient(route: .tor(proxy: await proxy.endpoint))
        await #expect(throws: RoutedHTTPClient.Failure.tooLarge) {
            try await client.get(URL(string: "http://oversized.invalid")!, maximumBytes: 8)
        }
        client.cancel(); await proxy.stop()
    }

    @Test func cancellingRouteStopsAnUnfinishedBody() async throws {
        let proxy = FakeSocksProxy(upstreamPort: nil, httpResponse: Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".utf8))
        try await proxy.start()
        let client = RoutedHTTPClient(route: .tor(proxy: await proxy.endpoint))
        let pending = Task { try await client.get(URL(string: "http://unfinished.invalid")!, maximumBytes: 8) }
        for _ in 0..<100 where await proxy.requestedHosts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await proxy.requestedHosts == ["unfinished.invalid"])
        client.cancel()
        await #expect(throws: (any Error).self) { try await pending.value }
        await #expect(throws: (any Error).self) {
            try await client.get(URL(string: "http://new-after-cancel.invalid")!, maximumBytes: 8)
        }
        #expect(await proxy.requestedHosts == ["unfinished.invalid"])
        await proxy.stop()
    }
}
