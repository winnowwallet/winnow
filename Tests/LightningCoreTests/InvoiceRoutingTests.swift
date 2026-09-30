import Foundation
import WalletCore
import XCTest
@testable import LightningCore

private final class InvoiceJournal: LightningJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    func load() -> Data? { lock.withLock { bytes } }
    func store(_ data: Data) { lock.withLock { bytes = data } }
}

final class InvoiceRoutingTests: XCTestCase, @unchecked Sendable {
    private let nodeSecret = Data(repeating: 1, count: 32), peerSecret = Data(repeating: 2, count: 32)
    private let scid: UInt64 = 100 << 40 | 2 << 16
    private func snapshot(index: UInt32? = 2) throws -> LightningEngine.State {
        let local = try ChannelSecrets(), remote = try ChannelSecrets()
        var channel = try ChannelState(peer: ChannelKeys.publicKey(secret: peerSecret),
            temporaryID: Data(repeating: 3, count: 32), capacity: 100_000, pushMsat: 0, feePerKW: 1000, isFunder: false,
            secrets: local, local: local.terms(capacity: 100_000), remote: remote.terms(capacity: 100_000), phase: .ready)
        let funding = try Transaction(version: 2,
            inputs: [.init(previousOutput: .init(txid: Data(repeating: 5, count: 32), vout: 0), scriptSig: Data(), sequence: .max)],
            outputs: [.init(value: 100_000, scriptPubKey: channel.fundingScript())], locktime: 0)
        channel.fundingTxid = funding.txid; channel.fundingOutput = 0
        channel.localReady = true; channel.remoteReady = true; channel.fundingIsConfirmed = true
        channel.recovery = .init(destination: Data([0, 20]) + Data(repeating: 4, count: 20), feeSat: 500)
        var state = LightningEngine.State(chain: NetworkParams.regtest.genesisHash, nodeSecret: nodeSecret)
        state.channels = [channel]
        state.scan.transactions = [.init(height: 100, blockHash: Data(repeating: 7, count: 32),
            raw: funding.serialized(includeWitness: true), transactionIndex: index)]
        return state
    }
    private func engine(_ state: LightningEngine.State) async throws -> (LightningEngine, InvoiceJournal) {
        let journal = InvoiceJournal(); try journal.store(JSONEncoder().encode(state))
        let engine = try LightningEngine(chain: state.chain, journal: journal)
        try await engine.chainCaughtUp(height: 103)
        try await engine.peerInitialized(ChannelKeys.publicKey(secret: peerSecret), features: .channelOpening)
        return (engine, journal)
    }
    private func update(scid: UInt64? = nil, timestamp: UInt32 = 10, disabled: Bool = false, signingSecret: Data? = nil) throws -> LightningWire.Message {
        var writer = LightningWire.Writer()
        writer.append(NetworkParams.regtest.genesisHash); writer.u64(scid ?? self.scid); writer.u32(timestamp); writer.u8(1)
        let peer = try ChannelKeys.publicKey(secret: peerSecret), node = try ChannelKeys.publicKey(secret: nodeSecret)
        writer.u8((peer.lexicographicallyPrecedes(node) ? 0 : 1) | (disabled ? 2 : 0))
        writer.u16(40); writer.u64(1000); writer.u32(1000); writer.u32(250); writer.u64(98_000_000)
        let digest = ChannelKeys.hash(ChannelKeys.hash(writer.data))
        let signature = try ChannelKeys.compactSignature(ChannelKeys.sign(digest: digest, secret: signingSecret ?? peerSecret))
        return try .init(type: 258, payload: signature + writer.data)
    }
    func testInvoiceRequiresVerifiedPositionAndSignedCurrentPrivateChannelPolicy() async throws {
        let peer = try ChannelKeys.publicKey(secret: peerSecret), (engine, journal) = try await engine(snapshot())
        let initially = try await engine.invoiceCapacities(peer: peer)
        XCTAssertTrue(initially.isEmpty)
        try await engine.receiveChannelPolicy(peer: peer, message: update(signingSecret: nodeSecret))
        let invalid = try await engine.invoiceCapacities(peer: peer)
        XCTAssertTrue(invalid.isEmpty)
        try await engine.receiveChannelPolicy(peer: peer, message: update())
        let capacity = try await engine.invoiceCapacities(peer: peer)
        XCTAssertEqual(capacity.first?.route.shortChannelID, scid)
        XCTAssertEqual(capacity.first?.maximumMsat, 98_000_000)
        let invoice = try await engine.createInvoice(id: Data(repeating: 9, count: 32), peer: peer, amountSat: 21, network: .regtest, now: 1_790_000_000)
        XCTAssertEqual(try Bolt11Invoice.decode(invoice, network: .regtest).amountMsat, 21_000)
        let saved = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(journal.load()))
        XCTAssertEqual(saved.incoming.first?.expiresAt, 1_790_003_600)
        try await engine.receiveChannelPolicy(peer: peer, message: update(timestamp: 11, disabled: true))
        try await engine.receiveChannelPolicy(peer: peer, message: update(timestamp: 10))
        let disabled = try await engine.invoiceCapacities(peer: peer)
        XCTAssertTrue(disabled.isEmpty, "replayed policy must not re-enable a channel")
        await engine.chainDisconnected()
        let offline = try await engine.invoiceCapacities(peer: peer)
        XCTAssertTrue(offline.isEmpty)
    }
    func testOlderJournalWithoutFundingPositionRequestsRescanAndOffersNoCapacity() async throws {
        let peer = try ChannelKeys.publicKey(secret: peerSecret), (engine, _) = try await engine(snapshot(index: nil))
        try await engine.receiveChannelPolicy(peer: peer, message: update())
        try await engine.prepareInvoiceRouting()
        let status = await engine.chainStatus(), capacity = try await engine.invoiceCapacities(peer: peer)
        XCTAssertTrue(status.rescanRequired)
        XCTAssertTrue(capacity.isEmpty)
    }
    func testUnfundedAndRejectedRequestsIgnoreUnrelatedRoutingUpdates() async throws {
        let peer = try ChannelKeys.publicKey(secret: peerSecret)
        let empty = LightningEngine.State(chain: NetworkParams.regtest.genesisHash, nodeSecret: nodeSecret)
        let (engine, _) = try await engine(empty)
        let id = try await engine.openChannel(peer: peer, capacitySat: 100_000, feePerKW: 1000)
        let policy = try update()
        let unrelated = try LightningWire.Message(type: 258, payload: policy.payload + Data([0, 0]))
        try await engine.receiveChannelPolicy(peer: peer, message: unrelated)
        let before = await engine.invoicePolicies
        XCTAssertTrue(before.isEmpty)
        var error = LightningWire.Writer(); error.append(id); error.u16(0)
        try await engine.rejectOpening(LightningPeerNotice(.init(type: 17, payload: error.data)), peer: peer)
        try await engine.receiveChannelPolicy(peer: peer, message: unrelated)
        let after = await engine.invoicePolicies, capacities = try await engine.invoiceCapacities(peer: peer)
        XCTAssertTrue(after.isEmpty); XCTAssertTrue(capacities.isEmpty)
    }
}
