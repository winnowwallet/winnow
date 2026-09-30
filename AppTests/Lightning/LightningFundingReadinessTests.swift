@testable import WinnowLightning
import Foundation
import LightningCore
import TestSupport
import WalletCore
import XCTest

@MainActor
final class LightningFundingReadinessTests: XCTestCase {
    private final class Journal: LightningJournal {
        var bytes: Data?
        func load() throws -> Data? { bytes }
        func store(_ snapshot: Data) throws { bytes = snapshot }
    }
    private final class Approved: DeviceAuthenticating {
        var entered: (() -> Void)?
        var calls = 0
        var declines = false
        func authenticate(reason: String) async throws {
            calls += 1; entered?()
            if declines { throw CancellationError() }
        }
    }
    private struct Fixture {
        let model: AppModel
        let controller: LightningAppController
        let engine: LightningEngine
        let wallet: Wallet
        let pool: PeerPool
        let node: LoopbackNode
        let peer: Data
        let counterparty: LightningEngine
        let local: Data
        let review: LightningAppController.FundingReview
        let authenticator: Approved
    }

    private func makeFixture(lockNetwork: Bool = true) async throws -> Fixture {
        var environment = ["WINNOW_E2E": "1", "WINNOW_E2E_RUN": "funding-readiness-\(UUID())",
            "WINNOW_E2E_NETWORK": "regtest", "WINNOW_E2E_ENTROPY": "000102030405060708090a0b0c0d0e0f",
            "WINNOW_E2E_DEVICE_AUTH": "1"]
        if !lockNetwork { environment.removeValue(forKey: "WINNOW_E2E_NETWORK") }
        guard case let .active(mode) = E2EMode.resolve(environment: environment),
              case let .active(cleanup) = E2EMode.resolve(environment: environment.merging(["WINNOW_E2E_RESET": "1"]) { _, value in value })
        else { throw WalletError.invalidBundle("isolated Debug test namespace unavailable") }
        addTeardownBlock { cleanup.wipeIfRequested() }
        mode.defaults.set(BitcoinNetwork.regtest.rawValue, forKey: AppModel.DefaultsKey.network)
        let authenticator = Approved(), keys = InMemoryStoreKeyVault(), spendingKeys = InMemoryKeyStore()
        let model = AppModel(deviceAuthenticator: authenticator, e2e: mode, defaults: makeDefaults(),
            storeKeys: keys, keyStore: spendingKeys)
        let root = try XCTUnwrap(model.storageDirectory())
        _ = await model.vaultStore.configure(storageURL: nil, network: .regtest)
        let wallet = try makeTestWallet(network: .regtest, storageURL: root.appending(path: "wallet.json"),
            keyStore: spendingKeys, creationHeight: 0)
        // Wallet.apply consumes a trusted BlockMatch in these unit fixtures;
        // use a non-coinbase coin so this tests funding rather than maturity.
        let script = try await wallet.scriptPubKey(chain: .receive, index: 0)
        let incoming = Transaction(version: 2,
            inputs: [.init(previousOutput: .init(txid: Data(repeating: 9, count: 32), vout: 0), scriptSig: Data(), sequence: 0xFFFF_FFFF)],
            outputs: [.init(value: 500_000, scriptPubKey: script)], locktime: 0)
        try await wallet.apply(match: fakeMatch(height: 1, transactions: [incoming]))
        let node = LoopbackNode(params: .regtest, withholdHeaders: true)
        try await node.start()
        let pool = PeerPool(params: .regtest, peerCount: 1, manualPeers: [await node.endpoint])
        let chain = try HeaderChain(params: .regtest)
        let filters = try FilterSync(pool: pool, chain: chain, startHeight: 1, storageURL: nil)
        let broadcaster = try TxBroadcaster(pool: pool, storageURL: nil)
        addTeardownBlock { await pool.stop(); await node.stop(); await broadcaster.shutdown() }
        await pool.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while await pool.connectedPeers().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let connected = await pool.connectedPeers()
        XCTAssertEqual(connected.count, 1, "loopback handshake is a fixture precondition")
        _ = try XCTUnwrap(connected.first)
        await model.installForTesting(wallet: wallet, stack: .init(pool: pool, chain: chain, filters: filters, broadcaster: broadcaster))
        let controller = try XCTUnwrap(model.lightning)
        try await controller.prepare(directory: root, headers: chain)
        let engine = try XCTUnwrap(controller.engine)
        let counterparty = try LightningEngine(chain: NetworkParams.regtest.genesisHash,
            nodeSecret: Data(repeating: 21, count: 32), journal: Journal())
        let peer = try await counterparty.nodeID(), local = try await engine.nodeID()
        try await engine.chainCaughtUp(); try await counterparty.chainCaughtUp()
        try await engine.peerInitialized(peer, features: .channelOpening)
        try await counterparty.peerInitialized(local, features: .channelOpening)
        _ = try await engine.openChannel(peer: peer, capacitySat: 100_000, feePerKW: 5_000)
        let openingMessages = try await engine.pendingMessages(peer: peer)
        let open = try XCTUnwrap(openingMessages.first(where: { $0.message.type == 32 })).message
        _ = try await counterparty.receive(peer: local, message: open)
        let acceptingMessages = try await counterparty.pendingMessages(peer: local)
        let accept = try XCTUnwrap(acceptingMessages.first(where: { $0.message.type == 33 })).message
        _ = try await engine.receive(peer: peer, message: accept)
        let fundingRequests = try await engine.fundingRequests()
        let request = try XCTUnwrap(fundingRequests.first)
        let review = try await controller.reviewFunding(request, model: model)
        return Fixture(model: model, controller: controller, engine: engine, wallet: wallet,
            pool: pool, node: node, peer: peer, counterparty: counterparty, local: local,
            review: review, authenticator: authenticator)
    }

