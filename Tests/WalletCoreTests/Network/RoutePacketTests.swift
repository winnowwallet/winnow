import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// scripts/check-route-packets observes these synthetic destinations on a
/// disposable CI host. The local proxy supplies every response.
struct RoutePacketTests {
    private let name = "winnow-wallet-route-proof.winnowwallet.com"
    private let ok = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK".utf8)

    /// A redirect to another host is refused outright (2026-09-14), so the
    /// redirected-to address is reached only when asked for directly — and
    /// then through the proxy, like the name.
    @Test func namesAddressesAndRedirectsStayAtProxy() async throws {
        let proxy = FakeSocksProxy(upstreamPort: nil, httpResponsesByHost: [
            name: Data("HTTP/1.1 302 Found\r\nLocation: http://8.8.8.8:38357/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
            "8.8.8.8": ok
        ])
        try await proxy.start()
        let client = RoutedHTTPClient(route: .tor(proxy: await proxy.endpoint))
        do {
            await #expect(throws: RoutedHTTPClient.HTTPFailure.self) {
                try await client.get(URL(string: "http://\(name):38357/")!, maximumBytes: 8)
            }
            #expect(await proxy.requestedHosts == [name])
            #expect(try await client.get(URL(string: "http://8.8.8.8:38357/")!, maximumBytes: 8) == Data("OK".utf8))
            #expect(await proxy.requestedHosts == [name, "8.8.8.8"])
        } catch { client.cancel(); await proxy.stop(); throw error }
        client.cancel(); await proxy.stop()
    }

    @Test func failedProxyAndClosedRouteNeverDialDestination() async throws {
        let proxy = FakeSocksProxy(upstreamPort: nil, refuseWith: 4)
        try await proxy.start()
        let client = RoutedHTTPClient(route: .tor(proxy: await proxy.endpoint))
        for host in [name, "8.8.8.8"] {
            await #expect(throws: (any Error).self) {
                try await client.get(URL(string: "http://\(host):38357/")!, maximumBytes: 8)
            }
        }
        #expect(await proxy.requestedHosts == [name, "8.8.8.8"])
        client.cancel()
        await #expect(throws: RoutedHTTPClient.Failure.unavailable) {
            try await client.get(URL(string: "http://8.8.8.8:38357/")!, maximumBytes: 8)
        }
        await proxy.stop()
    }
}
