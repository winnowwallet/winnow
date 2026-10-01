import Foundation
import WalletCore
import XCTest
@testable import LightningCore

private final class ZeroConfStore: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    func load() -> Data? { lock.withLock { bytes } }
    func store(_ value: Data) { lock.withLock { bytes = value } }
}
private final class ZeroConfJournal: LightningJournal {
    let store: ZeroConfStore
    init(_ store: ZeroConfStore) { self.store = store }
    func load() -> Data? { store.load() }
    func store(_ snapshot: Data) throws { store.store(snapshot) }
}

/// A just-in-time channel: Alice is the provider (funder) and Bob is Winnow,
/// which bought the channel and accepts it before its funding confirms.
final class ZeroConfChannelTests: XCTestCase, @unchecked Sendable {
    private let chain = NetworkParams.regtest.genesisHash
    private let size: UInt64 = 30_000_000, fee: UInt64 = 3_514_000
    private var aliceKey: Data { try! ChannelKeys.publicKey(secret: Data(repeating: 1, count: 32)) }
    private var bobKey: Data { try! ChannelKeys.publicKey(secret: Data(repeating: 2, count: 32)) }
    private var carolKey: Data { try! ChannelKeys.publicKey(secret: Data(repeating: 3, count: 32)) }
    private var now: UInt64 { UInt64(Date().timeIntervalSince1970) }

