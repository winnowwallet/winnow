import Foundation
import Testing
import TestSupport
@testable import WalletCore

@Suite(.timeLimit(.minutes(2)))
struct PeerGatewayTests {
    let onion = PeerEndpoint(host: "22cdvu3sdhpuhaj2g7zbg6gupdkhhuqt7o6k3o7sxqj6div7vk3detid.onion", port: 8333)
    let i2p = PeerEndpoint(host: String(repeating: "a", count: 52) + ".b32.i2p", port: 0x1fff)
    let direct = PeerEndpoint(host: "8.8.8.8", port: 8333)
    let torProxy = PeerEndpoint(host: "100.112.65.68", port: 9050)
    let i2pProxy = PeerEndpoint(host: "tdx2", port: 4447)

    @Test(arguments: 1...7)
    func everyNonemptyCombinationIsAnAllowlist(mask: Int) throws {
        let types = OverlayNetwork.allCases
        let networks = Set(types.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil })
        let config = PeerGatewayConfiguration(networks: networks, torProxy: torProxy, i2pProxy: i2pProxy)
        let route = NetworkRoute.gateways(config)
        #expect(config.isValid)
        for peer in [direct, onion, i2p] { #expect(route.permits(peer) == networks.contains(peer.overlay)) }
        #expect(route.proxy(for: direct) == nil)
        #expect(route.proxy(for: onion) == torProxy)
        #expect(route.proxy(for: i2p) == i2pProxy)
        #expect(try JSONDecoder().decode(PeerGatewayConfiguration.self, from: JSONEncoder().encode(config)) == config)
        let http = networks.contains(.clearnet) ? NetworkRoute.direct : networks.contains(.tor) ? .tor(proxy: torProxy) : .offline
        #expect(RoutedHTTPClient(route: route).route == http)
    }

    @Test func qualifiedOverlayNamesKeepTheirProxy() {
        let route = NetworkRoute.gateways(.init(networks: [.tor, .i2p], torProxy: torProxy, i2pProxy: i2pProxy))
        for peer in [onion, i2p] {
            let qualified = PeerEndpoint(host: peer.host.uppercased() + ".", port: peer.port)
            #expect(route.permits(qualified))
            #expect(route.proxy(for: qualified) == route.proxy(for: peer))
            #expect(NetworkRoute.direct.permits(qualified) == false)
        }
    }

    @Test func incompleteConfigurationAndMalformedOverlayFailClosed() {
        for config in [PeerGatewayConfiguration(networks: []), .init(networks: [.tor]),
                       .init(networks: [.i2p]), .init(networks: [.clearnet, .tor])] {
            #expect(!config.isValid)
            #expect(!NetworkRoute.gateways(config).permits(direct))
            #expect(config.httpRoute == .offline)
        }
        let route = NetworkRoute.gateways(.init(networks: [.tor, .i2p], torProxy: torProxy, i2pProxy: i2pProxy))
        for host in ["invalid.onion", "invalid.b32.i2p", "localhost", "example.com", "invalid.onion."] {
            #expect(!route.permits(.init(host: host, port: 8333)))
        }
        #expect(PeerGatewayConfiguration.validProxy(PeerEndpoint(host: "http://tdx2", port: 9050)) == false)
        #expect(!PeerGatewayConfiguration.validProxy(onion))
        #expect(PeerGatewayConfiguration.validProxy(PeerEndpoint(host: "tdx2", port: 0)) == false)
    }

    @Test func poolSendsEachOverlayToItsOwnProxyAndSkipsDisabledDirectPeer() async throws {
        let params = NetworkParams.customSignet(challenge: Data([0x51]))
        let node = LoopbackNode(params: params)
        try await node.start()
        let tor = FakeSocksProxy(upstreamPort: await node.endpoint.port)
        let i2pNode = LoopbackNode(params: params)
        try await i2pNode.start()
        let i2pGateway = FakeSocksProxy(upstreamPort: await i2pNode.endpoint.port)
        try await tor.start(); try await i2pGateway.start()
        let config = PeerGatewayConfiguration(networks: [.tor, .i2p], torProxy: await tor.endpoint, i2pProxy: await i2pGateway.endpoint)
        let pool = PeerPool(params: params, peerCount: 2,
                            manualPeers: [await node.endpoint, onion, i2p],
                            dialTimeout: .seconds(5), route: .gateways(config))
        await pool.start()
        #expect(await tor.requestedHosts == [onion.host])
        #expect(await i2pGateway.requestedHosts == [i2p.host])
        let peers = await pool.connectedPeers()
        var endpoints = Set<PeerEndpoint>()
        for peer in peers { endpoints.insert(await peer.endpoint) }
        #expect(endpoints == [onion, i2p])
        await pool.stop(); await tor.stop(); await i2pGateway.stop(); await node.stop(); await i2pNode.stop()
    }

    @Test func refusedI2PProxyNeverFallsBackToDirectOrSeeds() async throws {
        let params = NetworkParams.customSignet(challenge: Data([0x51]))
        let node = LoopbackNode(params: params)
        try await node.start()
        let proxy = FakeSocksProxy(upstreamPort: nil, refuseWith: 4)
        try await proxy.start()
        let config = PeerGatewayConfiguration(networks: [.i2p], i2pProxy: await proxy.endpoint)
        let pool = PeerPool(params: params, peerCount: 1, manualPeers: [await node.endpoint, i2p],
                            dialTimeout: .seconds(2), seedResolver: .init(lookup: { _, _, _ in
                                Issue.record("I2P-only must not perform seed discovery"); return []
                            }), route: .gateways(config))
        await pool.start()
        #expect(await proxy.requestedHosts == [i2p.host])
        #expect(await pool.connectedPeers().isEmpty)
        #expect(await pool.connectionStatus.exhausted)
        await pool.stop(); await proxy.stop(); await node.stop()
    }
}
