import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// The sender session end to end over loopback HTTP: the wallet's routed
/// client posts OHTTP to the fake directory, the fake receiver answers in
/// process, and the session hands back a checked proposal, nothing, or the
/// receiver's error.
@Suite("Payjoin sender session (BIP 77)", .serialized)
struct PayjoinSenderTests {
    private struct Rig {
        var directory: FakePayjoinDirectory
        var receiver: FakePayjoinReceiver
        var session: PayjoinSession
        var context: PayjoinContext
        var client: RoutedHTTPClient

        func stop() async {
            client.cancel()
            await directory.stop()
        }
    }

    private static func rig() async throws -> Rig {
        let directory = try FakePayjoinDirectory(pollTimeout: .milliseconds(200))
        try await directory.start()
        let receiver = try FakePayjoinReceiver(network: .signet, directory: directory)
        receiver.fund(outpoint: Transaction.Outpoint(txid: Data(repeating: 0x42, count: 32), vout: 0), amount: 50_000)
        let (wallet, _) = try await fundedWallet(coins: [(.receive, 0, 300_000, 100)])
        let payee = Payment(amount: 100_000, scriptPubKey: receiver.paymentScript)
        let prepared = try await wallet.buildSend(payments: [payee], feeRateSatPerVByte: 3, chainTip: testChainTip,
                                                  randomness: { 0.5 })
        let context = try await wallet.payjoinContext(for: prepared, payee: payee, feeRateSatPerVByte: 3)
        let session = try PayjoinSession(parameters: await receiver.parameters(), relay: await directory.url)
        return Rig(directory: directory, receiver: receiver, session: session, context: context, client: RoutedHTTPClient())
    }

    @Test("an honest receiver's proposal comes back checked")
    func honest() async throws {
        let rig = try await Self.rig()
        defer { Task { await rig.stop() } }
        let serving = Task { try await rig.receiver.serve(.honest) }
        try await rig.session.postOriginal(rig.context, transport: rig.client)
        let checked = try await rig.session.awaitProposal(context: rig.context, transport: rig.client,
                                                          deadline: Date().addingTimeInterval(20), pause: .milliseconds(50))
        try await serving.value
        let proposal = try #require(checked)
        #expect(proposal.receiverInputCount == 1)
        #expect(proposal.contributedFee > 0)
        // What the directory saw: a POST to the receiver mailbox and GETs to ours, 7,168-byte bodies.
        let inner = await rig.directory.innerRequests
        #expect(inner.first?.method == "POST")
        #expect(inner.first?.path == "/\(rig.receiver.mailboxID)")
        #expect(inner.first?.body.count == 7_168)
        #expect(inner.dropFirst().allSatisfy { $0.method == "GET" && $0.path == "/\(rig.session.replyMailboxID)" && $0.body.count == 7_168 })
        let heads = await rig.directory.outerRequestHeads
        #expect(heads.allSatisfy { $0.hasPrefix("POST /http://127.0.0.1:") && $0.contains("Content-Type: message/ohttp-req") })
        #expect(rig.receiver.receivedParameters["disableoutputsubstitution"] == "true")
        #expect(rig.receiver.receivedParameters["v"] == "2")
        // The reference wire form: the relay URL is `{relay}/{directory}/`.
        #expect(try rig.session.relayURL.absoluteString == "\(await rig.directory.url.absoluteString.dropLast())/http://127.0.0.1:\(await rig.directory.port)/")
    }

    @Test("a silent receiver leaves the session empty at the deadline; a cancelled wait stops")
    func silent() async throws {
        let rig = try await Self.rig()
        defer { Task { await rig.stop() } }
        try await rig.session.postOriginal(rig.context, transport: rig.client)
        let started = Date()
        let checked = try await rig.session.awaitProposal(context: rig.context, transport: rig.client,
                                                          deadline: Date().addingTimeInterval(1.5), pause: .milliseconds(50))
        #expect(checked == nil)
        #expect(Date().timeIntervalSince(started) >= 1.4)
        let waiting = Task {
            try await rig.session.awaitProposal(context: rig.context, transport: rig.client,
                                                deadline: Date().addingTimeInterval(30), pause: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(300))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
    }

    @Test("a receiver error is reported by its well-known code only; other codes read as unknown")
    func receiverError() async throws {
        let rig = try await Self.rig()
        defer { Task { await rig.stop() } }
        let serving = Task { try await rig.receiver.serve(.error("not-enough-money")) }
        try await rig.session.postOriginal(rig.context, transport: rig.client)
        await #expect(throws: PayjoinSessionError.receiverError(code: "not-enough-money")) {
            try await rig.session.awaitProposal(context: rig.context, transport: rig.client,
                                                deadline: Date().addingTimeInterval(20), pause: .milliseconds(50))
        }
        try await serving.value
        #expect(throws: PayjoinSessionError.receiverError(code: "unknown")) {
            try PayjoinSession.proposal(fromReply: Data("{\"errorCode\":\"<script>\",\"message\":\"x\"}".utf8))
        }
        #expect(throws: PayjoinSessionError.proposalNotAPSBT) { try PayjoinSession.proposal(fromReply: Data("hello".utf8)) }
    }

    @Test("a hostile proposal fails the checks inside the session")
    func hostile() async throws {
        let rig = try await Self.rig()
        defer { Task { await rig.stop() } }
        let serving = Task { try await rig.receiver.serve(.reducePayment) }
        try await rig.session.postOriginal(rig.context, transport: rig.client)
        await #expect(throws: PayjoinProposalError.paymentOutputChanged) {
            try await rig.session.awaitProposal(context: rig.context, transport: rig.client,
                                                deadline: Date().addingTimeInterval(20), pause: .milliseconds(50))
        }
        try await serving.value
    }

    @Test("an expired session posts nothing; a relay error and a short reply are refused")
    func transportFailures() async throws {
        let rig = try await Self.rig()
        defer { Task { await rig.stop() } }
        var expired = await rig.receiver.parameters()
        expired.expiry = Date().addingTimeInterval(-1)
        let stale = try PayjoinSession(parameters: expired, relay: await rig.directory.url)
        await #expect(throws: PayjoinSessionError.sessionExpired) {
            try await stale.postOriginal(rig.context, transport: rig.client)
        }
        await rig.directory.setOuterStatus(503)
        await #expect(throws: RoutedHTTPClient.HTTPFailure.self) {
            try await rig.session.postOriginal(rig.context, transport: rig.client)
        }
        await rig.directory.setOuterStatus(200)
        struct ShortReply: PayjoinTransport {
            func post(_: URL, body _: Data) async throws -> Data { Data(count: 100) }
        }
        await #expect(throws: PayjoinSessionError.relayResponseSize(100)) {
            try await rig.session.postOriginal(rig.context, transport: ShortReply())
        }
        // The client refuses a relay it may not talk to.
        let disabled = RoutedHTTPClient(proxy: nil, enabled: false)
        await #expect(throws: RoutedHTTPClient.Failure.unavailable) {
            try await rig.session.postOriginal(rig.context, transport: disabled)
        }
    }
}
