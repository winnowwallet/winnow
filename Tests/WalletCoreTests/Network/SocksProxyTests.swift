import Testing
import TestSupport
import WalletCore

@Suite(.timeLimit(.minutes(1)))
struct SocksProxyTests {
    @Test("a peer is dialled by name through the proxy and the handshake runs over the circuit")
    func connectsByName() async throws {
        let signetParams = NetworkParams.signet
        let node = LoopbackNode(params: signetParams)
        try await node.start()
        defer { Task { await node.stop() } }
        let proxy = FakeSocksProxy(upstreamPort: await node.endpoint.port)
        try await proxy.start()
        defer { Task { await proxy.stop() } }

        // A name no resolver could answer: only the proxy can take it.
        let peer = PeerConnection(endpoint: PeerEndpoint(host: "winnowtestpeer.onion", port: 8333),
                                  params: signetParams, socksProxy: await proxy.endpoint)
        try await peer.connect(timeout: .seconds(10))
        #expect(await peer.isConnected)
        #expect(await peer.peerUserAgent.isEmpty == false, "the version exchange ran over the circuit")
        #expect(await proxy.requestedHost == "winnowtestpeer.onion", "the name went to the proxy unresolved")
        #expect(await proxy.requestedPort == 8333)
        #expect(await node.nextMessage(command: "verack", timeout: .seconds(5)) != nil)
        await peer.disconnect()
    }

    @Test("a proxy that cannot reach the peer reports a transport failure, not a protocol fault")
    func proxyRefusal() async throws {
        let signetParams = NetworkParams.signet
        let proxy = FakeSocksProxy(upstreamPort: nil, refuseWith: 0x04) // host unreachable
        try await proxy.start()
        defer { Task { await proxy.stop() } }
        let peer = PeerConnection(endpoint: PeerEndpoint(host: "nowhere.onion", port: 8333),
                                  params: signetParams, socksProxy: await proxy.endpoint)
        do {
            try await peer.connect(timeout: .seconds(10))
            Issue.record("the connection should have failed")
        } catch let error as PeerError {
            #expect(error.isTransport, "\(error)")
            #expect(error.localizedDescription.contains("host unreachable"))
        }
        #expect(await peer.isConnected == false)
    }

    @Test("without a proxy the dial is direct and unchanged")
    func directDialUnchanged() async throws {
        let signetParams = NetworkParams.signet
        let node = LoopbackNode(params: signetParams)
        try await node.start()
        defer { Task { await node.stop() } }
        let peer = PeerConnection(endpoint: await node.endpoint, params: signetParams)
        try await peer.connect(timeout: .seconds(10))
        #expect(await peer.socksProxy == nil)
        #expect(await peer.isConnected)
        await peer.disconnect()
    }
    @Test("malformed proxy replies cannot enter the Bitcoin handshake")
    func invalidReservedByte() async throws {
        let node = LoopbackNode(params: .signet)
        try await node.start()
        defer { Task { await node.stop() } }
        let proxy = FakeSocksProxy(upstreamPort: await node.endpoint.port, reserved: 1)
        try await proxy.start()
        defer { Task { await proxy.stop() } }
        let peer = PeerConnection(endpoint: .init(host: "unresolved.onion", port: 8333), params: .signet, socksProxy: await proxy.endpoint)
        do {
            try await peer.connect(timeout: .seconds(5))
            Issue.record("Expected invalid proxy reply")
        } catch let error as PeerError {
            guard case .handshakeFailed = error else { Issue.record("Unexpected error: \(error)"); return }
        }
        #expect(await peer.isConnected == false)
        #expect(await peer.peerUserAgent.isEmpty)
    }

    @Test("a silent proxy times out instead of pinning connect")
    func stalledProxy() async throws {
        let proxy = FakeSocksProxy(upstreamPort: nil, stall: true)
        try await proxy.start()
        defer { Task { await proxy.stop() } }
        let peer = PeerConnection(endpoint: .init(host: "unresolved.onion", port: 8333), params: .signet, socksProxy: await proxy.endpoint)
        do {
            try await peer.connect(timeout: .milliseconds(100))
            Issue.record("Expected timeout")
        } catch let error as PeerError {
            guard case .timeout = error else { Issue.record("Unexpected error: \(error)"); return }
        }
        #expect(await peer.isConnected == false)
    }

    @Test("cancellation releases a pending proxy negotiation")
    func cancelledProxy() async throws {
        let proxy = FakeSocksProxy(upstreamPort: nil, stall: true)
        try await proxy.start()
        defer { Task { await proxy.stop() } }
        let peer = PeerConnection(endpoint: .init(host: "unresolved.onion", port: 8333), params: .signet, socksProxy: await proxy.endpoint)
        let task = Task { try await peer.connect(timeout: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") } catch {}
        #expect(await peer.isConnected == false)
    }
}