    private struct Pair {
        let alice: LightningEngine, bob: LightningEngine
        let aliceStore: ZeroConfStore, bobStore: ZeroConfStore
    }
    private func engine(_ store: ZeroConfStore, secret: UInt8, peers: [Data]) async throws -> LightningEngine {
        let engine = try LightningEngine(chain: chain, nodeSecret: Data(repeating: secret, count: 32), journal: ZeroConfJournal(store))
        try await engine.chainCaughtUp()
        for peer in peers { try await engine.peerInitialized(peer, features: .jitClient) }
        return engine
    }
    private func pair() async throws -> Pair {
        let aliceStore = ZeroConfStore(), bobStore = ZeroConfStore()
        return Pair(alice: try await engine(aliceStore, secret: 1, peers: [bobKey]),
                    bob: try await engine(bobStore, secret: 2, peers: [aliceKey, carolKey]),
                    aliceStore: aliceStore, bobStore: bobStore)
    }
    private func offer(validFor seconds: UInt64 = 3600, at time: UInt64? = nil) throws -> LightningJIT.Offer {
        let formatter = ISO8601DateFormatter()
        let start = time ?? now
        let entry: [String: Any] = ["min_fee_msat": "3514000", "proportional": 14_000,
            "valid_until": formatter.string(from: Date(timeIntervalSince1970: TimeInterval(start + seconds))),
            "min_lifetime": 13_140, "max_client_to_self_delay": 512, "min_payment_size_msat": "3515000",
            "max_payment_size_msat": "16000000000", "promise": "test"]
        let menu = try LightningJIT.Menu.decode(JSONSerialization.data(withJSONObject: ["opening_fee_params_menu": [entry]]), now: start)
        return try XCTUnwrap(menu.offers.first)
    }
    private func terms(provider: Data? = nil, offer: LightningJIT.Offer? = nil) throws -> LightningEngine.JITTerms {
        LightningEngine.JITTerms(provider: provider ?? aliceKey, offer: try offer ?? self.offer(),
            purchase: .init(jitChannelScid: "800000x1x0", lspCltvExpiryDelta: 144, clientTrustsLsp: true), paymentSizeMsat: size)
    }
    @discardableResult
    private func buy(_ bob: LightningEngine, id: UInt8 = 40, provider: Data? = nil, offer: LightningJIT.Offer? = nil,
                     at time: UInt64? = nil) async throws -> Bolt11Invoice.Decoded {
        let invoice = try await bob.createJITInvoice(id: Data(repeating: id, count: 32), terms: terms(provider: provider, offer: offer),
            recoveryDestination: ChannelScripts.witnessKeyHash(bobKey), recoveryFeeSat: 500, network: .regtest, now: time ?? now)
        return try Bolt11Invoice.decode(invoice, network: .regtest)
    }
    private func state(_ store: ZeroConfStore) throws -> LightningEngine.State {
        try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(store.load()))
    }
    /// The provider opens, Bob accepts, the provider funds; returns Bob's
    /// accept_channel and the funding transaction.
    private func open(_ p: Pair, capacity: UInt64 = 100_000) async throws -> (accept: ChannelNegotiation.Accept, funding: Transaction) {
        let temporary = try await p.alice.openChannel(peer: bobKey, capacitySat: capacity, feePerKW: 1000)
        _ = try await p.bob.receive(peer: aliceKey, message: p.alice.pendingMessages(peer: bobKey).last!.message)
        let acceptMessage = try await p.bob.pendingMessages(peer: aliceKey).last!.message
        let events = try await p.alice.receive(peer: bobKey, message: acceptMessage)
        guard case .fundingRequired(_, _, let script) = try XCTUnwrap(events.first) else { throw LightningError.invalidState }
        let funding = Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: Data(repeating: 9, count: 32), vout: 1),
            scriptSig: Data(), sequence: .max, witness: [Data([1])])], outputs: [.init(value: Int64(capacity), scriptPubKey: script)],
            locktime: 0)
        try await p.alice.provideFunding(temporaryID: temporary, peer: bobKey, transaction: funding, output: 0)
        return (try ChannelNegotiation.Accept(message: acceptMessage), funding)
    }
    /// Bob signs; the provider sends channel_ready (with an alias) without
    /// waiting for a confirmation, as a zero-conf funder does.
    private func ready(_ p: Pair, funding: Transaction, alias: UInt64 = 0xA11CE) async throws -> Data {
        let fundingCreated = try await p.alice.pendingMessages(peer: bobKey).first { $0.message.type == 34 }!.message
        _ = try await p.bob.receive(peer: aliceKey, message: fundingCreated)
        let signed = try await p.bob.pendingMessages(peer: aliceKey).first { $0.message.type == 35 }!.message
        _ = try await p.alice.receive(peer: bobKey, message: signed)
        let aliceChannels = await p.alice.channels()
        let id = try XCTUnwrap(aliceChannels.first(where: { $0.phase != .closed })?.id)
        _ = try await p.alice.fundingConfirmed(channelID: id, peer: bobKey, transaction: funding, confirmations: 1)
        let aliceReady = try await p.alice.pendingMessages(peer: bobKey).first { $0.message.type == 36 }!.message
        var withAlias = LightningWire.Writer(); withAlias.append(aliceReady.payload)
        var value = LightningWire.Writer(); value.u64(alias)
        try withAlias.tlvs([.init(type: 1, value: value.data)])
        _ = try await p.bob.receive(peer: aliceKey, message: .init(type: 36, payload: withAlias.data))
        if let bobReady = try await p.bob.pendingMessages(peer: aliceKey).first(where: { $0.message.type == 36 }) {
            _ = try await p.alice.receive(peer: bobKey, message: bobReady.message)
        }
        try await p.alice.configureRecovery(channelID: id, peer: bobKey, destination: ChannelScripts.witnessKeyHash(aliceKey), feeSat: 500)
        return id
    }
    /// Like a live session, each message is delivered once.
    private var aliceSent = Set<UInt64>(), bobSent = Set<UInt64>()
    /// Delivers payment traffic; open() and ready() hand-deliver the opening.
    private func pump(_ p: Pair, rounds: Int = 6) async throws {
        let opening: Set<UInt16> = [32, 33, 34, 35, 36]
        for _ in 0..<rounds {
            for item in try await p.alice.pendingMessages(peer: bobKey)
            where !aliceSent.contains(item.sequence) && !opening.contains(item.message.type) {
                _ = try await p.bob.receive(peer: aliceKey, message: item.message); aliceSent.insert(item.sequence)
            }
            for item in try await p.bob.pendingMessages(peer: aliceKey)
            where !bobSent.contains(item.sequence) && !opening.contains(item.message.type) {
                _ = try await p.alice.receive(peer: bobKey, message: item.message); bobSent.insert(item.sequence)
            }
        }
    }
    /// The provider forwards the payer's payment minus its fee (bLIP-52).
    private func forward(_ p: Pair, channel: Data, invoice: Bolt11Invoice.Decoded, deliver: UInt64? = nil,
                         extraFee: UInt64? = nil, onionAmount: UInt64? = nil) async throws {
        let payload = try PaymentPayload(amountMsat: onionAmount ?? size, expiry: 200, secret: XCTUnwrap(invoice.paymentSecret))
        let onion = try OnionPacket.create(hops: [.init(publicKey: bobKey, payload: payload.bytes)], associatedData: invoice.paymentHash)
        _ = try await p.alice.offerHTLC(channelID: channel, peer: bobKey, amountMsat: deliver ?? size - fee,
                                        paymentHash: invoice.paymentHash, expiry: 200, onion: onion, extraFeeMsat: extraFee ?? fee)
        try await pump(p)
    }

    func testBoughtChannelWorksBeforeConfirmationAndKeepsOnlyTheAgreedFee() async throws {
        let p = try await pair()
        let invoice = try await buy(p.bob)
        XCTAssertEqual(invoice.amountMsat, size)
        XCTAssertEqual(invoice.minimumFinalDelta, 20, "bLIP-52 adds two blocks for the provider")
        XCTAssertFalse(invoice.features.supports(16), "single-part: no basic_mpp")
        let hint = try XCTUnwrap(invoice.routes.first?.first)
        XCTAssertEqual(hint.peer, aliceKey)
        XCTAssertEqual(hint.shortChannelID, 800_000 << 40 | 1 << 16)
        XCTAssertEqual([hint.baseMsat, hint.proportionalMillionths], [0, 0])
        XCTAssertEqual(hint.expiryDelta, 144)

        let (accept, funding) = try await open(p)
        XCTAssertEqual(accept.minimumDepth, 0, "a bought channel is accepted at depth zero")
        let id = try await ready(p, funding: funding)
        let fundee = try XCTUnwrap(state(p.bobStore).channels.first)
        XCTAssertNotNil(fundee.zeroConf)
        XCTAssertNotNil(fundee.recovery, "the payment can be claimed the moment it arrives")
        XCTAssertNotNil(fundee.localAlias)
        XCTAssertEqual(fundee.remoteAlias, 0xA11CE)
        XCTAssertFalse(fundee.fundingIsConfirmed)
        XCTAssertFalse(try state(p.bobStore).scan.rescanRequired, "a full rescan would outlast the forwarding window")
        let bobChannels = await p.bob.channels()
        XCTAssertEqual(bobChannels.first?.phase, .ready)
        XCTAssertEqual(bobChannels.first?.trustedUnconfirmed, true)

        try await forward(p, channel: id, invoice: invoice)
        let received = await p.bob.payments()
        XCTAssertEqual(received.map(\.phase), [.settled])
        XCTAssertEqual(received.first?.amountMsat, size - fee)
        XCTAssertEqual(received.first?.feeMsat, fee)
        XCTAssertEqual(try state(p.bobStore).jit?.first?.claimed, true)

        // The grant survives a restart and a reorg; it was never funding evidence.
        let restarted = try LightningEngine(chain: chain, journal: ZeroConfJournal(p.bobStore))
        try await restarted.blocksDisconnected(to: 0, hash: chain)
        try await restarted.chainCaughtUp()
        let afterReorg = await restarted.channels()
        XCTAssertEqual(afterReorg.first?.trustedUnconfirmed, true)
        XCTAssertNotNil(try state(p.bobStore).channels.first?.zeroConf)
    }

    func testOrdinaryChannelsStillWaitForConfirmations() async throws {
        let p = try await pair()
        let (accept, funding) = try await open(p)
        XCTAssertEqual(accept.minimumDepth, 3)
        let fundingCreated = try await p.alice.pendingMessages(peer: bobKey).first { $0.message.type == 34 }!.message
        _ = try await p.bob.receive(peer: aliceKey, message: fundingCreated)
        let pending = try await p.bob.pendingMessages(peer: aliceKey).map(\.message.type)
        XCTAssertFalse(pending.contains(36), "no channel_ready before confirmation")
        XCTAssertTrue(try state(p.bobStore).scan.rescanRequired)
        let channel = try XCTUnwrap(state(p.bobStore).channels.first)
        XCTAssertNil(channel.zeroConf); XCTAssertNil(channel.localAlias)
        _ = funding
    }

    func testZeroConfChannelTypeWithoutAPurchaseIsRefused() async throws {
        let p = try await pair()
        let terms = try ChannelSecrets().terms(capacity: 100_000, options: [.scidAlias, .zeroConf])
        let open = ChannelNegotiation.Open(chain: chain, temporaryID: Data(repeating: 5, count: 32), capacity: 100_000,
                                           pushMsat: 0, feePerKW: 1000, terms: terms)
        do { _ = try await p.bob.receive(peer: aliceKey, message: open.message()); XCTFail("zero-conf without a purchase") }
        catch { XCTAssertEqual(error as? LightningError, .invalidMessage) }
        // An alias-only channel_type is ordinary: accepted, waiting for confirmations, with our alias.
        let aliasOnly = ChannelNegotiation.Open(chain: chain, temporaryID: Data(repeating: 6, count: 32), capacity: 100_000,
            pushMsat: 0, feePerKW: 1000, terms: try ChannelSecrets().terms(capacity: 100_000, options: [.scidAlias]))
        _ = try await p.bob.receive(peer: aliceKey, message: aliasOnly.message())
        let pending = try await p.bob.pendingMessages(peer: aliceKey)
        let accept = try ChannelNegotiation.Accept(message: XCTUnwrap(pending.last).message)
        XCTAssertEqual(accept.minimumDepth, 3)
        XCTAssertEqual(accept.terms.options, [.scidAlias])
        XCTAssertNotNil(try state(p.bobStore).channels.last?.localAlias)
    }

    func testOnlyTheBoughtChannelFromTheProviderGetsTheGrant() async throws {
        let p = try await pair()
        try await buy(p.bob)
        // The provider forwards size - fee and rounds down to whole sats.
        let minimum = (size - fee) / 1000
        func accepted(capacity: UInt64, push: UInt64 = 0, from peer: Data? = nil, temporary: UInt8) async throws -> UInt32 {
            let terms = try ChannelSecrets().terms(capacity: capacity)
            let open = ChannelNegotiation.Open(chain: chain, temporaryID: Data(repeating: temporary, count: 32), capacity: capacity,
                                               pushMsat: push, feePerKW: 1000, terms: terms)
            _ = try await p.bob.receive(peer: peer ?? aliceKey, message: open.message())
            let pending = try await p.bob.pendingMessages(peer: peer ?? aliceKey)
            return try ChannelNegotiation.Accept(message: XCTUnwrap(pending.last).message).minimumDepth
        }
        let tooSmall = try await accepted(capacity: max(20_000, minimum - 1), temporary: 10)
        let pushed = try await accepted(capacity: 100_000, push: 1000, temporary: 11)
        let stranger = try await accepted(capacity: 100_000, from: carolKey, temporary: 12)
        let bought = try await accepted(capacity: minimum, temporary: 13)
        let second = try await accepted(capacity: 100_000, temporary: 14)
        XCTAssertEqual([tooSmall, pushed, stranger, bought, second], [3, 3, 3, 0, 3])
        XCTAssertEqual(try state(p.bobStore).jit?.first?.channel, Data(repeating: 13, count: 32))
    }

    func testExpiredPurchaseGrantsNothing() async throws {
        let p = try await pair()
        let past = now - 7200
        try await buy(p.bob, offer: offer(validFor: 3600, at: past), at: past)
        let (accept, _) = try await open(p)
        XCTAssertEqual(accept.minimumDepth, 3)
    }

    func testAbandonedNegotiationFreesThePurchase() async throws {
        let p = try await pair()
        try await buy(p.bob)
        let temporary = try await p.alice.openChannel(peer: bobKey, capacitySat: 100_000, feePerKW: 1000)
        _ = try await p.bob.receive(peer: aliceKey, message: p.alice.pendingMessages(peer: bobKey)[0].message)
        XCTAssertEqual(try state(p.bobStore).jit?.first?.channel, temporary)
        // The provider gives up on this attempt: Bob keeps the connection.
        var notice = LightningWire.Writer(); notice.append(temporary); notice.u16(4); notice.append(Data("gone".utf8))
        let kept = try await p.bob.rejectOpening(LightningPeerNotice(.init(type: 17, payload: notice.data)), peer: aliceKey)
        XCTAssertTrue(kept)
        XCTAssertNil(try state(p.bobStore).jit?.first?.channel)
        XCTAssertEqual(try state(p.bobStore).channels.first?.phase, .closed)

        // A reconnection likewise forgets an unfunded inbound channel.
        let (accept, _) = try await open(p)
        XCTAssertEqual(accept.minimumDepth, 0)
        let fundingCreated = try await p.alice.pendingMessages(peer: bobKey).first { $0.message.type == 34 }!.message
        _ = try await p.bob.receive(peer: aliceKey, message: fundingCreated)
        let again = try await p.alice.openChannel(peer: bobKey, capacitySat: 100_000, feePerKW: 1000)
        _ = try await p.bob.receive(peer: aliceKey, message: p.alice.pendingMessages(peer: bobKey).last!.message)
        await p.bob.peerDisconnected(aliceKey)
        try await p.bob.peerInitialized(aliceKey, features: .jitClient)
        let channels = try state(p.bobStore).channels
        XCTAssertEqual(channels.first(where: { $0.temporaryID == again })?.phase, .closed)
        XCTAssertNotEqual(channels.first(where: { $0.fundingTxid != nil })?.phase, .closed, "a funded channel is kept")
    }

    func testProviderMayKeepNoMoreThanTheAgreedFee() async throws {
        let p = try await pair()
        let invoice = try await buy(p.bob)
        let (_, funding) = try await open(p)
        let id = try await ready(p, funding: funding)
        try await forward(p, channel: id, invoice: invoice, deliver: size - fee - 1, extraFee: fee + 1)
        let received = await p.bob.payments()
        XCTAssertTrue(received.isEmpty, "an overcharging provider is refused")
        let failed = try state(p.aliceStore).channels.first { $0.id == id }?.updates.contains {
            if case .fail = $0.change { return true }; return false
        }
        XCTAssertEqual(failed, true)
    }

    func testShortPaymentWithoutADeclaredFeeIsRefused() async throws {
        let p = try await pair()
        let invoice = try await buy(p.bob)
        let (_, funding) = try await open(p)
        let id = try await ready(p, funding: funding)
        try await forward(p, channel: id, invoice: invoice, deliver: size - fee, extraFee: 0)
        let received = await p.bob.payments()
        XCTAssertTrue(received.isEmpty)
    }

    func testOrdinaryInvoicesIgnoreExtraFee() async throws {
        let p = try await pair()
        let invoice = try await buy(p.bob)
        let (_, funding) = try await open(p)
        let id = try await ready(p, funding: funding)
        try await forward(p, channel: id, invoice: invoice) // the bought payment fills the channel
        let ordinary = try await p.bob.registerReceive(id: Data(repeating: 77, count: 32), amountMsat: 1_000_000, expiry: 300)
        let payload = try PaymentPayload(amountMsat: 1_000_000, expiry: 200, secret: ordinary.paymentSecret)
        let onion = try OnionPacket.create(hops: [.init(publicKey: bobKey, payload: payload.bytes)], associatedData: ordinary.paymentHash)
        _ = try await p.alice.offerHTLC(channelID: id, peer: bobKey, amountMsat: 1_000_000, paymentHash: ordinary.paymentHash,
                                        expiry: 200, onion: onion, extraFeeMsat: 5)
        try await pump(p)
        let settled = await p.bob.payments().filter { $0.hash == ordinary.paymentHash }
        XCTAssertEqual(settled.map(\.phase), [.settled])
        XCTAssertEqual(settled.first?.amountMsat, 1_000_000)
        XCTAssertNil(settled.first?.feeMsat)
    }

    func testDeductionNeedsTheProvidersChannel() throws {
        let request = LightningEngine.ReceiveRequest(id: Data(repeating: 1, count: 32), preimage: Data(repeating: 2, count: 32),
            secret: Data(repeating: 3, count: 32), amountMsat: size, expiry: 100,
            jit: .init(provider: carolKey, maximumFeeMsat: fee))
        var channel = try XCTUnwrap(fundedChannel())
        let htlc = ChannelTransactions.HTLC(id: 0, offered: false, amountMsat: size - fee, paymentHash: Data(repeating: 4, count: 32), expiry: 100)
        channel.incomingExtraFee = [0: fee]
        XCTAssertNil(LightningEngine.deduction(htlc, request: request, channel: channel), "Alice is not the provider Bob bought from")
        let ordinary = LightningEngine.ReceiveRequest(id: request.id, preimage: request.preimage, secret: request.secret,
                                                      amountMsat: size, expiry: 100)
        XCTAssertEqual(LightningEngine.deduction(htlc, request: ordinary, channel: channel), 0)
        // extra_fee is exactly eight bytes.
        XCTAssertThrowsError(try LightningEngine.recordExtraFee([.init(type: 65537, value: Data(repeating: 1, count: 7))],
                                                                 id: 1, in: &channel))
        try LightningEngine.recordExtraFee([.init(type: 65537, value: Data([0, 0, 0, 0, 0, 0, 1, 0]))], id: 1, in: &channel)
        XCTAssertEqual(channel.incomingExtraFee?[1], 256)
    }
    private func fundedChannel() throws -> ChannelState {
        let secrets = try ChannelSecrets()
        return ChannelState(peer: aliceKey, temporaryID: Data(repeating: 8, count: 32), capacity: 100_000, pushMsat: 0, feePerKW: 1000,
                            isFunder: false, secrets: secrets, local: try secrets.terms(capacity: 100_000),
                            remote: try ChannelSecrets().terms(capacity: 100_000), phase: .ready)
    }

    func testAliasesRouteTheNextInvoiceBeforeConfirmation() async throws {
        let p = try await pair()
        let invoice = try await buy(p.bob)
        let (_, funding) = try await open(p)
        let id = try await ready(p, funding: funding, alias: 0xBEEF)
        try await forward(p, channel: id, invoice: invoice)
        // LDK signs its policy for the alias Bob sent, until the funding confirms.
        let bobAlias = try XCTUnwrap(state(p.bobStore).channels.first?.localAlias)
        try await p.bob.receiveChannelPolicy(peer: aliceKey, message: update(scid: bobAlias))
        let capacities = try await p.bob.invoiceCapacities(peer: aliceKey)
        let capacity = try XCTUnwrap(capacities.first)
        XCTAssertEqual(capacity.route.shortChannelID, 0xBEEF, "payers route with the provider's alias")
        XCTAssertEqual(capacity.route.baseMsat, 1000)
        XCTAssertEqual(capacity.route.expiryDelta, 40)
        let second = try await p.bob.createInvoice(id: Data(repeating: 41, count: 32), peer: aliceKey, amountSat: 1000,
                                                   network: .regtest, now: now)
        XCTAssertEqual(try Bolt11Invoice.decode(second, network: .regtest).routes.first?.first?.shortChannelID, 0xBEEF)
    }
    private func update(scid: UInt64) throws -> LightningWire.Message {
        var writer = LightningWire.Writer()
        writer.append(chain); writer.u64(scid); writer.u32(10); writer.u8(1)
        writer.u8(aliceKey.lexicographicallyPrecedes(bobKey) ? 0 : 1)
        writer.u16(40); writer.u64(1000); writer.u32(1000); writer.u32(250); writer.u64(98_000_000)
        let digest = ChannelKeys.hash(ChannelKeys.hash(writer.data))
        let signature = try ChannelKeys.compactSignature(ChannelKeys.sign(digest: digest, secret: Data(repeating: 1, count: 32)))
        return try .init(type: 258, payload: signature + writer.data)
    }

    func testNeverFundedEmptyChannelIsForgottenButAFundedOneIsKept() async throws {
        let p = try await pair()
        let invoice = try await buy(p.bob)
        let (_, funding) = try await open(p)
        _ = try await ready(p, funding: funding)
        var empty = try state(p.bobStore)
        try LightningEngine.forgetUnfundedZeroConf(height: 2015, in: &empty)
        XCTAssertEqual(empty.channels.first?.phase, .ready, "not yet two weeks")
        try LightningEngine.forgetUnfundedZeroConf(height: 2016, in: &empty)
        XCTAssertEqual(empty.channels.first?.phase, .closed)

        let bobChannels = await p.bob.channels()
        let id = try XCTUnwrap(bobChannels.first?.id)
        try await forward(p, channel: id, invoice: invoice)
        var funded = try state(p.bobStore)
        try LightningEngine.forgetUnfundedZeroConf(height: 5000, in: &funded)
        XCTAssertEqual(funded.channels.first?.phase, .ready, "a channel holding our payment is never forgotten")
    }

    func testRecoveryNeverCarriesAPurchaseOrAGrant() async throws {
        let p = try await pair()
        try await buy(p.bob)
        let (_, funding) = try await open(p)
        _ = try await ready(p, funding: funding)
        let backup = try await p.bob.recoveryBackup()
        XCTAssertNil(try backup.validatedState(chain: chain).jit)
        let restored = try LightningEngine.restoringRecovery(backup, chain: chain, journal: ZeroConfJournal(ZeroConfStore()))
        let channels = await restored.channels()
        XCTAssertEqual(channels.first?.trustedUnconfirmed, false, "a restored channel waits for its funding")
    }

    func testInvoiceExpiresBeforeTheFeeTerms() throws {
        XCTAssertEqual(try LightningEngine.jitInvoiceLifetime(validUntil: 10_000 + 3_000, now: 10_000), 2_970)
        XCTAssertEqual(try LightningEngine.jitInvoiceLifetime(validUntil: 10_000 + 86_400, now: 10_000), 3_600)
        XCTAssertThrowsError(try LightningEngine.jitInvoiceLifetime(validUntil: 10_090, now: 10_000))
        XCTAssertThrowsError(try LightningEngine.jitRecovery(destination: Data([1, 2]), feeSat: 500, minimumCapacitySat: 26_486))
        XCTAssertThrowsError(try LightningEngine.jitRecovery(destination: ChannelScripts.witnessKeyHash(bobKey), feeSat: 26_486,
                                                             minimumCapacitySat: 26_486))
    }

    func testPurchasesAreBoundedAndTheInvoiceNeedsTheProvider() async throws {
        let p = try await pair()
        for id in 50..<62 { try await buy(p.bob, id: UInt8(id)) }
        XCTAssertEqual(try state(p.bobStore).jit?.count, LightningEngine.maximumJITPurchases)
        do { try await buy(p.bob, id: 70, provider: try ChannelKeys.publicKey(secret: Data(repeating: 9, count: 32))); XCTFail() }
        catch {}
        do { try await buy(p.bob, id: 50); XCTFail("an invoice id is used once") } catch {}
    }
}
