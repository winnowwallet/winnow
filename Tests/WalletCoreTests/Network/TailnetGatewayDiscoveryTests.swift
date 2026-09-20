import Foundation
import Testing
import TestSupport
@testable import WalletCore

@Suite(.timeLimit(.minutes(1)))
struct TailnetGatewayDiscoveryTests {
    @Test func discoversOnlyTailnetAddressesWithSuccessfulSOCKS() async {
        let discovery = TailnetGatewayDiscovery(resolve: { host in
            host == "winnow-tor-gateway" ? ["8.8.8.8", "127.0.0.1", "100.75.175.127"] : ["100.74.30.8"]
        }, probe: { endpoint in
            #expect(endpoint.host.hasPrefix("100."))
            return endpoint.port == 9050
        })
        let result = await discovery.discover()
        #expect(result.networks == [.clearnet, .tor])
        #expect(result.torProxy == .init(host: "100.75.175.127", port: 9050))
        #expect(result.i2pProxy == nil)
        let absent = await TailnetGatewayDiscovery(resolve: { _ in [] }, probe: { _ in
            Issue.record("Probed an unresolved host"); return true
        }).discover()
        #expect(absent == .init())
    }

    @Test func cancelledDiscoveryCannotInstallAnEndpoint() async {
        let task = Task {
            await TailnetGatewayDiscovery(resolve: { _ in
                try? await Task.sleep(for: .seconds(30)); return ["100.75.175.127"]
            }, probe: { _ in Issue.record("Probed after cancellation"); return true }).discover()
        }
        task.cancel()
        #expect(await task.value == .init())
    }

    @Test func liveSOCKSProbeAndCancellation() async throws {
        let ready = FakeSocksProxy(upstreamPort: nil)
        let stalled = FakeSocksProxy(upstreamPort: nil, stall: true)
        try await ready.start(); try await stalled.start()
        #expect(await TailnetGatewayDiscovery.probeSOCKS(await ready.endpoint))
        let endpoint = await stalled.endpoint
        let task = Task { await TailnetGatewayDiscovery.probeSOCKS(endpoint) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        #expect(await task.value == false)
        #expect(await TailnetGatewayDiscovery.probeSOCKS(endpoint) == false, "Silent gateways must time out")
        await ready.stop(); await stalled.stop()
    }

    private func answer(_ query: GatewayDNSQuery, ip: [UInt8] = [100, 75, 175, 127]) -> Data {
        var data = query.bytes
        data[2] = 0x81; data[3] = 0x80; data[7] = 1
        data.append(contentsOf: [0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4] + ip)
        return data
    }

    @Test func validatesDNSReplyBeforeUsingAnyAddress() {
        let query = GatewayDNSQuery(host: "winnow-tor-gateway", id: 1234)
        let valid = answer(query)
        #expect(query.addresses(in: valid) == ["100.75.175.127"])
        #expect(query.addresses(in: answer(query, ip: [8, 8, 8, 8])).isEmpty)
        #expect(query.addresses(in: answer(query, ip: [100, 100, 100, 100])).isEmpty)
        for count in 0..<valid.count { #expect(query.addresses(in: valid.prefix(count)).isEmpty) }
        for (offset, value) in [(0, UInt8(0)), (2, 0x83), (3, 0x83), (12, 0xc0), (13, 12), (valid.count - 12, 0xc0)] {
            var bad = valid; bad[offset] = value
            #expect(query.addresses(in: bad).isEmpty)
        }
        var wrongOwner = valid
        wrongOwner[query.bytes.count + 1] = UInt8(query.bytes.count)
        #expect(query.addresses(in: wrongOwner).isEmpty, "A compression loop cannot supply an address")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WINNOW_LIVE_GATEWAYS"] == "1"))
    func deployedMagicDNSGateways() async throws {
        let config = await TailnetGatewayDiscovery().discover()
        #expect(config.networks == [.clearnet, .tor, .i2p])
        _ = try #require(config.torProxy)
        _ = try #require(config.i2pProxy)
        print("Discovered gateways: \(config.torProxy?.description ?? "none"), \(config.i2pProxy?.description ?? "none")")
        if let path = ProcessInfo.processInfo.environment["WINNOW_LIVE_CENSUS"] {
            let catalog = try #require(CensusCatalogStore(url: URL(filePath: path)).load()?.catalog)
            await withTaskGroup(of: Void.self) { group in
                for network in [PeerNetwork.tor, .i2p] {
                    group.addTask {
                        for entry in catalog.networks[network.rawValue, default: []].prefix(2) {
                            let peer = PeerConnection(endpoint: entry.endpoint, params: .mainnet,
                                                      socksProxy: config.proxy(for: entry.endpoint))
                            do {
                                try await peer.connect(timeout: .seconds(5))
                                print("Live \(network.rawValue) Bitcoin handshake: \(await peer.peerUserAgent)")
                                await peer.disconnect()
                                return
                            } catch {
                                await peer.disconnect()
                            }
                        }
                        Issue.record("No live \(network.rawValue) peer answered through its discovered gateway")
                    }
                }
            }
        }
    }
}