    /// The real model/driver clears engine readiness and blocks on the peer's
    /// getheaders response. No test setter fabricates a syncing boolean.
    private func holdScan(_ fixture: Fixture) async throws -> Task<Void, Never> {
        let scan = Task { await fixture.model.syncNow() }
        let request = await fixture.node.nextMessage(command: "getheaders")
        _ = try XCTUnwrap(request, "the verified scan must reach its held header request")
        XCTAssertTrue(fixture.model.status.syncing)
        let current = await fixture.engine.isChainCurrent()
        XCTAssertFalse(current)
        return scan
    }
    private func releaseScan(_ fixture: Fixture, scan: Task<Void, Never>) async throws {
        try await fixture.node.send(.headers([]))
        let second = await fixture.node.nextMessage(command: "getheaders")
        _ = try XCTUnwrap(second, "both the driver and filter scan must verify headers")
        try await fixture.node.send(.headers([]))
        await scan.value
        XCTAssertFalse(fixture.model.status.syncing)
        XCTAssertNil(fixture.model.status.lastSyncError)
        let current = await fixture.engine.isChainCurrent()
        XCTAssertTrue(current)
    }
    private func startFunding(_ fixture: Fixture) async -> Task<Void, Error> {
        let entered = expectation(description: "actual funding authentication entered")
        fixture.authenticator.entered = { entered.fulfill() }
        // The review sheet's Confirm action, as the app runs it.
        let operation = Task { try await LightningReview.funding(fixture.review).confirm(controller: fixture.controller, model: fixture.model) }
        await fulfillment(of: [entered], timeout: 5)
        return operation
    }
    private func assertUnreserved(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async {
        let reservations = await fixture.wallet.fundingReservations
        let changeIndex = await fixture.wallet.nextChangeIndex
        let pending = await fixture.wallet.history.filter { $0.height == 0 }
        XCTAssertTrue(reservations.isEmpty, file: file, line: line)
        XCTAssertEqual(changeIndex, 0, file: file, line: line)
        XCTAssertTrue(pending.isEmpty, file: file, line: line)
    }
    private func assertReadinessRejected(_ operation: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation.value; XCTFail("funding passed an unverified readiness gate", file: file, line: line) }
        catch { XCTAssertEqual(error as? LightningError, .invalidState, file: file, line: line) }
    }

