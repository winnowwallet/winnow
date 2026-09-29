import Foundation
import Network
import os

/// A naming convention, not tag discovery. Query only Quad100, never public DNS.
/// IPv4 MagicDNS answers are pinned for this foreground networking generation.
public struct TailnetGatewayDiscovery: Sendable {
    public typealias Resolve = @Sendable (String) async -> [String]
    public typealias Probe = @Sendable (PeerEndpoint) async -> Bool
    private let resolve: Resolve
    private let probe: Probe

    public init(resolve: @escaping Resolve = Self.resolveMagicDNS, probe: @escaping Probe = Self.probeSOCKS) {
        self.resolve = resolve; self.probe = probe
    }

    public func discover() async -> PeerGatewayConfiguration {
        async let tor = find("winnow-tor-gateway", port: 9050)
        async let i2p = find("winnow-i2p-gateway", port: 4447)
        let endpoints = await (tor, i2p)
        guard !Task.isCancelled else { return .init() }
        var networks: Set<PeerNetwork> = [.clearnet]
        if endpoints.0 != nil { networks.insert(.tor) }
        if endpoints.1 != nil { networks.insert(.i2p) }
        return .init(networks: networks, torProxy: endpoints.0, i2pProxy: endpoints.1)
    }

    private func find(_ host: String, port: UInt16) async -> PeerEndpoint? {
        // Each conventional hostname identifies one device. Bound even an
        // unexpected multi-answer response to one probe per gateway.
        guard !Task.isCancelled, let address = await resolve(host).first(where: Self.isTailnetIPv4), !Task.isCancelled else { return nil }
        let endpoint = PeerEndpoint(host: address, port: port)
        return await probe(endpoint) && !Task.isCancelled ? endpoint : nil
    }

    static func isTailnetIPv4(_ host: String) -> Bool {
        guard let octets = SeedAddressFilter.ipv4Octets(host) else { return false }
        return octets.0 == 100 && (64...127).contains(octets.1) && host != "100.100.100.100"
    }

    public static func resolveMagicDNS(_ host: String) async -> [String] {
        guard ["winnow-tor-gateway", "winnow-i2p-gateway"].contains(host) else { return [] }
        let query = GatewayDNSQuery(host: host, id: UInt16.random(in: .min ... .max))
        let exchange = GatewayExchange(endpoint: .init(host: "100.100.100.100", port: 53), udp: true)
        guard let answer = await exchange.run(query.bytes, minimum: 12, maximum: 512, timeout: 2) else { return [] }
        return query.addresses(in: answer)
    }

    /// A greeting proves SOCKS availability, not that Tor/I2P can reach a peer.
    /// The subsequent Bitcoin handshake still checks the selected destination.
    public static func probeSOCKS(_ endpoint: PeerEndpoint) async -> Bool {
        let exchange = GatewayExchange(endpoint: endpoint, udp: false)
        return await exchange.run(Data([5, 1, 0]), minimum: 2, maximum: 2, timeout: 2) == Data([5, 0])
    }
}

/// One bounded exchange; cancellation resumes the waiter even before NW starts.
private final class GatewayExchange: Sendable {
    private struct State {
        var finished = false
        var continuation: CheckedContinuation<Data?, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.winnow.gateway-discovery")

    init(endpoint: PeerEndpoint, udp: Bool) {
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host),
                                  port: NWEndpoint.Port(rawValue: endpoint.port)!, using: udp ? .udp : .tcp)
    }

    func run(_ request: Data, minimum: Int, maximum: Int, timeout: Double) async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let start = state.withLock { state in
                    guard !state.finished else { return false }
                    state.continuation = continuation
                    return true
                }
                guard start else { continuation.resume(returning: nil); return }
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed, .cancelled: self?.finish(nil)
                    default: break
                    }
                }
                connection.start(queue: queue)
                connection.send(content: request, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    guard error == nil else { self.finish(nil); return }
                    self.connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { [weak self] data, _, _, error in
                        self?.finish(error == nil && (data?.count ?? 0) >= minimum ? data : nil)
                    }
                })
            }
        } onCancel: { self.finish(nil) }
    }

    private func finish(_ data: Data?) {
        let continuation = state.withLock { state in
            guard !state.finished else { return CheckedContinuation<Data?, Never>?.none }
            state.finished = true
            defer { state.continuation = nil }
            return state.continuation
        }
        connection.cancel()
        continuation?.resume(returning: data)
    }
}

/// Minimal DNS A lookup for two fixed, single-label MagicDNS names. Refuses
/// truncation, mismatched questions, aliases and malformed compression pointers.
struct GatewayDNSQuery {
    let host: String
    let id: UInt16
    var bytes: Data {
        Data([UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, UInt8(host.utf8.count)]
             + Array(host.utf8) + [0, 0, 1, 0, 1])
    }

    func addresses(in data: Data) -> [String] {
        let bytes = Array(data)
        func word(_ i: Int) -> Int { Int(bytes[i]) << 8 | Int(bytes[i + 1]) }
        guard bytes.count >= 12, word(0) == Int(id), word(2) & 0xfa0f == 0x8000,
              word(4) == 1, word(6) <= 16 else { return [] }
        var cursor = 12
        func name(_ cursor: inout Int) -> String? {
            var at = cursor, end: Int?, labels: [String] = [], visited = Set<Int>()
            while at < bytes.count, visited.insert(at).inserted, visited.count <= 16 {
                let count = Int(bytes[at])
                if count == 0 { cursor = end ?? (at + 1); return labels.joined(separator: ".").lowercased() }
                if count & 0xc0 == 0xc0 {
                    guard at + 1 < bytes.count else { return nil }
                    let target = (count & 0x3f) << 8 | Int(bytes[at + 1])
                    guard target >= 12, target < at else { return nil }
                    end = end ?? (at + 2); at = target
                } else {
                    guard count <= 63, at + 1 + count < bytes.count else { return nil }
                    labels.append(String(decoding: bytes[(at + 1)..<(at + 1 + count)], as: UTF8.self))
                    at += count + 1
                }
            }
            return nil
        }
        guard name(&cursor) == host, cursor + 4 <= bytes.count,
              word(cursor) == 1, word(cursor + 2) == 1 else { return [] }
        cursor += 4
        var result: [String] = []
        for _ in 0..<word(6) {
            guard let owner = name(&cursor), cursor + 10 <= bytes.count else { return [] }
            let type = word(cursor), klass = word(cursor + 2), length = word(cursor + 8)
            cursor += 10
            guard cursor + length <= bytes.count else { return [] }
            if owner == host, type == 1, klass == 1, length == 4 {
                result.append(bytes[cursor..<(cursor + 4)].map(String.init).joined(separator: "."))
            }
            cursor += length
        }
        return result.filter(TailnetGatewayDiscovery.isTailnetIPv4)
    }
}
