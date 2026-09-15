import Foundation
import Observation
import WalletCore
import WinnowTor

protocol TorDriving: Sendable {
    func start(directory: String) async -> Int32
    func status() async -> (UInt8, UInt16)
    func stop() async
}

actor NativeTorDriver: TorDriving {
    static let shared = NativeTorDriver()
    func start(directory: String) -> Int32 {
        guard !Task.isCancelled else { return -1 }
        return directory.withCString { winnow_tor_start($0) }
    }
    func status() -> (UInt8, UInt16) { (winnow_tor_state(), winnow_tor_port()) }
    func stop() { winnow_tor_stop() }
}

/// Owns one routing generation. Suspending or changing modes invalidates every
/// HTTP request before stopping Arti; callers also stop their Bitcoin pool.
@MainActor @Observable
final class TorController {
    enum State: String { case stopped, bootstrapping, ready, failed }
    private(set) var gateways: PeerGatewayConfiguration?
    private(set) var enabled: Bool
    private(set) var state: State = .stopped
    private(set) var route: NetworkRoute = .offline
    private(set) var generation: UInt64 = 0
    private(set) var client = RoutedHTTPClient(route: .offline)
    private let driver: any TorDriving
    private var bootstrap: Task<(UInt8, UInt16), Never>?
    private var healthMonitor: Task<Void, Never>?

    init(enabled: Bool, gateways: PeerGatewayConfiguration? = nil, driver: any TorDriving = NativeTorDriver.shared) {
        self.gateways = gateways
        self.enabled = enabled
        self.driver = driver
    }

    func setEnabled(_ value: Bool) async {
        await suspend()
        enabled = value
    }

    func setGateways(_ value: PeerGatewayConfiguration?) async {
        await suspend()
        gateways = value
    }

    func suspend() async {
        generation &+= 1
        bootstrap?.cancel()
        bootstrap = nil
        healthMonitor?.cancel()
        healthMonitor = nil
        client.cancel()
        route = .offline
        state = .stopped
        await driver.stop()
    }

    func resume(directory: URL) async -> NetworkRoute {
        if route != .offline { return route }
        if let gateways {
            guard gateways.isValid else { state = .failed; return .offline }
            install(.gateways(gateways))
            state = .ready
            return route
        }
        guard enabled else { install(.direct); return route }
        guard state != .failed else { return .offline }
        let epoch = generation
        if bootstrap == nil {
            state = .bootstrapping
            let driver = driver
            bootstrap = Task { await Self.runBootstrap(driver: driver, directory: directory) }
        }
        guard let bootstrap else { return .offline }
        let result = await bootstrap.value
        guard epoch == generation, !Task.isCancelled else { return .offline }
        self.bootstrap = nil
        if result.0 == 2, result.1 > 0 {
            install(.tor(proxy: PeerEndpoint(host: "127.0.0.1", port: result.1)))
            state = .ready
            monitorHealth(epoch: epoch)
        } else {
            state = .failed
            route = .offline
            await driver.stop()
        }
        return route
    }

    private static func runBootstrap(driver: any TorDriving, directory: URL) async -> (UInt8, UInt16) {
        guard !Task.isCancelled, await driver.start(directory: directory.path) == 0 else { return (3, 0) }
        for _ in 0..<1_200 {
            guard !Task.isCancelled else { return (0, 0) }
            let status = await driver.status()
            if status.0 == 2 || status.0 == 3 { return status }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return (3, 0)
    }

    private func install(_ route: NetworkRoute) {
        client.cancel()
        self.route = route
        client = RoutedHTTPClient(route: route)
    }

    private func monitorHealth(epoch: UInt64) {
        healthMonitor?.cancel()
        healthMonitor = Task { [weak self, driver] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.generation == epoch else { return }
                let status = await driver.status()
                guard self.generation == epoch, !Task.isCancelled else { return }
                if status.0 != 2 {
                    self.client.cancel()
                    self.route = .offline
                    self.state = .failed
                    await driver.stop()
                    return
                }
            }
        }
    }
}
