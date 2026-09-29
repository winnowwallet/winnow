@testable import WinnowApp
import Foundation
import WalletCore
import XCTest

@MainActor
final class BackgroundSyncTests: XCTestCase {
    func testCompletionOccursOnceAndCancelsDeadline() async {
        let done = expectation(description: "completed")
        var completions: [Bool] = [], cancellations = 0
        let run = BackgroundSyncRun(budget: .milliseconds(20), work: { true }, cancel: { cancellations += 1 }) {
            completions.append($0); done.fulfill()
        }
        run.start(); run.start()
        await fulfillment(of: [done], timeout: 1)
        run.expire()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(completions, [true]); XCTAssertEqual(cancellations, 0)
    }

    func testExpirationDrainsWorkAndCannotReportSuccess() async {
        let done = expectation(description: "completed"), started = expectation(description: "started")
        var completions: [Bool] = [], cancellations = 0, drained = false
        let run = BackgroundSyncRun(budget: .seconds(10), work: {
            started.fulfill()
            do { try await Task.sleep(for: .seconds(10)) } catch {}
            drained = true
            return true
        }, cancel: { cancellations += 1 }) {
            XCTAssertTrue(drained); completions.append($0); done.fulfill()
        }
        run.start()
        await fulfillment(of: [started], timeout: 1)
        run.expire(); run.expire()
        await fulfillment(of: [done], timeout: 1)
        await Task.yield()
        XCTAssertEqual(completions, [false]); XCTAssertEqual(cancellations, 1)
    }

    func testDeadlineCancelsHungWork() async {
        let done = expectation(description: "deadline")
        let run = BackgroundSyncRun(budget: .milliseconds(10), work: {
            do { try await Task.sleep(for: .seconds(10)) } catch {}
            return true
        }, cancel: {}) { XCTAssertFalse($0); done.fulfill() }
        run.start()
        await fulfillment(of: [done], timeout: 1)
    }

    func testBackgroundAndForegroundCannotOwnNetworkingTogether() async {
        let model = makeModel()
        await model.scenePhaseChanged(.active)
        let completed = await model.runBackgroundSync()
        XCTAssertFalse(completed)
        XCTAssertFalse(model.backgroundRunning)
        await model.scenePhaseChanged(.background)
    }

    /// A cold BGTask launch: nothing opened the wallet and the scene never
    /// went active. The run opens it, scans, and leaves no networking behind.
    func testColdBackgroundRunOpensTheWalletScansAndTearsDown() async throws {
        let environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "background-\(UUID().uuidString)",
                           "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f",
                           "WINNOW_E2E_PEER": "127.0.0.1:1", "WINNOW_E2E_CHALLENGE": "51"]
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(
                environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, reset in reset })
        else { return XCTFail("could not create isolated background fixture") }
        defer { cleanup.wipeIfRequested() }
        let seeding = AppModel(e2e: mode)
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: mode.storageDirectoryName).appending(path: "signet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try Wallet.create(network: .signet, keyStore: seeding.keyStore,
                              storageURL: directory.appending(path: "wallet.json"), entropy: mode.entropy)

        let model = AppModel(e2e: mode)
        XCTAssertEqual(model.stage, .loading)
        let complete = await model.runBackgroundSync()
        XCTAssertFalse(complete, "an unreachable peer cannot finish a check")
        XCTAssertEqual(model.stage, .ready)
        XCTAssertFalse(model.backgroundRunning)
        XCTAssertNil(model.stack, "a background check must leave no networking running")
        XCTAssertNil(model.lastCompleteCheck)
        // The foreground still starts normally afterwards.
        await model.scenePhaseChanged(.active)
        XCTAssertNotNil(model.stack?.filters)
        await model.scenePhaseChanged(.background)
    }

    func testBackgroundIdentifiersAreDeclaredInBuiltApplication() throws {
        let permitted = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        XCTAssertEqual(Set(permitted), [BackgroundSyncScheduler.refreshID, BackgroundSyncScheduler.processingID])
        let modes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        XCTAssertTrue(Set(["fetch", "processing"]).isSubset(of: Set(modes)))
    }

    /// No banner runs in the background, so Automatic routing must not fall
    /// back to direct connections there once the foreground used a gateway.
    func testBackgroundCheckDoesNotConnectDirectlyAfterTheForegroundUsedGateways() {
        let direct = PeerGatewayConfiguration()
        let overlay = PeerGatewayConfiguration(networks: [.tor, .i2p],
                                               torProxy: .init(host: "100.64.0.1", port: 9050),
                                               i2pProxy: .init(host: "100.64.0.2", port: 4447))
        XCTAssertFalse(AppModel.backgroundRoutingAllowed(mode: .automatic, resolved: direct, foregroundUsedGateways: true))
        XCTAssertTrue(AppModel.backgroundRoutingAllowed(mode: .automatic, resolved: overlay, foregroundUsedGateways: true))
        XCTAssertTrue(AppModel.backgroundRoutingAllowed(mode: .automatic, resolved: direct, foregroundUsedGateways: false))
        // Direct only and Manual were chosen by the user; the background
        // follows them exactly as the foreground does.
        XCTAssertTrue(AppModel.backgroundRoutingAllowed(mode: .direct, resolved: direct, foregroundUsedGateways: true))
        XCTAssertTrue(AppModel.backgroundRoutingAllowed(mode: .manual, resolved: overlay, foregroundUsedGateways: true))
    }

    func testSimpleModeWaitsOutDroppedPeersButShowsOtherErrorsAtOnce() {
        let dropped = PeerError.disconnected("closed").localizedDescription
        XCTAssertNil(AppModel.simpleSyncError(lastError: nil, transientError: nil, failures: 0))
        XCTAssertNil(AppModel.simpleSyncError(lastError: dropped, transientError: dropped, failures: 1))
        XCTAssertNil(AppModel.simpleSyncError(lastError: dropped, transientError: dropped, failures: 2))
        let persistent = AppModel.simpleSyncError(lastError: dropped, transientError: dropped, failures: 3)
        XCTAssertEqual(persistent, "Winnow keeps losing its connection to Bitcoin peers. It will keep trying.")
        // Another failure replaced the dropped-peer message: it shows as is.
        let mismatch = FilterSyncError.filterHeaderMismatch(height: 7).localizedDescription
        XCTAssertEqual(AppModel.simpleSyncError(lastError: mismatch, transientError: dropped, failures: 1), mismatch)
        XCTAssertEqual(AppModel.simpleSyncError(lastError: mismatch, transientError: nil, failures: 0), mismatch)
    }

    func testOnlyLinkFailuresCountAsTransient() {
        XCTAssertTrue(AppModel.isTransientSyncError(PeerError.disconnected("closed")))
        XCTAssertTrue(AppModel.isTransientSyncError(PeerError.timeout))
        XCTAssertTrue(AppModel.isTransientSyncError(FilterSyncError.peersCoolingDown(2)))
        XCTAssertTrue(AppModel.isTransientSyncError(FilterSyncError.noPeers))
        XCTAssertFalse(AppModel.isTransientSyncError(PeerError.protocolViolation("bad")))
        XCTAssertFalse(AppModel.isTransientSyncError(FilterSyncError.checkpointMismatch("split")))
        XCTAssertFalse(AppModel.isTransientSyncError(CocoaError(.fileReadCorruptFile)))
    }
}
