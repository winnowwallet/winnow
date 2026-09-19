@testable import WinnowApp
import Foundation
import TestSupport
import WalletCore
import XCTest

@MainActor
final class PeerCatalogStartupTests: XCTestCase {
    private func fixture(network: BitcoinNetwork) async throws -> (AppModel, LoopbackHTTPServer) {
        let server = LoopbackHTTPServer(response: Data(
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8))
        try await server.start()
        let control = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = await server.url("/peers.json")
        try JSONEncoder().encode(E2EMode.Control(censusURL: url.absoluteString)).write(to: control)
        let environment = [
            "WINNOW_E2E": "1", "WINNOW_E2E_RUN": "catalog-\(UUID().uuidString)",
            "WINNOW_E2E_ENTROPY": String(repeating: "00", count: 16),
            "WINNOW_E2E_NETWORK": network.rawValue, "WINNOW_E2E_CONTROL_FILE": control.path,
        ]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { throw NSError(domain: "fixture", code: 1) }
        let model = AppModel(e2e: mode, storeKeys: InMemoryStoreKeyVault(), keyStore: InMemoryKeyStore())
        addTeardownBlock {
            await model.scenePhaseChanged(.background)
            await server.stop()
            cleanup.wipeIfRequested()
            try? FileManager.default.removeItem(at: control)
        }
        // Activation before boot changes foreground state without starting a
        // public peer pool. Refresh exercises automatic discovery in isolation.
        await model.scenePhaseChanged(.active)
        return (model, server)
    }

    func testFreshMainnetAutomaticallyDownloadsAndRejectsUnsignedListWithoutRetryStorm() async throws {
        let (model, server) = try await fixture(network: .mainnet)
        XCTAssertNil(model.catalogStore?.load())
        await model.refresh()
        let deadline = ContinuousClock.now + .seconds(60)
        while model.catalogError == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.catalogError)
        let requests = await server.httpRequests
        XCTAssertEqual(requests.map { $0.split(separator: " ")[1] }, ["/peers.json", "/peers.json.sig"])
        XCTAssertNil(model.catalogStore?.load(), "invalid download must never become discovery input")
        for _ in 0..<5 { await model.refresh() }
        let requestCount = await server.httpRequests.count
        XCTAssertEqual(requestCount, 2, "foreground refreshes must respect retry backoff")
        XCTAssertEqual(model.network, .mainnet)
        XCTAssertNil(model.walletID)
    }

    func testSignetDoesNotFetchMainnetCatalog() async throws {
        let (model, server) = try await fixture(network: .signet)
        await model.refresh()
        await Task.yield()
        let requests = await server.httpRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func testBackgroundDoesNotStartCatalogDownload() async throws {
        let (model, server) = try await fixture(network: .mainnet)
        await model.scenePhaseChanged(.background)
        await model.refresh()
        await Task.yield()
        let requests = await server.httpRequests
        XCTAssertTrue(requests.isEmpty)
    }
}
