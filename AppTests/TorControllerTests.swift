@testable import WinnowApp
import WalletCore
import XCTest

private actor TestTorDriver: TorDriving {
    var starts = 0
    var stops = 0
    var answer: (UInt8, UInt16)
    init(_ answer: (UInt8, UInt16)) { self.answer = answer }
    func start(directory: String) -> Int32 { starts += 1; return 0 }
    func status() -> (UInt8, UInt16) { answer }
    func stop() { stops += 1 }
    func setAnswer(_ value: (UInt8, UInt16)) { answer = value }
}

@MainActor
final class TorControllerTests: XCTestCase {
    func testExternalGatewaysBypassEmbeddedTorAndSurviveSuspension() async {
        let driver = TestTorDriver((3, 0))
        let config = PeerGatewayConfiguration(networks: [.i2p],
                                              i2pProxy: .init(host: "tdx2", port: 4447))
        let controller = TorController(enabled: true, gateways: config, driver: driver)
        let route = await controller.resume(directory: .temporaryDirectory)
        XCTAssertEqual(route, .gateways(config))
        XCTAssertEqual(controller.client.route, .offline)
        let starts = await driver.starts
        XCTAssertEqual(starts, 0)
        await controller.suspend()
        XCTAssertEqual(controller.route, .offline)
        let resumed = await controller.resume(directory: .temporaryDirectory)
        XCTAssertEqual(resumed, .gateways(config))
        await controller.setGateways(nil)
        let embedded = await controller.resume(directory: .temporaryDirectory)
        XCTAssertEqual(embedded, .offline)
        let embeddedStarts = await driver.starts
        XCTAssertEqual(embeddedStarts, 1)
        await controller.suspend()
    }

    func testRuntimeFailureInvalidatesReadyRoute() async throws {
        let driver = TestTorDriver((2, 9050))
        let controller = TorController(enabled: true, driver: driver)
        _ = await controller.resume(directory: .temporaryDirectory)
        XCTAssertEqual(controller.state, .ready)
        await driver.setAnswer((3, 0))
        for _ in 0..<40 where controller.state == .ready { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.route, .offline)
        await controller.suspend()
    }

    func testDisabledDoesNotStartTorAndSuspensionInvalidatesRoute() async {
        let driver = TestTorDriver((2, 9050))
        let controller = TorController(enabled: false, driver: driver)
        XCTAssertEqual(controller.route, .offline)
        let route = await controller.resume(directory: .temporaryDirectory)
        XCTAssertEqual(route, .direct)
        let starts = await driver.starts
        XCTAssertEqual(starts, 0)
        let generation = controller.generation
        await controller.suspend()
        XCTAssertEqual(controller.route, .offline)
        XCTAssertGreaterThan(controller.generation, generation)
    }

    func testFailureStaysOfflineUntilExplicitRetryAndForegroundRebuilds() async {
        let driver = TestTorDriver((3, 0))
        let controller = TorController(enabled: true, driver: driver)
        let failed = await controller.resume(directory: .temporaryDirectory)
        XCTAssertEqual(failed, .offline)
        XCTAssertEqual(controller.state, .failed)
        await driver.setAnswer((2, 9050))
        let stillFailed = await controller.resume(directory: .temporaryDirectory)
        XCTAssertEqual(stillFailed, .offline)
        await controller.suspend()
        let ready = await controller.resume(directory: .temporaryDirectory)
        XCTAssertEqual(ready, .tor(proxy: .init(host: "127.0.0.1", port: 9050)))
        XCTAssertEqual(controller.state, .ready)
        await controller.suspend()
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertEqual(controller.route, .offline)
        let resumed = await controller.resume(directory: .temporaryDirectory)
        XCTAssertEqual(resumed, ready)
        await controller.suspend()
    }

    func testBackgroundDuringBootstrapCannotInstallOldRoute() async throws {
        let driver = TestTorDriver((1, 0))
        let controller = TorController(enabled: true, driver: driver)
        let pending = Task { await controller.resume(directory: .temporaryDirectory) }
        for _ in 0..<100 where controller.state != .bootstrapping { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.state, .bootstrapping)
        await controller.suspend()
        await driver.setAnswer((2, 9050))
        let old = await pending.value
        XCTAssertEqual(old, .offline)
        XCTAssertEqual(controller.route, .offline)
        await controller.setEnabled(false)
        let direct = await controller.resume(directory: .temporaryDirectory)
        XCTAssertEqual(direct, .direct)
        await controller.suspend()
    }
}
