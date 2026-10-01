import Foundation
import WalletCore
import XCTest
@testable import LightningCore

private final class OrdinaryJournal: LightningJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    func load() -> Data? { lock.withLock { bytes } }
    func store(_ bytes: Data) { lock.withLock { self.bytes = bytes } }
}

final class OrdinaryOfferTests: XCTestCase, @unchecked Sendable {
    private let chain = NetworkParams.regtest.genesisHash
    private func secret(_ n: UInt8) -> Data { Data(repeating: n, count: 32) }
    private func key(_ n: UInt8) throws -> Data { try ChannelKeys.publicKey(secret: secret(n)) }
    private func offer(blinded: Bool = false) throws -> LightningOffer {
        var fields: [LightningWire.TLV] = [.init(type: 2, value: chain), .init(type: 10, value: Data("Test offer".utf8)), .init(type: 22, value: try key(4))]
        if blinded { fields.append(try .init(type: 16, value: OnionMessage.path(nodes: [key(2), key(4)], context: secret(7), authenticationKey: secret(8)).encoded())) }
        return try LightningOffer(bytes: Bolt12Encoding.serialize(fields.sorted { $0.type < $1.type }))
    }
    private func invoice(_ request: InvoiceRequest, hash: Data = Data(repeating: 7, count: 32), now: UInt64 = 100) throws -> Bolt12Invoice {
        let path = try OrdinaryBlindedPayment.path(provider: key(2), recipient: key(4),
            route: .init(peer: key(2), shortChannelID: 456, baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 40),
            token: secret(8), maximumExpiry: 3000, minimumMsat: 1000)
        return try Bolt12Invoice(request: request, paths: [path],
            payInfo: [.init(baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 58, minimumMsat: 1000, maximumMsat: 98_000_000, features: .init(bytes: Data()))],
            paymentHash: hash, createdAt: now, relativeExpiry: 3600, signingSecret: secret(4))
    }
    private func snapshot(funder: Bool) throws -> LightningEngine.State {
        let local = try ChannelSecrets(), remote = try ChannelSecrets()
        var channel = try ChannelState(peer: key(2), temporaryID: secret(3), capacity: 100_000,
            pushMsat: 0, feePerKW: 1000, isFunder: funder, secrets: local,
            local: local.terms(capacity: 100_000), remote: remote.terms(capacity: 100_000), phase: .ready)
        let funding = try Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: secret(5), vout: 0), scriptSig: Data(), sequence: .max)],
            outputs: [.init(value: 100_000, scriptPubKey: channel.fundingScript())], locktime: 0)
        channel.fundingTxid = funding.txid; channel.fundingOutput = 0; channel.fundingIsConfirmed = true
        channel.localReady = true; channel.remoteReady = true; channel.remoteNextPoint = try remote.point(1)
        channel.recovery = .init(destination: Data([0, 20]) + secret(6).prefix(20), feeSat: 500)
        channel.invoicePolicy = try .init(peer: key(2), shortChannelID: 100 << 40 | 2 << 16, timestamp: 100,
            baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 40, disabled: false, minimumMsat: 1000, maximumMsat: 98_000_000)
        var state = LightningEngine.State(chain: chain, nodeSecret: secret(1)); state.channels = [channel]
        state.scan.transactions = [.init(height: 100, blockHash: secret(7), raw: funding.serialized(includeWitness: true), transactionIndex: 2)]
        return state
    }
    private func engine(_ snapshot: LightningEngine.State) async throws -> (LightningEngine, OrdinaryJournal) {
        let journal = OrdinaryJournal(); try journal.store(JSONEncoder().encode(snapshot))
        let engine = try LightningEngine(chain: chain, journal: journal)
        try await engine.chainCaughtUp(height: 103); try await engine.peerInitialized(key(2), features: .asyncClient)
        return (engine, journal)
    }
    func testInvoiceCopiesExactPayerFieldsAndBindsAmountNetworkIssuerExpiry() throws {
        let request = try InvoiceRequest(offer: offer(), chain: chain, amountMsat: 21_000, now: 100,
            metadata: secret(9), payerSecret: secret(10), humanReadableName: BIP353Name("test@example.com"))
        let value = try invoice(request)
        try value.validate(for: request, expectedIssuer: key(4), chain: chain, now: 101)
        XCTAssertEqual(try Bolt12Invoice(string: value.string).bytes, value.bytes)
        XCTAssertThrowsError(try value.validate(for: request, expectedIssuer: key(3), chain: chain, now: 101))
        XCTAssertThrowsError(try value.validate(for: request, expectedIssuer: key(4), chain: secret(8), now: 101))
        XCTAssertThrowsError(try value.validate(for: request, expectedIssuer: key(4), chain: chain, now: 3701))
        let other = try InvoiceRequest(offer: offer(), chain: chain, amountMsat: 22_000, now: 100, metadata: secret(9), payerSecret: secret(10))
        XCTAssertThrowsError(try value.validate(for: other, expectedIssuer: key(4), chain: chain, now: 101))
        let changed = try Bolt12Encoding.records(value.bytes).map { $0.type == 168 ? LightningWire.TLV(type: 168, value: secret(2)) : $0 }
        XCTAssertThrowsError(try Bolt12Invoice(bytes: Bolt12Encoding.serialize(changed)))
        XCTAssertThrowsError(try StaticInvoice(bytes: value.bytes), "Ordinary invoices never enter the async static-invoice flow")
    }
    func testDirectOnionAcceptsOnlySignedInvoiceRequestsAndKeepsPrivateRepliesAuthenticated() throws {
        let request = try InvoiceRequest(offer: offer(), chain: chain, amountMsat: 21_000, now: 100, metadata: secret(9), payerSecret: secret(10))
        let path = try OnionMessage.directPath(node: key(4))
        let message = try OnionMessage.create(to: path, content: .init(type: 64, value: request.bytes))
        guard case .invoiceRequest(let content, nil) = try OnionMessage.peel(message, nodeSecret: secret(4), authenticationKey: secret(8)) else { return XCTFail() }
        XCTAssertEqual(content.value, request.bytes)
        for type: UInt64 in [66, 70, 74] {
            let forged = try OnionMessage.create(to: path, content: .init(type: type, value: request.bytes))
            XCTAssertThrowsError(try OnionMessage.peel(forged, nodeSecret: secret(4), authenticationKey: secret(8)))
        }
    }
    func testInvoiceUsesSupportedPathsAndRejectsAnInvoiceWithNoUsablePath() throws {
        let request = try InvoiceRequest(offer: offer(), chain: chain, amountMsat: 21_000, now: 100, metadata: secret(9), payerSecret: secret(10))
        let value = try invoice(request), validInfo = try value.payInfo[0].encoded()
        var unsupportedInfo = Data(validInfo.dropLast(2)); unsupportedInfo.append(Data([0, 1, 4]))
        var fields = try Bolt12Encoding.records(value.bytes).filter { $0.type != 240 }
        fields = try fields.map { field in
            switch field.type {
            case 160: return .init(type: 160, value: try value.paymentPaths[0].encoded() + value.paymentPaths[0].encoded())
            case 162: return .init(type: 162, value: unsupportedInfo + validInfo)
            default: return field
            }
        }
        let mixed = try Bolt12Invoice(bytes: Bolt12Encoding.sign(fields, message: "invoice", secret: secret(4)))
        XCTAssertEqual(mixed.paymentPaths.count, 1); XCTAssertEqual(mixed.payInfo[0], value.payInfo[0])
        fields = fields.map { $0.type == 162 ? .init(type: 162, value: unsupportedInfo + unsupportedInfo) : $0 }
        XCTAssertThrowsError(try Bolt12Invoice(bytes: Bolt12Encoding.sign(fields, message: "invoice", secret: secret(4))))
        let shortDelta = try StaticInvoice.PayInfo(baseMsat: 1000, proportionalMillionths: 0, expiryDelta: 10, minimumMsat: 1000, maximumMsat: 98_000_000, features: .init(bytes: Data()))
        let padded = try Bolt12Invoice(request: request, paths: value.paymentPaths, payInfo: [shortDelta], paymentHash: value.paymentHash,
            createdAt: 100, signingSecret: secret(4))
        let route = try Bolt12PaymentRoute(hops: [], pathIndex: 0, introduction: key(2))
        XCTAssertEqual(try route.quote(invoice: padded, feeLimitMsat: 1000, height: 100, maximumDelta: 18).firstExpiry, 118)
    }
    func testFetchingInvoiceNeverCreatesHTLCAndAuthorizedPaymentPersistsOnceAcrossRestart() async throws {
        let (engine, journal) = try await engine(snapshot(funder: true)), id = secret(9)
        let pending = try LightningEngine.OrdinaryOfferRequest(id: id, offer: offer(blinded: true), amountMsat: 21_000, via: [key(2)])
        try await engine.requestOrdinaryInvoice(pending, now: 100)
        try await engine.requestOrdinaryInvoice(pending, now: 101)
        var saved = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(journal.load()))
        XCTAssertTrue(saved.payments.isEmpty); XCTAssertTrue(saved.channels[0].updates.isEmpty); XCTAssertEqual(saved.offers?.outgoing.count, 1)
        let request = try InvoiceRequest(bytes: XCTUnwrap(saved.offers?.outgoing.first?.invoiceRequest)), value = try invoice(request)
        try await engine.acceptOrdinaryInvoice(.init(type: 66, value: value.bytes), id: id, now: 101)
        let route = try Bolt12PaymentRoute(hops: [], pathIndex: 0, introduction: key(2))
        let payment = LightningEngine.OrdinaryInvoicePayment(id: id, channelID: saved.channels[0].id, invoice: value, feeLimitMsat: 1000, route: route)
        let quote = try await engine.ordinaryInvoiceQuote(payment, now: 101)
        XCTAssertEqual(quote.feeMsat, 1000)
        saved = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(journal.load()))
        XCTAssertTrue(saved.payments.isEmpty); XCTAssertTrue(saved.channels[0].updates.isEmpty)
        let first = try await engine.payOrdinaryInvoice(payment, now: 101), duplicate = try await engine.payOrdinaryInvoice(payment, now: 102)
        XCTAssertEqual(first, duplicate)
        saved = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(journal.load()))
        XCTAssertEqual(saved.payments.count, 1); XCTAssertEqual(saved.channels[0].nextLocalHTLC, 1)
        let restored = try LightningEngine(chain: chain, journal: journal)
        try await restored.chainCaughtUp(height: 103); try await restored.peerInitialized(key(2), features: .asyncClient)
        let replay = try await restored.payOrdinaryInvoice(payment, now: 103)
        XCTAssertEqual(replay, first)
        try await restored.cancelOrdinaryInvoiceRequest(id: id)
        let retained = try await restored.ordinaryInvoiceRequests(now: 104)
        XCTAssertEqual(retained.count, 1, "Cancelling a review cannot erase an authorized payment")
    }
    func testCancelAndTimeoutDoNotPayAndRestoreRetainsPendingRequest() async throws {
        let (engine, journal) = try await engine(snapshot(funder: true)), id = secret(9)
        let pending = try LightningEngine.OrdinaryOfferRequest(id: id, offer: offer(), amountMsat: 21_000, via: [key(2)])
        try await engine.requestOrdinaryInvoice(pending, now: 100)
        let restored = try LightningEngine(chain: chain, journal: journal)
        let expired = try await restored.ordinaryInvoiceRequests(now: 401)
        XCTAssertTrue(expired.first!.expired)
        try await restored.cancelOrdinaryInvoiceRequest(id: id)
        let cancelled = try await restored.ordinaryInvoiceRequests(now: 401), payments = await restored.payments()
        XCTAssertTrue(cancelled.isEmpty); XCTAssertTrue(payments.isEmpty)
    }
    func testCancelledAuthorizationDoesNotCommitHTLCAndCanBeRetriedOnce() async throws {
        let (engine, journal) = try await engine(snapshot(funder: true)), id = secret(9)
        let pending = try LightningEngine.OrdinaryOfferRequest(id: id, offer: offer(), amountMsat: 21_000, via: [key(2)])
        try await engine.requestOrdinaryInvoice(pending, now: 100)
        let stored = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(journal.load()))
        let request = try InvoiceRequest(bytes: XCTUnwrap(stored.offers?.outgoing.first?.invoiceRequest)), value = try invoice(request)
        try await engine.acceptOrdinaryInvoice(.init(type: 66, value: value.bytes), id: id, now: 101)
        let route = try Bolt12PaymentRoute(hops: [], pathIndex: 0, introduction: key(2))
        let payment = LightningEngine.OrdinaryInvoicePayment(id: id, channelID: stored.channels[0].id, invoice: value, feeLimitMsat: 1000, route: route)
        let before = try XCTUnwrap(journal.load())
        let cancelled = Task {
            // Cancel this caller before entering the engine; no sleep or
            // scheduling race may short-circuit the actual authorization call.
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.payOrdinaryInvoice(payment, now: 101)
        }
        do { _ = try await cancelled.value; XCTFail("A canceled caller authorized a new payment") }
        catch is CancellationError {}
        XCTAssertEqual(journal.load(), before, "Cancellation must not advance the durable journal")
        let unchanged = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(journal.load()))
        XCTAssertTrue(unchanged.payments.isEmpty)
        XCTAssertTrue(unchanged.channels[0].updates.isEmpty)
        XCTAssertNil(unchanged.offers?.outgoing.first?.payment)
        let paid = try await engine.payOrdinaryInvoice(payment, now: 101)
        let duplicate = try await engine.payOrdinaryInvoice(payment, now: 102)
        XCTAssertEqual(paid, duplicate)
        let committed = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(journal.load()))
        XCTAssertEqual(committed.payments.count, 1)
        XCTAssertEqual(committed.channels[0].nextLocalHTLC, 1)
        let committedBytes = journal.load()
        let cancelledReplay = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.payOrdinaryInvoice(payment, now: 102)
        }
        let replay = try await cancelledReplay.value
        XCTAssertEqual(replay, paid, "Cancellation after durable authorization cannot erase its receipt")
        XCTAssertEqual(journal.load(), committedBytes)
    }
    func testIssuerRequiresPublishedPathAndReusesIdenticalRequestWithoutChangingPaymentHash() async throws {
        let (engine, journal) = try await engine(snapshot(funder: false)), now = UInt64(Date().timeIntervalSince1970), id = secret(9)
        let configuration = try LightningEngine.OrdinaryOfferConfiguration(id: id, peer: key(2), description: "Reusable receive", expiresAt: now + 86_400)
        let offer = try await engine.registerOrdinaryOffer(configuration, now: now)
        let request = try InvoiceRequest(offer: offer, chain: chain, amountMsat: 21_000, now: now, metadata: secret(10), payerSecret: secret(11))
        let reply = try OnionMessage.path(nodes: [key(3)], context: secret(12), authenticationKey: secret(13))
        do { try await engine.receiveOrdinaryRequest(.init(type: 64, value: request.bytes), reply: reply, offerID: nil, now: now); XCTFail() } catch {}
        try await engine.receiveOrdinaryRequest(.init(type: 64, value: request.bytes), reply: reply, offerID: id, now: now)
        let first = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(journal.load()))
        try await engine.receiveOrdinaryRequest(.init(type: 64, value: request.bytes), reply: reply, offerID: id, now: now + 1)
        let second = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(journal.load()))
        XCTAssertEqual(first.incoming.count, 1); XCTAssertEqual(second.incoming.count, 1)
        XCTAssertEqual(first.offers?.issued.first?.invoice, second.offers?.issued.first?.invoice)
        let invoice = try Bolt12Invoice(bytes: XCTUnwrap(second.offers?.issued.first?.invoice))
        try invoice.validate(for: request, expectedIssuer: key(1), chain: chain, now: now + 1)
        XCTAssertEqual(invoice.amountMsat, 21_000)
    }
    func testOrdinaryBlindedPaymentBindsTokenAmountHeightAndRejectsReplay() async throws {
        let (engine, journal) = try await engine(snapshot(funder: false)), now = UInt64(Date().timeIntervalSince1970)
        let offer = try await engine.registerOrdinaryOffer(.init(id: secret(9), peer: key(2), description: "Online receiving", expiresAt: now + 86_400), now: now)
        let request = try InvoiceRequest(offer: offer, chain: chain, amountMsat: 21_000, now: now, metadata: secret(10), payerSecret: secret(11))
        let reply = try OnionMessage.path(nodes: [key(3)], context: secret(12), authenticationKey: secret(13))
        try await engine.receiveOrdinaryRequest(.init(type: 64, value: request.bytes), reply: reply, offerID: secret(9), now: now)
        var saved = try JSONDecoder().decode(LightningEngine.State.self, from: XCTUnwrap(journal.load()))
        let invoice = try Bolt12Invoice(bytes: XCTUnwrap(saved.offers?.issued.first?.invoice))
        let route = try Bolt12PaymentRoute(hops: [], pathIndex: 0, introduction: key(2))
        let quote = try route.quote(invoice: invoice, feeLimitMsat: 1000, height: 103, maximumDelta: 144)
        let path = invoice.paymentPaths[0], onion = try route.onion(invoice: invoice, quote: quote)
        let provider = try BlindedPayment.peel(onion: onion, blinding: path.blinding, nodeSecret: secret(2), hash: invoice.paymentHash)
        let shared = try NoiseCrypto.ecdh(secret: secret(2), point: path.blinding)
        let nextBlinding = try ChannelKeys.point(path.blinding).multiply(Array(ChannelKeys.hash(path.blinding + shared))).dataRepresentation
        let peeled = try BlindedPayment.peel(onion: XCTUnwrap(provider.next), blinding: nextBlinding, nodeSecret: secret(1), hash: invoice.paymentHash)
        let htlc = ChannelTransactions.HTLC(id: 0, offered: false, amountMsat: 21_000, paymentHash: invoice.paymentHash, expiry: 121)
        let received = await engine.validOrdinaryReceive(htlc, peeled: peeled, blinding: nextBlinding, state: saved)
        XCTAssertEqual(received?.preimage, saved.incoming[0].preimage)
        let finalValues = try Bolt12Encoding.records(peeled.payload)
        XCTAssertEqual(try Bolt12Encoding.integer(XCTUnwrap(finalValues.first { $0.type == 4 }?.value)), 103,
                       "BOLT4's blinded final payload uses the current-height baseline; actual incoming HTLC adds the final delta")
        do { try OrdinaryBlindedPayment.receive(peeled: provider, blinding: path.blinding, nodeSecret: secret(2), request: saved.incoming[0], htlc: htlc, height: 103); XCTFail() } catch {}
        let original = saved.incoming[0]
        saved.incoming[0] = .init(id: original.id, preimage: original.preimage, secret: secret(15), amountMsat: original.amountMsat, expiry: original.expiry, expiresAt: original.expiresAt)
        let wrongToken = await engine.validOrdinaryReceive(htlc, peeled: peeled, blinding: nextBlinding, state: saved)
        XCTAssertNil(wrongToken)
        saved.incoming[0] = original
        let tooSmall = ChannelTransactions.HTLC(id: 0, offered: false, amountMsat: 20_000, paymentHash: invoice.paymentHash, expiry: 121)
        let underpaid = await engine.validOrdinaryReceive(tooSmall, peeled: peeled, blinding: nextBlinding, state: saved)
        XCTAssertNil(underpaid)
        try await engine.chainCaughtUp(height: 104)
        let stale = await engine.validOrdinaryReceive(htlc, peeled: peeled, blinding: nextBlinding, state: saved)
        XCTAssertNil(stale)
        try await engine.chainCaughtUp(height: 103)
        saved.payments.append(.init(payment: .init(id: invoice.paymentHash, hash: invoice.paymentHash, amountMsat: 21_000, incoming: true, phase: .inFlight), channelID: saved.channels[0].id, htlcID: 0, request: nil))
        let replay = await engine.validOrdinaryReceive(htlc, peeled: peeled, blinding: nextBlinding, state: saved)
        XCTAssertNil(replay)
    }
}
