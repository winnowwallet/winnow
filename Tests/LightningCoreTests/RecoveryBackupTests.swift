import CryptoKit
import Foundation
import TestSupport
import XCTest
@testable import LightningCore
@testable import WalletCore

private final class BackupBytes: @unchecked Sendable {
    let lock = NSLock()
    var bytes: Data?
    var fail = false
    func read() -> Data? { lock.withLock { bytes } }
    func write(_ data: Data) throws {
        try lock.withLock { if fail { throw LightningError.storageFailed }; bytes = data }
    }
}
private final class BackupJournal: LightningJournal {
    let storage: BackupBytes
    init(_ storage: BackupBytes) { self.storage = storage }
    func load() -> Data? { storage.read() }
    func store(_ data: Data) throws { try storage.write(data) }
}

final class RecoveryBackupTests: XCTestCase, @unchecked Sendable {
    let genesis = makeSyntheticChain(length: 0).blocks[0].header
    private func fixture() throws -> (LightningEngine, ChannelState, Transaction, ChannelSecrets) {
        let alice = try ChannelSecrets(), bob = try ChannelSecrets()
        var channel = try ChannelState(peer: ChannelKeys.publicKey(secret: Data(repeating: 2, count: 32)),
            temporaryID: Data(repeating: 3, count: 32), capacity: 100_000, pushMsat: 0, feePerKW: 1000,
            isFunder: true, secrets: alice, local: alice.terms(capacity: 100_000),
            remote: bob.terms(capacity: 100_000), phase: .ready)
        let funding = try Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: Data(repeating: 9, count: 32), vout: 0),
            scriptSig: Data(), sequence: .max, witness: [Data([1])])],
            outputs: [.init(value: 100_000, scriptPubKey: channel.fundingScript())], locktime: 0)
        channel.fundingTxid = funding.txid; channel.fundingOutput = 0
        channel.fundingTransaction = funding.serialized(includeWitness: true)
        channel.localReady = true; channel.remoteReady = true; channel.fundingIsConfirmed = true
        channel.remoteNextPoint = try bob.point(1)
        let commitment = try channel.commitment(localOwner: true), digest = try ChannelTransactions.fundingDigest(commitment)
        channel.signedCommitment = try ChannelTransactions.signed(commitment,
            localSignature: ChannelKeys.sign(digest: digest, secret: alice.funding),
            remoteSignature: ChannelKeys.sign(digest: digest, secret: bob.funding)).serialized(includeWitness: true)
        channel.recovery = .init(destination: Data([0, 20]) + Data(repeating: 12, count: 20), feeSat: 500)
        var state = LightningEngine.State(chain: genesis.hash, nodeSecret: Data(repeating: 1, count: 32))
        state.channels = [channel]; state.revision = 4
        let storage = BackupBytes(); try storage.write(JSONEncoder().encode(state))
        return (try LightningEngine(chain: genesis.hash, journal: BackupJournal(storage)), channel, funding, bob)
    }
    private func restore(_ backup: LightningRecoveryBackup, storage: BackupBytes = BackupBytes()) throws -> LightningEngine {
        try LightningEngine.restoringRecovery(backup, chain: genesis.hash, journal: BackupJournal(storage))
    }
    private func state(_ storage: BackupBytes) throws -> LightningEngine.State {
        try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(storage.read()))
    }
    private func scan(_ engine: LightningEngine, height: UInt32, previous: Data, transaction: Transaction) async throws -> BlockHeader {
        let header = minedHeader(previousHash: previous, merkleRoot: transaction.txid, time: genesis.time + height * 600)
        _ = try await engine.scannedBlock(.init(height: height, header: header,
            block: Block(header: header, transactions: [transaction]), watchRevision: engine.chainStatus().revision))
        return header
    }
    func testRestoreIsDurablyRecoveryOnlyBeforeConnectionAndAfterRestart() async throws {
        let (source, channel, _, _) = try fixture()
        let backup = try await source.recoveryBackup(savedAt: Date(timeIntervalSince1970: 1_000))
        let storage = BackupBytes(), restored = try restore(backup, storage: storage)
        let saved = try state(storage)
        XCTAssertEqual(saved.version, 5); XCTAssertNotNil(saved.recoveryRestore)
        XCTAssertTrue(saved.channels[0].dataLossDetected)
        XCTAssertNil(saved.channels[0].closingTransaction); XCTAssertNil(saved.channels[0].feeBumps)
        let originalID = try await source.nodeID(), restoredID = try await restored.nodeID()
        XCTAssertEqual(originalID, restoredID)
        let channels = await restored.channels(); XCTAssertNil(channels[0].signedCommitment)
        try await restored.chainCaughtUp()
        try await restored.peerInitialized(channel.peer, features: .channelOpening)
        let outbox = try await restored.pendingMessages(peer: channel.peer)
        XCTAssertEqual(outbox.map(\.message.type), [136])
        var reader = LightningWire.Reader(outbox[0].message.payload)
        XCTAssertEqual(try reader.take(32), channel.id); XCTAssertEqual(try reader.u64(), 0)
        do { _ = try await restored.openChannel(peer: channel.peer, capacitySat: 100_000, feePerKW: 1000); XCTFail() } catch {}
        do { _ = try await restored.forceClose(channelID: channel.id, peer: channel.peer); XCTFail() } catch {}
        do { _ = try await restored.registerReceive(id: Data(repeating: 5, count: 32), amountMsat: 1000, expiry: 100); XCTFail() } catch {}
        do { _ = try await restored.receive(peer: channel.peer, message: .init(type: 128, payload: Data())); XCTFail() } catch {}
        let fundingEvents = try await restored.pendingFundingBroadcasts(), closingEvents = try await restored.pendingCloseBroadcasts()
        let recoveryEvents = try await restored.pendingRecoveryBroadcasts()
        XCTAssertTrue(fundingEvents.isEmpty); XCTAssertTrue(closingEvents.isEmpty); XCTAssertTrue(recoveryEvents.isEmpty)
        let restarted = try LightningEngine(chain: genesis.hash, journal: BackupJournal(storage))
        let restartedStatus = await restarted.recoveryStatus(); XCTAssertNotNil(restartedStatus)
        let restartedChannels = await restarted.channels(); XCTAssertNil(restartedChannels[0].signedCommitment)
    }
    func testEqualAndStalePeerProofNeverActivatesRestoredChannels() async throws {
        let (source, channel, _, _) = try fixture()
        let backup = try await source.recoveryBackup(), restored = try restore(backup)
        try await restored.chainCaughtUp(); try await restored.peerInitialized(channel.peer, features: .channelOpening)
        for nextRevocation in [UInt64(0), UInt64(5)] {
            var writer = LightningWire.Writer(); writer.append(channel.id); writer.u64(1); writer.u64(nextRevocation)
            writer.append(nextRevocation == 0 ? Data(repeating: 0, count: 32)
                : try ChannelKeys.commitmentSecret(seed: channel.secrets.seed, number: nextRevocation - 1))
            writer.append(try channel.secrets.point(0))
            let events = try await restored.receive(peer: channel.peer, message: .init(type: 136, payload: writer.data))
            XCTAssertTrue(events.isEmpty)
            let channels = await restored.channels()
            XCTAssertEqual(channels[0].phase, .recovering); XCTAssertNil(channels[0].signedCommitment)
        }
        let status = await restored.recoveryStatus(); XCTAssertEqual(status?.respondingPeers, 1)
        let messages = try await restored.pendingMessages(peer: channel.peer)
        XCTAssertTrue(messages.allSatisfy { $0.message.type == 17 })
    }
    func testRestoreDiscardsOldAuthorizedResolutionAndUnconfirmedParent() async throws {
        let (source, channel, funding, _) = try fixture(), backup = try await source.recoveryBackup()
        var old = try JSONDecoder().decode(LightningEngine.State.self, from: backup.snapshot)
        let signed = try Transaction.decode(XCTUnwrap(channel.signedCommitment))
        old.channels[0].phase = .closing; old.channels[0].closingTransaction = signed.serialized(includeWitness: true)
        old.channels[0].resolutions = [.init(signed, unconfirmedParent: funding.serialized(includeWitness: true))]
        let pending = LightningRecoveryBackup(version: backup.version, id: backup.id, chain: backup.chain,
            nodeID: backup.nodeID, savedAt: backup.savedAt, revision: backup.revision,
            channelCount: backup.channelCount, snapshot: try JSONEncoder().encode(old))
        let storage = BackupBytes(), restored = try restore(pending, storage: storage)
        XCTAssertTrue(try state(storage).channels[0].resolutions.isEmpty)
        XCTAssertNil(try state(storage).channels[0].closingTransaction)
        try await restored.chainCaughtUp()
        let closing = try await restored.pendingCloseBroadcasts(), recovery = try await restored.pendingRecoveryBroadcasts()
        XCTAssertTrue(closing.isEmpty); XCTAssertTrue(recovery.isEmpty)
    }
    func testNewerPeerCommitmentCanReturnFundsWithoutPublishingBackupCommitment() async throws {
        let (source, original, funding, bob) = try fixture()
        let backup = try await source.recoveryBackup(), restored = try restore(backup)
        var newer = original
        newer.remoteNumber = 1; newer.remoteCurrentPoint = try bob.point(1); newer.remoteNextPoint = try bob.point(2)
        let commitment = try newer.commitment(localOwner: false), digest = try ChannelTransactions.fundingDigest(commitment)
        let close = try ChannelTransactions.signed(commitment,
            localSignature: ChannelKeys.sign(digest: digest, secret: bob.funding),
            remoteSignature: ChannelKeys.sign(digest: digest, secret: original.secrets.funding))
        let first = try await scan(restored, height: 1, previous: genesis.hash, transaction: funding)
        _ = try await scan(restored, height: 2, previous: first.hash, transaction: close)
        try await restored.chainCaughtUp(height: 2)
        let events = try await restored.pendingRecoveryBroadcasts()
        XCTAssertEqual(events.count, 1)
        guard case .broadcastRecovery(let id, let raw) = events[0] else { return XCTFail("only a claim may publish") }
        XCTAssertEqual(id, original.id)
        let spend = try Transaction.decode(raw)
        XCTAssertEqual(spend.inputs[0].previousOutput.txid, close.txid)
        XCTAssertEqual(spend.outputs[0].scriptPubKey, original.recovery?.destination)
        XCTAssertNotEqual(raw, original.signedCommitment)
    }
    func testWrongNetworkCorruptionBoundsAndExistingJournalFailWithoutOverwrite() async throws {
        let (source, _, _, _) = try fixture(), backup = try await source.recoveryBackup()
        let encoded = try backup.encoded()
        XCTAssertThrowsError(try LightningRecoveryBackup.decode(encoded, chain: Data(repeating: 7, count: 32)))
        XCTAssertThrowsError(try LightningRecoveryBackup.decode(Data(encoded.dropLast()), chain: genesis.hash))
        XCTAssertThrowsError(try LightningRecoveryBackup.decode(Data(repeating: 0, count: LightningRecoveryBackup.maximumBytes + 1), chain: genesis.hash))
        let occupied = BackupBytes(); try occupied.write(Data("existing identity".utf8))
        XCTAssertThrowsError(try restore(backup, storage: occupied)); XCTAssertEqual(occupied.read(), Data("existing identity".utf8))
        let failing = BackupBytes(); failing.fail = true
        XCTAssertThrowsError(try restore(backup, storage: failing)); XCTAssertNil(failing.read())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["nodeID"] = Data(repeating: 0, count: 33).base64EncodedString()
        XCTAssertThrowsError(try LightningRecoveryBackup.decode(JSONSerialization.data(withJSONObject: object), chain: genesis.hash))
    }
    func testRecoverySecretsUseExistingAuthenticatedCloudWalletContainer() async throws {
        let (source, _, _, _) = try fixture(), backup = try await source.recoveryBackup()
        let wallet = try Wallet.create(network: .signet, keyStore: InMemoryKeyStore(), entropy: Data(repeating: 7, count: 16))
        let bundle = try await wallet.exportBundle(includeMnemonic: true), key = SymmetricKey(size: .bits256)
        let cloud = try CloudWalletBackup.create(bundle: bundle, appState: backup.encoded(), key: key)
        let bytes = try cloud.encoded()
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(backup.snapshot.base64EncodedString()))
        let decoded = try CloudWalletBackup.decode(bytes)
        XCTAssertThrowsError(try decoded.restoredAppState(key: SymmetricKey(size: .bits256)))
        let portable = try LightningRecoveryBackup.decode(XCTUnwrap(decoded.restoredAppState(key: key)), chain: genesis.hash)
        let restored = try restore(portable)
        let restoredID = try await restored.nodeID(), status = await restored.recoveryStatus()
        XCTAssertEqual(restoredID, backup.nodeID); XCTAssertNotNil(status)
    }
}
