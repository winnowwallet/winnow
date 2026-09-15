@testable import WinnowApp
import WalletCore
import XCTest

@MainActor
final class PeerGatewayModelTests: XCTestCase {
    func testCorruptPersistedSettingsStayOffline() async {
        let defaults = makeDefaults()
        defaults.set(Data("broken".utf8), forKey: "peerGateways")
        let model = makeModel(defaults: defaults)
        XCTAssertNotNil(model.tor.gateways)
        let route = await model.tor.resume(directory: .temporaryDirectory)
        XCTAssertEqual(route, .offline)
        XCTAssertEqual(model.tor.state, .failed)
    }

    func testSelectionPersistsAndInvalidEditKeepsPreviousSelection() async throws {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        let config = PeerGatewayConfiguration(networks: [.tor, .i2p],
                                               torProxy: .init(host: "tdx2", port: 9050),
                                               i2pProxy: .init(host: "tdx2", port: 4447))
        try await model.setPeerGateways(config)
        XCTAssertEqual(makeModel(defaults: defaults).tor.gateways, config)
        do {
            try await model.setPeerGateways(.init(networks: []))
            XCTFail("An empty selection must be refused")
        } catch {}
        XCTAssertEqual(model.tor.gateways, config)
        XCTAssertEqual(makeModel(defaults: defaults).tor.gateways, config)
        try await model.setPeerGateways(nil)
        XCTAssertNil(makeModel(defaults: defaults).tor.gateways)
    }
}
