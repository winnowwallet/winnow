import Foundation
import P256K
import TestSupport
import WalletCore
import XCTest
@testable import LightningCore

private final class AnchorJournal: LightningJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var storedBytes: Data?
    private var failWrites = false
    var bytes: Data? {
        get { lock.withLock { storedBytes } }
        set { lock.withLock { storedBytes = newValue } }
    }
    var failing: Bool {
        get { lock.withLock { failWrites } }
        set { lock.withLock { failWrites = newValue } }
    }
    init(_ bytes: Data? = nil) { storedBytes = bytes }
    func load() -> Data? { bytes }
    func store(_ value: Data) throws {
        try lock.withLock {
            if failWrites { throw LightningError.storageFailed }
            storedBytes = value
        }
    }
}

final class AnchorChannelTests: XCTestCase, @unchecked Sendable {
    private let chain = Data(repeating: 7, count: 32)
    private let walletSecret = Data(repeating: 55, count: 32)
    private func key(_ byte: UInt8) throws -> Data { try ChannelKeys.publicKey(secret: Data(repeating: byte, count: 32)) }
    private func parameters(local: UInt64 = 90_000_000, remote: UInt64 = 10_000_000,
                            htlcs: [ChannelTransactions.HTLC] = [], format: ChannelFormat = .anchors) throws -> ChannelTransactions.Parameters {
        try .init(funding: .init(txid: Data(repeating: 9, count: 32), vout: 0), fundingSat: 100_000,
            localMsat: local, remoteMsat: remote, localIsFunder: true, dustSat: 546, feePerKW: 1000, delay: 144, number: 0,
            openerPaymentBasepoint: key(3), accepterPaymentBasepoint: key(4),
            keys: .init(fundingLocal: key(1), fundingRemote: key(2), revocation: key(5), delayedLocal: key(6),
                paymentRemote: key(4), htlcLocal: key(7), htlcRemote: key(8)), format: format, htlcs: htlcs)
    }
    func testNegotiationRoundTripsBothFormatsAndLegacyPersistence() throws {
        let secrets = try ChannelSecrets()
        for format in [ChannelFormat.staticRemoteKey, .anchors] {
            let terms = try secrets.terms(capacity: 100_000, format: format)
            let open = ChannelNegotiation.Open(chain: chain, temporaryID: Data(repeating: 1, count: 32),
                capacity: 100_000, pushMsat: 0, feePerKW: 1000, terms: terms)
            let parsed = try ChannelNegotiation.Open(message: open.message())
            XCTAssertEqual(parsed.terms.format, format)
            let accept = ChannelNegotiation.Accept(temporaryID: open.temporaryID, minimumDepth: 3, terms: parsed.terms)
            XCTAssertEqual(try ChannelNegotiation.Accept(message: accept.message()).terms.format, format)
            let restored = try JSONDecoder().decode(ChannelTerms.self, from: JSONEncoder().encode(terms))
            XCTAssertEqual(restored.format, format)
        }
        let legacy = try secrets.terms(capacity: 100_000)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "negotiatedFormat")
        XCTAssertEqual(try JSONDecoder().decode(ChannelTerms.self, from: JSONSerialization.data(withJSONObject: object)).format, .staticRemoteKey)
        XCTAssertThrowsError(try ChannelFormat(features: LightningFeatures(bits: [12, 20])))
        XCTAssertThrowsError(try ChannelFormat(features: LightningFeatures(bits: [12, 22, 50])))
    }
    func testAnchorCommitmentHasExpectedAmountsAndScriptVariants() throws {
        let p = try parameters(), c = try ChannelTransactions.commitment(p)
        XCTAssertEqual(c.actualFeeSat, 1124)
        XCTAssertEqual(c.transaction.outputs.filter { $0.value == 330 }.count, 2)
        XCTAssertEqual(c.transaction.outputs.reduce(0) { $0 + $1.value }, 98_876)
        let anchor = try ChannelScripts.anchor(fundingKey: key(1))
        XCTAssertEqual(anchor.bytes, Data([33]) + (try key(1)) + Data([0xac, 0x73, 0x64, 0x60, 0xb2, 0x68]))
        let remote = try ChannelScripts.remote(paymentKey: key(4))
        XCTAssertEqual(remote.bytes, Data([33]) + (try key(4)) + Data([0xad, 0x51, 0xb2]))
        XCTAssertTrue(c.transaction.outputs.contains { $0.scriptPubKey == ChannelScripts.witnessScriptHash(remote) })
        let localOnly = try ChannelTransactions.commitment(parameters(local: 100_000_000, remote: 0))
        XCTAssertEqual(localOnly.transaction.outputs.filter { $0.value == 330 }.count, 1)
        XCTAssertEqual(localOnly.actualFeeSat, 1454, "omitted remote anchor remains part of the funder's deducted reserve")
        let legacy = try ChannelTransactions.commitment(parameters(format: .staticRemoteKey))
        XCTAssertEqual(legacy.actualFeeSat, 724)
        XCTAssertFalse(legacy.transaction.outputs.contains { $0.value == 330 })
    }
    func testAnchorHTLCsAreZeroFeeWithSingleAnyoneCanPayAndOneBlockDelay() throws {
        for offered in [true, false] {
            let preimage = Data(repeating: 42, count: 32)
            let htlc = ChannelTransactions.HTLC(id: 0, offered: offered, amountMsat: 546_000,
                paymentHash: ChannelKeys.hash(preimage), expiry: 50)
            let commitment = try ChannelTransactions.commitment(parameters(local: 89_454_000, htlcs: [htlc]))
            let output = try XCTUnwrap(commitment.htlcOutputs.first)
            let stage = try ChannelTransactions.htlcTransaction(commitment: commitment, output: output)
            XCTAssertEqual(stage.inputs[0].sequence, 1)
            XCTAssertEqual(stage.outputs[0].value, 546)
            XCTAssertEqual(stage.locktime, offered ? 50 : 0)
            XCTAssertEqual(output.witnessScript.bytes.suffix(5), Data([0x68, 0x51, 0xb2, 0x75, 0x68]))
            let digest = try ChannelRecovery.htlcDigest(commitment: commitment, output: output)
            let local = try ChannelKeys.sign(digest: digest, secret: Data(repeating: 7, count: 32))
            let remote = try ChannelKeys.sign(digest: digest, secret: Data(repeating: 8, count: 32))
            let signed = try ChannelRecovery.signedHTLC(commitment: commitment, output: output, localSignature: local,
                remoteSignature: remote, preimage: offered ? nil : preimage)
            XCTAssertEqual(signed.inputs[0].witness[1].last, 0x83)
            XCTAssertEqual(signed.inputs[0].witness[2].last, 0x83)
            var augmented = signed
            augmented.inputs.append(.init(previousOutput: .init(txid: Data(repeating: 33, count: 32), vout: 0), scriptSig: Data(), sequence: 0xfffffffd))
            augmented.outputs.append(.init(value: 1000, scriptPubKey: Data([0x51, 32]) + Data(repeating: 1, count: 32)))
            XCTAssertEqual(try SighashBIP143.sighash(tx: augmented, inputIndex: 0, scriptCode: output.witnessScript.bytes,
                value: 546, hashType: .singleAnyoneCanPay), digest)
            augmented.outputs[0].value -= 1
            XCTAssertNotEqual(try SighashBIP143.sighash(tx: augmented, inputIndex: 0, scriptCode: output.witnessScript.bytes,
                value: 546, hashType: .singleAnyoneCanPay), digest)
        }
    }
    private func channelFixture(format: ChannelFormat = .anchors) throws -> ChannelState {
        let alice = try ChannelSecrets(), bob = try ChannelSecrets()
        var channel = try ChannelState(peer: key(2), temporaryID: Data(repeating: 3, count: 32), capacity: 100_000,
            pushMsat: 0, feePerKW: 1000, isFunder: true, secrets: alice, local: alice.terms(capacity: 100_000, format: format),
            remote: bob.terms(capacity: 100_000, format: format), phase: .ready)
        channel.fundingTxid = Data(repeating: 9, count: 32); channel.fundingOutput = 0
        channel.fundingIsConfirmed = true; channel.localReady = true; channel.remoteReady = true
        let c = try channel.commitment(localOwner: true), digest = try ChannelTransactions.fundingDigest(c)
        channel.signedCommitment = try ChannelTransactions.signed(c,
            localSignature: ChannelKeys.sign(digest: digest, secret: alice.funding),
            remoteSignature: ChannelKeys.sign(digest: digest, secret: bob.funding)).serialized(includeWitness: true)
        channel.recovery = .init(destination: Data([0x51, 32]) + Data(repeating: 1, count: 32), feeSat: 500)
        return channel
    }
    private func engine(_ channel: ChannelState, journal: AnchorJournal) throws -> LightningEngine {
        var state = LightningEngine.State(chain: chain, nodeSecret: Data(repeating: 1, count: 32))
        state.channels = [channel]; journal.bytes = try JSONEncoder().encode(state)
        return try LightningEngine(chain: chain, journal: journal)
    }
    private func coins() throws -> [WalletUTXO] {
        let outputKey = try ChannelKeys.publicKey(secret: walletSecret).suffix(32)
        return [.init(txid: Data(repeating: 44, count: 32), vout: 0, amount: 50_000,
            scriptPubKey: Data([0x51, 32]) + outputKey, chain: .receive, index: 0, height: 1)]
    }
    private func sign(_ quote: AnchorFeeBump) throws -> Transaction {
        var tx = try Transaction.decode(quote.unsignedTransaction)
        let spent = try quote.spentOutputs()
        for index in tx.inputs.indices.dropFirst() {
            tx.inputs[index].witness = try Signer.witness(tx: tx, inputIndex: index, spentOutputs: spent,
                tweakedPrivateKey: walletSecret, auxiliaryRand: Data(repeating: 0, count: 32))
        }
        return tx
    }
    func testFeeBumpPreviewCommitRestartReplacementAndReservation() async throws {
        let channel = try channelFixture(), journal = AnchorJournal(), engine = try engine(channel, journal: journal)
        try await engine.chainCaughtUp()
        let before = journal.bytes
        let quote = try await engine.anchorFeeBumpQuote(id: Data(repeating: 22, count: 32), channelID: channel.id,
            peer: channel.peer, coins: coins(), destination: channel.recovery!.destination, feeRateSatPerVByte: 10, totalFeeLimitSat: 20_000)
        XCTAssertEqual(before, journal.bytes)
        XCTAssertLessThanOrEqual(quote.packageFeeSat, quote.totalFeeLimitSat)
        XCTAssertEqual(quote.selected, try coins())
        XCTAssertThrowsError(try AnchorFeeBumpBuilder.validate(AnchorFeeBump(id: quote.id, channelID: quote.channelID, kind: quote.kind,
            parentTransaction: quote.parentTransaction, unsignedTransaction: quote.unsignedTransaction, selected: quote.selected,
            feeSat: quote.feeSat + 1, parentFeeSat: quote.parentFeeSat, totalFeeLimitSat: quote.totalFeeLimitSat, replacesTxid: nil)))
        let events = try await engine.commitAnchorFeeBump(quote, peer: channel.peer, walletSignedTransaction: sign(quote))
        XCTAssertEqual(events.count, 2)
        let stored = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(journal.bytes))
        let saved = try XCTUnwrap(stored.channels[0].feeBumps?.first)
        XCTAssertNotNil(saved.signedTransaction); XCTAssertEqual(stored.channels[0].phase, .closing)
        let background = try LightningBackgroundSnapshot.make(stored)
        let rawChild = try XCTUnwrap(saved.signedTransaction)
        XCTAssertTrue(background.channels[0].spends.contains { $0.transaction == rawChild })
        let backgroundChild = try XCTUnwrap(background.channels[0].spends.first { $0.transaction == rawChild })
        XCTAssertTrue(try ChannelResolution.available(backgroundChild, confirmed: [], height: 0),
            "locked CPFP must relay with its pre-authorized unconfirmed commitment")


        let reserved = try await engine.reservedAnchorOutpoints()
        XCTAssertEqual(reserved, Set(try coins().map(\.outpoint)))
        let restarted = try LightningEngine(chain: chain, journal: journal)
        do { _ = try await restarted.pendingRecoveryBroadcasts(); XCTFail() } catch {}
        try await restarted.chainCaughtUp()
        let resumedEvents = try await restarted.pendingRecoveryBroadcasts()
        XCTAssertEqual(resumedEvents.count, 2)
        let replace = try await restarted.anchorFeeBumpQuote(id: Data(repeating: 23, count: 32), channelID: channel.id,
            peer: channel.peer, coins: coins(), destination: channel.recovery!.destination, feeRateSatPerVByte: 15,
            totalFeeLimitSat: 20_000, replacingTxid: saved.transaction().txid)
        XCTAssertGreaterThan(replace.feeSat, quote.feeSat)
        _ = try await restarted.commitAnchorFeeBump(replace, peer: channel.peer, walletSignedTransaction: sign(replace))
        let pending = try await restarted.pendingRecoveryBroadcasts()
        XCTAssertEqual(pending.count, 2)
        let latest = try await restarted.anchorFeeBumps(channelID: channel.id, peer: channel.peer)
        XCTAssertEqual(latest.count, 2)
        do { _ = try await restarted.anchorFeeBumpQuote(id: Data(repeating: 24, count: 32), channelID: channel.id,
            peer: channel.peer, coins: coins(), destination: channel.recovery!.destination, feeRateSatPerVByte: 15,
            totalFeeLimitSat: 20_000); XCTFail("competing quote reused reserved wallet coin") } catch {}
    }
    func testFeeBumpRejectsWrongSignaturesCapsAndPersistenceFailures() async throws {
        let channel = try channelFixture(), journal = AnchorJournal(), engine = try engine(channel, journal: journal)
        try await engine.chainCaughtUp()
        let before = journal.bytes
        do { _ = try await engine.anchorFeeBumpQuote(id: Data(repeating: 22, count: 32), channelID: channel.id,
            peer: channel.peer, coins: coins(), destination: channel.recovery!.destination, feeRateSatPerVByte: 10,
            totalFeeLimitSat: 2000); XCTFail("package exceeds total cap") } catch {}
        let quote = try await engine.anchorFeeBumpQuote(id: Data(repeating: 22, count: 32), channelID: channel.id,
            peer: channel.peer, coins: coins(), destination: channel.recovery!.destination, feeRateSatPerVByte: 10, totalFeeLimitSat: 20_000)
        var signed = try sign(quote); signed.inputs[1].witness[0][0] ^= 1
        do { _ = try await engine.commitAnchorFeeBump(quote, peer: channel.peer, walletSignedTransaction: signed); XCTFail() } catch {}
        XCTAssertEqual(before, journal.bytes)
        journal.failing = true
        do { _ = try await engine.commitAnchorFeeBump(quote, peer: channel.peer, walletSignedTransaction: sign(quote)); XCTFail() }
        catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
        XCTAssertEqual(before, journal.bytes)
        do { _ = try await engine.pendingRecoveryBroadcasts(); XCTFail() }
        catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
    }
    func testAnchorHTLCFeeBumpPreservesPeerSignaturesAndClaimAcrossRestart() async throws {
        var channel = try channelFixture()
        let bob = try ChannelSecrets()
        channel.remote = try bob.terms(capacity: channel.capacity, format: .anchors)
        channel.localNumber = 1
        let htlc = ChannelTransactions.HTLC(id: 0, offered: true, amountMsat: 5_000_000,
            paymentHash: ChannelKeys.hash(Data(repeating: 42, count: 32)), expiry: 10)
        channel.updates = [.init(change: .add(htlc, onion: Data()), fromLocal: true,
            localNumber: 1, remoteNumber: 0, remoteAcknowledged: true)]
        let commitment = try channel.commitment(localOwner: true)
        let fundingDigest = try ChannelTransactions.fundingDigest(commitment)
        channel.signedCommitment = try ChannelTransactions.signed(commitment,
            localSignature: ChannelKeys.sign(digest: fundingDigest, secret: channel.secrets.funding),
            remoteSignature: ChannelKeys.sign(digest: fundingDigest, secret: bob.funding)).serialized(includeWitness: true)
        let output = try XCTUnwrap(commitment.htlcOutputs.first)
        let digest = try ChannelRecovery.htlcDigest(commitment: commitment, output: output)
        let point = try channel.secrets.point(1)
        let localSecret = try ChannelKeys.derivedPrivateKey(baseSecret: channel.secrets.htlc, commitmentPoint: point)
        let remoteSecret = try ChannelKeys.derivedPrivateKey(baseSecret: bob.htlc, commitmentPoint: point)
        let remoteSignature = try ChannelKeys.sign(digest: digest, secret: remoteSecret)
        channel.localHTLCSignatures = [remoteSignature]
        let stage = try ChannelRecovery.signedHTLC(commitment: commitment, output: output,
            localSignature: ChannelKeys.sign(digest: digest, secret: localSecret), remoteSignature: remoteSignature)
        XCTAssertFalse(try ChannelResolution.available(.init(stage, delay: 1, height: 10),
            confirmed: [.init(height: 1, tx: commitment.transaction)], height: 10),
            "locked/foreground monitors must wait for a funded anchor HTLC stage")
        channel.observedFundingSpend = channel.signedCommitment
        channel.phase = .recovering
        channel.resolutions = [.init(stage, delay: 1, height: 10)]
        var state = LightningEngine.State(chain: chain, nodeSecret: Data(repeating: 1, count: 32))
        state.channels = [channel]; state.scan.nextHeight = 3
        state.scan.transactions = [.init(height: 1, blockHash: Data(repeating: 1, count: 32), raw: channel.signedCommitment!)]
        let journal = AnchorJournal(try JSONEncoder().encode(state))
        let engine = try LightningEngine(chain: chain, journal: journal)
        try await engine.chainCaughtUp(height: 10)
        let candidates = try await engine.feeBumpableHTLCs(channelID: channel.id, peer: channel.peer)
        XCTAssertEqual(candidates, [stage.txid])
        let quote = try await engine.anchorFeeBumpQuote(id: Data(repeating: 25, count: 32), channelID: channel.id,
            peer: channel.peer, coins: coins(), destination: channel.recovery!.destination,
            feeRateSatPerVByte: 10, totalFeeLimitSat: 20_000, htlcTransactionID: stage.txid)
        XCTAssertEqual(quote.kind, .htlc)
        let augmented = try sign(quote)
        XCTAssertEqual(augmented.inputs[0], stage.inputs[0])
        XCTAssertEqual(augmented.outputs[0], stage.outputs[0])
        XCTAssertEqual(try SighashBIP143.sighash(tx: augmented, inputIndex: 0, scriptCode: output.witnessScript.bytes,
            value: 5000, hashType: .singleAnyoneCanPay), digest)
        let events = try await engine.commitAnchorFeeBump(quote, peer: channel.peer, walletSignedTransaction: augmented)
        XCTAssertEqual(events.count, 1)
        let restarted = try LightningEngine(chain: chain, journal: journal)
        try await restarted.chainCaughtUp(height: 10)
        let saved = try await restarted.anchorFeeBumps(channelID: channel.id, peer: channel.peer)
        XCTAssertEqual(try saved.first?.transaction(), augmented)
        let observed = ChannelResolution.Confirmed(height: 2, tx: augmented)
        let context = ChannelResolution.Context(channel: channel, policy: channel.recovery!,
            confirmed: [observed], preimages: [])
        let descendants = try context.candidates(parent: commitment.transaction)
        XCTAssertTrue(try descendants.contains { try Transaction.decode($0.transaction).inputs[0].previousOutput.txid == augmented.txid },
            "an augmented HTLC txid still produces its wallet's delayed claim")
    }

    func testReplacementCannotTransferReservationsToAnotherHTLC() throws {
        let htlcs = [UInt64(0), 1].map { id in
            ChannelTransactions.HTLC(id: id, offered: true, amountMsat: 5_000_000,
                paymentHash: ChannelKeys.hash(Data(repeating: UInt8(id + 1), count: 32)), expiry: 50)
        }
        let commitment = try ChannelTransactions.commitment(parameters(local: 80_000_000, htlcs: htlcs))
        XCTAssertEqual(commitment.htlcOutputs.count, 2)
        let first = try ChannelTransactions.htlcTransaction(commitment: commitment, output: commitment.htlcOutputs[0])
        let second = try ChannelTransactions.htlcTransaction(commitment: commitment, output: commitment.htlcOutputs[1])
        let firstTarget = AnchorFeeBumpBuilder.Target(parent: commitment.transaction, transaction: first,
            parentFee: 0, kind: .htlc, anchorScript: nil)
        let quote = try AnchorFeeBumpBuilder.quote(id: Data(repeating: 26, count: 32), channelID: Data(repeating: 1, count: 32),
            target: firstTarget, coins: coins(), destination: Data([0x51, 32]) + Data(repeating: 1, count: 32),
            rate: 10, limit: 20_000, replacing: nil)
        XCTAssertNoThrow(try AnchorFeeBumpBuilder.validateReplacementTarget(firstTarget, replacing: quote))
        let secondTarget = AnchorFeeBumpBuilder.Target(parent: commitment.transaction, transaction: second,
            parentFee: 0, kind: .htlc, anchorScript: nil)
        XCTAssertThrowsError(try AnchorFeeBumpBuilder.validateReplacementTarget(secondTarget, replacing: quote))
        XCTAssertThrowsError(try AnchorFeeBumpBuilder.quote(id: Data(repeating: 27, count: 32), channelID: quote.channelID,
            target: secondTarget, coins: coins(), destination: Data([0x51, 32]) + Data(repeating: 1, count: 32),
            rate: 15, limit: 20_000, replacing: quote))
    }

    func testWalletAndEngineCrashWindowsRetainTheExactApprovedSpend() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let walletURL = root.appending(path: "wallet.json"), keys = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: walletURL, keyStore: keys)
        let channel = try channelFixture(), journal = AnchorJournal(), original = try engine(channel, journal: journal)
        try await original.chainCaughtUp()
        let index = await wallet.nextChangeIndex
        let destination = try await wallet.scriptPubKey(chain: .change, index: index)
        let coins = try await wallet.recoverySpendCoins(requestID: "approved-anchor")
        let approved = try await original.anchorFeeBumpQuote(id: Data(repeating: 28, count: 32), channelID: channel.id,
            peer: channel.peer, coins: coins, destination: destination, feeRateSatPerVByte: 10, totalFeeLimitSat: 20_000)
        let source = try approved.spentOutputs()[0]
        let reserved = try await wallet.reserveRecoverySpend(requestID: "approved-anchor",
            transaction: Transaction.decode(approved.unsignedTransaction), coins: approved.selected,
            externalOutput: .init(value: source.amount, scriptPubKey: source.scriptPubKey),
            feeLimit: Int64(approved.totalFeeLimitSat - approved.parentFeeSat))
        try await rejectChangedReservation(wallet, approved: approved, source: .init(value: source.amount + 1, scriptPubKey: source.scriptPubKey),
            feeLimit: reserved.feeLimit)
        try await rejectChangedReservation(wallet, approved: approved,
            source: .init(value: source.amount, scriptPubKey: Data([0, 32]) + Data(repeating: 99, count: 32)), feeLimit: reserved.feeLimit)
        try await rejectChangedReservation(wallet, approved: approved,
            source: .init(value: source.amount, scriptPubKey: source.scriptPubKey), feeLimit: reserved.feeLimit + 1)

        // A crash before submission still leaves signed bytes and excluded
        // inputs; reconnect uses that exact authorized child, without selection.
        let reopened = try Wallet.open(storageURL: walletURL, keyStore: keys)
        let spendableAfterReservation = await reopened.spendableUtxos
        XCTAssertTrue(spendableAfterReservation.isEmpty)
        let reservations = await reopened.recoverySpendReservations
        let durable = try XCTUnwrap(reservations.first)
        XCTAssertEqual(durable.rawTransaction, reserved.rawTransaction)
        XCTAssertFalse(durable.submitted)
        try await reopened.markRecoverySpendSubmitted(requestID: durable.requestID)
        journal.failing = true
        do {
            _ = try await original.commitAnchorFeeBump(approved, peer: channel.peer, walletSignedTransaction: durable.transaction())
            XCTFail("An engine write failure must leave no broadcast event")
        } catch { XCTAssertEqual(error as? LightningError, .storageFailed) }
        let walletAfterFailure = try Wallet.open(storageURL: walletURL, keyStore: keys)
        let spendableAfterFailure = await walletAfterFailure.spendableUtxos
        let submittedAfterFailure = await walletAfterFailure.recoverySpendReservations.first?.submitted
        XCTAssertTrue(spendableAfterFailure.isEmpty)
        XCTAssertEqual(submittedAfterFailure, true)

        journal.failing = false
        let restarted = try LightningEngine(chain: chain, journal: journal)
        try await restarted.chainCaughtUp()
        let beforeCommit = try await restarted.pendingRecoveryBroadcasts()
        XCTAssertTrue(beforeCommit.isEmpty)
        let events = try await restarted.commitAnchorFeeBump(approved, peer: channel.peer, walletSignedTransaction: durable.transaction())
        guard let last = events.last, case .broadcastRecovery(_, let raw) = last else { return XCTFail("Missing committed child") }
        let child = try Transaction.decode(raw)
        XCTAssertEqual(child.serialized(includeWitness: false), try durable.transaction().serialized(includeWitness: false))
        XCTAssertEqual(child.inputs[1].witness, try durable.transaction().inputs[1].witness)
        try await walletAfterFailure.commitRecoverySpendBroadcast(requestID: durable.requestID, transaction: child)
        let finalWallet = try Wallet.open(storageURL: walletURL, keyStore: keys)
        let finalHistory = await finalWallet.history
        let finalCoins = await finalWallet.spendableUtxos
        XCTAssertEqual(finalHistory.filter { $0.txid == child.txid }.count, 1)
        XCTAssertFalse(finalCoins.contains { approved.selected.map(\.outpoint).contains($0.outpoint) })
        let finalEngine = try LightningEngine(chain: chain, journal: journal)
        try await finalEngine.chainCaughtUp()
        let resumed = try await finalEngine.pendingRecoveryBroadcasts()
        XCTAssertEqual(resumed.count, 2)
    }
    private func rejectChangedReservation(_ wallet: Wallet, approved: AnchorFeeBump, source: Transaction.Output, feeLimit: Int64) async throws {
        do {
            _ = try await wallet.reserveRecoverySpend(requestID: "approved-anchor", transaction: Transaction.decode(approved.unsignedTransaction),
                coins: approved.selected, externalOutput: source, feeLimit: feeLimit)
            XCTFail("Idempotent request changed its authorized fee or external output")
        } catch { XCTAssertEqual(error as? FundingReservationError, .requestChanged) }
    }

    func testLastDurableFeeBumpCanRetryAtIntentLimitWithoutAcceptingAnotherIntent() async throws {
        let channel = try channelFixture(), journal = AnchorJournal(), original = try engine(channel, journal: journal)
        try await original.chainCaughtUp()
        var last: AnchorFeeBump?, lastRaw: Data?, replacing: Data?
        for offset in 0..<64 {
            let quote = try await original.anchorFeeBumpQuote(id: Data(repeating: UInt8(offset + 40), count: 32),
                channelID: channel.id, peer: channel.peer, coins: coins(), destination: channel.recovery!.destination,
                feeRateSatPerVByte: Double(offset + 4), totalFeeLimitSat: 50_000, replacingTxid: replacing)
            let events = try await original.commitAnchorFeeBump(quote, peer: channel.peer, walletSignedTransaction: sign(quote))
            guard let event = events.last, case .broadcastRecovery(_, let raw) = event else { return XCTFail("missing signed child") }
            last = quote; lastRaw = raw; replacing = try quote.transaction().txid
        }
        let committed = try XCTUnwrap(last), raw = try XCTUnwrap(lastRaw)
        let restarted = try LightningEngine(chain: chain, journal: journal)
        try await restarted.chainCaughtUp()
        let retried = try await restarted.commitAnchorFeeBump(committed, peer: channel.peer, walletSignedTransaction: sign(committed))
        guard let event = retried.last, case .broadcastRecovery(_, let retryRaw) = event else { return XCTFail("retry lost committed child") }
        XCTAssertEqual(retryRaw, raw)
        let records = try await restarted.anchorFeeBumps(channelID: channel.id, peer: channel.peer)
        XCTAssertEqual(records.count, 64)
        do {
            _ = try await restarted.anchorFeeBumpQuote(id: Data(repeating: 111, count: 32), channelID: channel.id,
                peer: channel.peer, coins: coins(), destination: channel.recovery!.destination,
                feeRateSatPerVByte: 70, totalFeeLimitSat: 50_000, replacingTxid: replacing)
            XCTFail("intent limit admitted another preview")
        } catch { XCTAssertEqual(error as? LightningError, .invalidState) }
        var lost = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(journal.bytes))
        lost.channels[0].dataLossDetected = true
        let lostJournal = AnchorJournal(); lostJournal.bytes = try JSONEncoder().encode(lost)
        let protected = try LightningEngine(chain: chain, journal: lostJournal)
        try await protected.chainCaughtUp()
        do {
            _ = try await protected.commitAnchorFeeBump(committed, peer: channel.peer, walletSignedTransaction: sign(committed))
            XCTFail("saved-ID retry bypassed data-loss protection")
        } catch { XCTAssertEqual(error as? LightningError, .invalidState) }
    }

}