    /// Create a funded, initialized channel through the real signature and
    /// confirmation transitions. No app approval or wallet reservation occurs.
    private func readyChannel(_ fixture: Fixture) async throws -> LightningEngine.Channel {
        let request = fixture.review.request
        let funding = Transaction(version: 2,
            inputs: [.init(previousOutput: .init(txid: Data(repeating: 22, count: 32), vout: 1),
                scriptSig: Data(), sequence: .max, witness: [Data([1])])],
            outputs: [.init(value: Int64(request.amountSat), scriptPubKey: request.scriptPubKey)], locktime: 0)
        try await fixture.engine.provideFunding(temporaryID: request.temporaryID, peer: fixture.peer, transaction: funding, output: 0)
        try await deliver(34, from: fixture.engine, peer: fixture.peer, to: fixture.counterparty, senderID: fixture.local)
        try await deliver(35, from: fixture.counterparty, peer: fixture.local, to: fixture.engine, senderID: fixture.peer)
        let channels = await fixture.engine.channels()
        let channel = try XCTUnwrap(channels.first)
        for (engine, peer) in [(fixture.engine, fixture.peer), (fixture.counterparty, fixture.local)] {
            _ = try await engine.fundingConfirmed(channelID: channel.id, peer: peer, transaction: funding, confirmations: 3)
        }
        try await deliver(36, from: fixture.engine, peer: fixture.peer, to: fixture.counterparty, senderID: fixture.local)
        try await deliver(36, from: fixture.counterparty, peer: fixture.local, to: fixture.engine, senderID: fixture.peer)
        let ready = await fixture.engine.channels()
        let result = try XCTUnwrap(ready.first)
        XCTAssertEqual(result.phase, .ready)
        XCTAssertNotNil(result.signedCommitment)
        await assertUnreserved(fixture)
        return result
    }
    private func deliver(_ type: UInt16, from sender: LightningEngine, peer: Data,
                         to recipient: LightningEngine, senderID: Data) async throws {
        let pending = try await sender.pendingMessages(peer: peer)
        let message = try XCTUnwrap(pending.first { $0.message.type == type })
        _ = try await recipient.receive(peer: senderID, message: message.message)
    }
    private func startCloseReview(_ fixture: Fixture, channel: LightningEngine.Channel,
                                 completed: XCTestExpectation? = nil) async -> Task<LightningAppController.CloseReview, Error> {
        let entered = expectation(description: "close review started while the actual scan is held")
        let operation = Task {
            entered.fulfill()
            defer { if fixture.model.status.syncing { completed?.fulfill() } }
            return try await fixture.controller.reviewClose(channel, force: false, model: fixture.model)
        }
        await fulfillment(of: [entered], timeout: 2)
        return operation
    }
    private func assertCloseUnchanged(_ fixture: Fixture, channel: LightningEngine.Channel,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        let channels = await fixture.engine.channels()
        XCTAssertEqual(channels.count, 1, file: file, line: line)
        XCTAssertEqual(channels.first?.id, channel.id, file: file, line: line)
        XCTAssertEqual(channels.first?.phase, .ready, file: file, line: line)
        XCTAssertEqual(channels.first?.signedCommitment, channel.signedCommitment, file: file, line: line)
        XCTAssertEqual(fixture.authenticator.calls, 0, "a review cannot authenticate a close", file: file, line: line)
        await assertUnreserved(fixture, file: file, line: line)
    }
    private func assertCloseRejected(_ operation: Task<LightningAppController.CloseReview, Error>,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation.value; XCTFail("close review passed an unverified readiness gate", file: file, line: line) }
        catch { XCTAssertEqual(error as? LightningError, .invalidState, file: file, line: line) }
    }

    func testCloseReviewWaitsForActualVerifiedScanWithoutClosingOrApproving() async throws {
        let fixture = try await makeFixture(), channel = try await readyChannel(fixture)
        let scan = try await holdScan(fixture)
        let completed = expectation(description: "review must not complete or reject before verified scan")
        completed.isInverted = true
        let operation = await startCloseReview(fixture, channel: channel, completed: completed)
        await fulfillment(of: [completed], timeout: 0.2)
        await assertCloseUnchanged(fixture, channel: channel)
        try await releaseScan(fixture, scan: scan)
        let review: LightningAppController.CloseReview
        do { review = try await operation.value }
        catch { XCTFail("close review rejected after actual verified scan: \(error)"); return }
        XCTAssertEqual(review.channel.id, channel.id)
        XCTAssertFalse(review.force)
        XCTAssertGreaterThan(review.feeSat, 0)
        XCTAssertEqual(try AddressDecoder.scriptPubKey(for: review.address, network: .regtest), review.destination)
        await assertCloseUnchanged(fixture, channel: channel)
        let outbox = try await fixture.engine.pendingMessages(peer: fixture.peer)
        XCTAssertFalse(outbox.contains { [38, 39].contains($0.message.type) }, "readiness may not initiate a close")

        fixture.authenticator.declines = true
        do {
            try await LightningReview.close(review).confirm(controller: fixture.controller, model: fixture.model)
            XCTFail("a declined close closed")
        } catch is CancellationError {}
        XCTAssertEqual(fixture.authenticator.calls, 1, "confirming the reviewed close asks for its approval")
        XCTAssertFalse(fixture.model.keychainAuthentication.isGranted)
        let declined = try await fixture.engine.pendingMessages(peer: fixture.peer)
        XCTAssertFalse(declined.contains { [38, 39].contains($0.message.type) }, "a declined close sends no shutdown")
        let phase = await fixture.engine.channels().first?.phase
        XCTAssertEqual(phase, .ready)
    }

    func testCancelledCloseReviewDuringActualScanCannotProduceApproval() async throws {
        let fixture = try await makeFixture(), channel = try await readyChannel(fixture)
        let scan = try await holdScan(fixture), operation = await startCloseReview(fixture, channel: channel)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("cancelled close review completed") } catch is CancellationError {}
        try await releaseScan(fixture, scan: scan)
        await assertCloseUnchanged(fixture, channel: channel)
    }

    func testStoppedGenerationDuringActualScanCannotPublishOldCloseReview() async throws {
        let fixture = try await makeFixture(), channel = try await readyChannel(fixture)
        let scan = try await holdScan(fixture), operation = await startCloseReview(fixture, channel: channel)
        await fixture.controller.stop()
        do { _ = try await operation.value; XCTFail("stale generation produced close review") } catch is CancellationError {}
        try await fixture.node.send(.headers([]))
        let request = await fixture.node.nextMessage(command: "getheaders")
        _ = try XCTUnwrap(request)
        try await fixture.node.send(.headers([]))
        await scan.value
        // The stopped generation cancels the old scan's publication. As any
        // cancellation, that is not reported as a failed sync, and it is not
        // recorded as a verified check either.
        XCTAssertNil(fixture.model.lastCompleteCheck)
        await assertCloseUnchanged(fixture, channel: channel)
    }

    func testNetworkSwitchDuringActualScanCannotPublishOldCloseReview() async throws {
        let fixture = try await makeFixture(lockNetwork: false), channel = try await readyChannel(fixture)
        let scan = try await holdScan(fixture), operation = await startCloseReview(fixture, channel: channel)
        await fixture.model.switchNetwork(to: .signet)
        await scan.value
        XCTAssertEqual(fixture.model.network, .signet, "exercise the actual network switch rather than a test setter")
        do { _ = try await operation.value; XCTFail("old network produced close review") } catch is CancellationError {}
        await assertCloseUnchanged(fixture, channel: channel)
    }

    func testFailedActualScanRejectsCloseReviewWithoutClosing() async throws {
        let fixture = try await makeFixture(), channel = try await readyChannel(fixture)
        let scan = try await holdScan(fixture), operation = await startCloseReview(fixture, channel: channel)
        await fixture.pool.stop()
        await scan.value
        XCTAssertNotNil(fixture.model.status.lastSyncError)
        await assertCloseRejected(operation)
        await assertCloseUnchanged(fixture, channel: channel)
    }

    func testNoActiveScanAndIncompleteChainRejectCloseReviewWithoutStartingScan() async throws {
        let fixture = try await makeFixture(), channel = try await readyChannel(fixture)
        await fixture.engine.chainDisconnected()
        XCTAssertFalse(fixture.model.status.syncing)
        let operation = await startCloseReview(fixture, channel: channel)
        await assertCloseRejected(operation)
        let requests = await fixture.node.receivedMessages.filter { $0.command == "getheaders" }
        XCTAssertTrue(requests.isEmpty, "review cannot start an unrequested scan")
        await assertCloseUnchanged(fixture, channel: channel)
    }

    func testDisconnectedPeerRejectsCloseReviewAfterActualScanCompletes() async throws {
        let fixture = try await makeFixture(), channel = try await readyChannel(fixture)
        let scan = try await holdScan(fixture), operation = await startCloseReview(fixture, channel: channel)
        await fixture.engine.peerDisconnected(fixture.peer)
        try await releaseScan(fixture, scan: scan)
        await assertCloseRejected(operation)
        await assertCloseUnchanged(fixture, channel: channel)
    }

    func testStalledActualScanKeepsOriginalReadinessDeadlineWithoutClosing() async throws {
        let fixture = try await makeFixture(), channel = try await readyChannel(fixture)
        let scan = try await holdScan(fixture), start = ContinuousClock.now
        let operation = await startCloseReview(fixture, channel: channel)
        await assertCloseRejected(operation)
        XCTAssertGreaterThanOrEqual(start.duration(to: ContinuousClock.now), .seconds(9))
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(12))
        XCTAssertTrue(fixture.model.status.syncing)
        try await releaseScan(fixture, scan: scan)
        await assertCloseUnchanged(fixture, channel: channel)
    }

    func testApprovalWaitsForTheActualScanThenSignsTheReviewedFundingOnce() async throws {
        let fixture = try await makeFixture(), scan = try await holdScan(fixture)
        let operation = await startFunding(fixture)
        await assertUnreserved(fixture)
        let phase = await fixture.engine.channels().first?.phase
        XCTAssertEqual(phase, .accepted)
        try await releaseScan(fixture, scan: scan)
        try await operation.value
        let reservations = await fixture.wallet.fundingReservations
        XCTAssertEqual(reservations.count, 1)
        let reserved = try XCTUnwrap(reservations.first)
        XCTAssertEqual(reserved.phase, .submitted)
        XCTAssertTrue(try fixture.review.preview.authorizes(transaction: reserved.transaction(), fee: reserved.fee,
            changeAmount: reserved.changeOutput()?.value))
        let fundedPhase = await fixture.engine.channels().first?.phase
        XCTAssertEqual(fundedPhase, .awaitingFundingSignature)
        let outbox = try await fixture.engine.pendingMessages(peer: fixture.peer)
        XCTAssertEqual(outbox.filter { $0.message.type == 34 }.count, 1)
        XCTAssertFalse(fixture.model.keychainAuthentication.isGranted)
        let reopened = try Wallet.open(storageURL: XCTUnwrap(fixture.model.storageDirectory()).appending(path: "wallet.json"), keyStore: fixture.model.keyStore)
        let reopenedReservations = await reopened.fundingReservations
        XCTAssertEqual(reopenedReservations, reservations, "exact signed reservation must survive reopening")
    }

    func testCancelledApprovalDuringHeldScanCannotReserveInputs() async throws {
        let fixture = try await makeFixture(), scan = try await holdScan(fixture)
        let operation = await startFunding(fixture)
        operation.cancel()
        do { try await operation.value; XCTFail("cancelled approval funded") } catch is CancellationError {}
        await assertUnreserved(fixture)
        try await releaseScan(fixture, scan: scan)
        XCTAssertFalse(fixture.model.keychainAuthentication.isGranted)
    }

    func testFailedScanCannotReserveInputs() async throws {
        let fixture = try await makeFixture(), scan = try await holdScan(fixture)
        let operation = await startFunding(fixture)
        await fixture.pool.stop()
        await scan.value
        XCTAssertFalse(fixture.model.status.syncing)
        XCTAssertNotNil(fixture.model.status.lastSyncError)
        await assertReadinessRejected(operation)
        await assertUnreserved(fixture)
        let phase = await fixture.engine.channels().first?.phase
        XCTAssertEqual(phase, .accepted)
    }

    func testIncompleteChainWithNoActiveScanRejectsWithoutStartingOne() async throws {
        let fixture = try await makeFixture()
        await fixture.engine.chainDisconnected()
        XCTAssertFalse(fixture.model.status.syncing)
        let operation = await startFunding(fixture)
        await assertReadinessRejected(operation)
        await assertUnreserved(fixture)
        let requests = await fixture.node.receivedMessages.filter { $0.command == "getheaders" }
        XCTAssertTrue(requests.isEmpty, "funding must not initiate an unrequested scan")
    }

    func testPeerDisconnectedDuringScanCannotReserveInputsEvenAfterVerifiedCompletion() async throws {
        let fixture = try await makeFixture(), scan = try await holdScan(fixture)
        let operation = await startFunding(fixture)
        await fixture.engine.peerDisconnected(fixture.peer)
        try await releaseScan(fixture, scan: scan)
        await assertReadinessRejected(operation)
        await assertUnreserved(fixture)
    }

    func testNetworkGenerationChangeDuringScanCancelsBeforeReservation() async throws {
        let fixture = try await makeFixture(), scan = try await holdScan(fixture)
        let operation = await startFunding(fixture)
        await fixture.controller.stop()
        do { try await operation.value; XCTFail("stale generation funded") } catch is CancellationError {}
        await assertUnreserved(fixture)
        // The old scan may finish its verified reads, but its generation check
        // must reject publication through the stopped controller.
        try await fixture.node.send(.headers([]))
        let request = await fixture.node.nextMessage(command: "getheaders")
        _ = try XCTUnwrap(request)
        try await fixture.node.send(.headers([]))
        await scan.value
        // A cancelled publication is neither a failed sync nor a verified check.
        XCTAssertNil(fixture.model.lastCompleteCheck)
        await assertUnreserved(fixture)
    }

    /// The state an app stopped in after durably marking the signed funding
    /// submitted and before handing it to the engine.
    private func submitWithoutSupplying(_ fixture: Fixture) async throws {
        let request = fixture.review.request
        let reserved = try await fixture.wallet.reserveChannelFunding(requestID: request.temporaryID.hex,
            amount: Int64(request.amountSat), scriptPubKey: request.scriptPubKey,
            feeRateSatPerVByte: fixture.review.preview.feeRateSatPerVByte, chainTip: fixture.model.chainTipHeight)
        _ = try await fixture.wallet.markFundingSubmitted(requestID: reserved.requestID)
        let phase = await fixture.engine.channels().first?.phase
        XCTAssertEqual(phase, .accepted)
    }
    private func assertSuppliedOnce(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        let phase = await fixture.engine.channels().first?.phase
        XCTAssertEqual(phase, .awaitingFundingSignature, file: file, line: line)
        let created = try await fixture.engine.pendingMessages(peer: fixture.peer).filter { $0.message.type == 34 }
        XCTAssertEqual(created.count, 1, "one funding_created for the one submitted transaction", file: file, line: line)
        let reservations = await fixture.wallet.fundingReservations
        XCTAssertEqual(reservations.map(\.phase), [.submitted], file: file, line: line)
    }

    /// Resuming supplies the submitted funding once; a later resume finds the
    /// request already answered and supplies nothing again.
    func testResumeSuppliesFundingSubmittedBeforeARestartOnce() async throws {
        let fixture = try await makeFixture()
        try await submitWithoutSupplying(fixture)
        try await fixture.controller.resumeSubmittedFunding(model: fixture.model)
        try await fixture.controller.resumeSubmittedFunding(model: fixture.model)
        try await assertSuppliedOnce(fixture)
        XCTAssertEqual(fixture.authenticator.calls, 0, "resuming never asks for another approval")
    }

    /// Approving a provider runs a verified scan, then connects to it over
    /// BOLT 8 and resumes submitted funding. Resuming while connected reuses
    /// that session rather than opening another.
    func testApprovedProviderConnectsAfterTheVerifiedScanAndResumingReusesTheSession() async throws {
        let fixture = try await makeFixture()
        try await submitWithoutSupplying(fixture)
        let remote = try LightningLocalPeer(secret: Data(repeating: 21, count: 32)), port = try await remote.listen()
        addTeardownBlock { await remote.close() }
        let profile = try LightningProfile(network: "regtest", name: "Fixture", peer: fixture.peer.hex, host: "127.0.0.1", port: port,
            route: .init(introduction: ChannelKeys.publicKey(secret: Data(repeating: 22, count: 32)).hex, shortChannelID: 1,
                baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 48), receive: nil)
        let answered = Task { try await remote.handshake() }
        let approval = Task {
            try await LightningReview.profile(profile).confirm(controller: fixture.controller, model: fixture.model)
        }
        for _ in 0..<2 {
            let request = await fixture.node.nextMessage(command: "getheaders")
            _ = try XCTUnwrap(request, "approving a provider runs a verified scan first")
            try await fixture.node.send(.headers([]))
        }
        try await answered.value
        try await approval.value
        XCTAssertEqual(fixture.controller.profile, profile)
        XCTAssertEqual(fixture.controller.connection, "Connected")
        XCTAssertNil(fixture.controller.error)
        try await assertSuppliedOnce(fixture)

        await fixture.controller.resume(model: fixture.model)
        let connections = await remote.connections
        XCTAssertEqual(connections, 1, "resuming while connected reuses the session")
        XCTAssertEqual(fixture.controller.connection, "Connected")
        try await assertSuppliedOnce(fixture)
        XCTAssertEqual(fixture.authenticator.calls, 1, "only the provider approval authenticates")
        await fixture.controller.stop()
    }

    func testStalledActiveScanExpiresWithoutReservationOrFinancialRetry() async throws {
        let fixture = try await makeFixture(), scan = try await holdScan(fixture)
        let start = ContinuousClock.now
        let operation = await startFunding(fixture)
        await assertReadinessRejected(operation)
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(12))
        XCTAssertTrue(fixture.model.status.syncing, "approval's deadline must not pretend the scan completed")
        await assertUnreserved(fixture)
        try await releaseScan(fixture, scan: scan)
        await assertUnreserved(fixture)
        let phase = await fixture.engine.channels().first?.phase
        XCTAssertEqual(phase, .accepted)
    }
}
