import Foundation

/// One HTTP POST of an OHTTP request to a relay: the production transport
/// is `RoutedHTTPClient`; tests plug in a fake directory.
public protocol PayjoinTransport: Sendable {
    func post(_ url: URL, body: Data) async throws -> Data
}

extension RoutedHTTPClient: PayjoinTransport {
    public func post(_ url: URL, body: Data) async throws -> Data {
        try await post(url, body: body, contentType: PayjoinSession.requestMediaType,
                       accept: PayjoinSession.responseMediaType, maximumBytes: PayjoinSession.encapsulatedBytes)
    }
}

public enum PayjoinSessionError: Error, Equatable {
    case sessionExpired
    case directoryStatus(Int)
    case relayResponseSize(Int)
    /// A BIP 78 well-known error from the receiver; the text shown is ours.
    case receiverError(code: String)
    case proposalNotAPSBT
}

/// A BIP 77 sender session: the ephemeral reply key, the receiver's
/// parameters and the relay. Builds and reads the OHTTP exchanges with the
/// directory — POST the Original PSBT to the receiver's mailbox, GET the
/// sender's mailbox until a Proposal PSBT arrives or the session is given
/// up — and hands the proposal to `PayjoinContext.check`.
///
/// Exercised by `PayjoinSenderTests` through an in-memory directory and by
/// `PayjoinSendFlowTests` through the app.
public struct PayjoinSession: Sendable {
    public static let requestMediaType = "message/ohttp-req"
    public static let responseMediaType = "message/ohttp-res"
    public static let encapsulatedBytes = 8_192
    /// BIP 77: the BHTTP request is padded to this before encapsulation.
    static let paddedRequestBytes = 8_104

    public typealias Curve = HPKE.Secp256k1
    public typealias Cipher = HPKE.ChaChaPolyAEAD

    public let parameters: PayjoinParameters
    public let relay: URL
    let replyKey: Curve.PrivateKey

    public init(parameters: PayjoinParameters, relay: URL) throws {
        self.parameters = parameters
        self.relay = relay
        replyKey = try Curve.generatePrivateKey()
    }

    /// The sender's own mailbox: the short id of its reply key.
    public var replyMailboxID: String {
        PayjoinShortID.derive(compressedKey: Curve.compressed(replyKey.publicKey))
    }

    /// `{relay}/{directory}/`: how an OHTTP relay is told which gateway to
    /// forward to (the reference directory's convention).
    public var relayURL: URL {
        get throws {
            var base = relay.absoluteString
            while base.hasSuffix("/") { base.removeLast() }
            guard let url = URL(string: base + "/" + parameters.directory.absoluteString) else {
                throw PaymentURIError.invalidPayjoinEndpoint("relay")
            }
            return url
        }
    }

    func receiverKey() throws -> Curve.PublicKey {
        try Curve.publicKey(compressed: parameters.receiverKey)
    }

    // MARK: - Exchanges

    /// Encapsulates an inner request to a mailbox; the returned context
    /// decrypts the directory's answer.
    func encapsulate(method: String, mailbox: URL, body: Data) throws -> (Data, OHTTP.ClientContext<Curve, Cipher>) {
        var authority = mailbox.host ?? ""
        if let port = mailbox.port { authority += ":\(port)" }
        let request = OHTTP.Request(method: method, scheme: mailbox.scheme ?? "https", authority: authority,
                                    path: mailbox.path, body: body)
        let encoded = request.encoded
        guard encoded.count <= Self.paddedRequestBytes else { throw PayjoinMessage.Failure.payloadTooLarge(
            actual: encoded.count, max: Self.paddedRequestBytes) }
        let padded = encoded + ElligatorSwift.random(count: Self.paddedRequestBytes - encoded.count)
        return try OHTTP.encapsulateRequest(padded, config: parameters.ohttpKeyConfig, Curve.self, Cipher.self)
    }

    func exchange(method: String, mailbox: URL, body: Data, transport: any PayjoinTransport) async throws -> OHTTP.Response {
        let (encapsulated, context) = try encapsulate(method: method, mailbox: mailbox, body: body)
        let answer = try await transport.post(try relayURL, body: encapsulated)
        guard answer.count == Self.encapsulatedBytes else { throw PayjoinSessionError.relayResponseSize(answer.count) }
        return try OHTTP.Response(decoding: try context.decapsulate(answer))
    }

    /// Posts the Original PSBT (Message A) to the receiver's mailbox.
    public func postOriginal(_ context: PayjoinContext, transport: any PayjoinTransport, now: Date = Date()) async throws {
        guard now < parameters.expiry else { throw PayjoinSessionError.sessionExpired }
        let message = try PayjoinMessage.encryptA(body: try context.messageBody(), replyKey: replyKey.publicKey,
                                                  receiverKey: try receiverKey())
        let response = try await exchange(method: "POST", mailbox: parameters.mailboxURL, body: message,
                                          transport: transport)
        guard response.status == 200 else { throw PayjoinSessionError.directoryStatus(response.status) }
    }

    /// One poll of the sender's mailbox: the receiver's reply body (the
    /// Proposal PSBT, or its JSON error) or nil when nothing is there yet.
    /// The reference client sends an empty Message A as the GET body; so
    /// does this one, so the two look alike to the directory.
    public func pollReply(transport: any PayjoinTransport, now: Date = Date()) async throws -> Data? {
        guard now < parameters.expiry else { throw PayjoinSessionError.sessionExpired }
        let body = try PayjoinMessage.encryptA(body: Data(), replyKey: replyKey.publicKey, receiverKey: try receiverKey())
        let response = try await exchange(method: "GET", mailbox: parameters.mailboxURL(shortID: replyMailboxID),
                                          body: body, transport: transport)
        switch response.status {
        case 200:
            let plaintext = try PayjoinMessage.decryptB(response.body, receiverKey: try receiverKey(), replyKey: replyKey)
            return PayjoinMessage.unpadded(plaintext)
        case 202:
            return nil
        default:
            throw PayjoinSessionError.directoryStatus(response.status)
        }
    }

    /// Reads a reply body: a BIP 78 JSON error, or a base64 Proposal PSBT.
    public static func proposal(fromReply body: Data) throws -> PSBT {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") {
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            let code = object?["errorCode"] as? String ?? "unknown"
            throw PayjoinSessionError.receiverError(code: Self.wellKnownErrors.contains(code) ? code : "unknown")
        }
        guard let psbt = try? PSBT(base64: text) else { throw PayjoinSessionError.proposalNotAPSBT }
        return psbt
    }

    /// BIP 78's well-known receiver errors; any other code is reported as
    /// "unknown" so a receiver cannot put its own words on the screen.
    public static let wellKnownErrors: Set<String> = ["unavailable", "not-enough-money", "version-unsupported",
                                                      "original-psbt-rejected"]

    /// Polls until a reply arrives, `deadline` passes, or the task is
    /// cancelled; `pause` separates polls that the directory answered at
    /// once (its own long poll normally supplies the wait).
    public func awaitProposal(context: PayjoinContext, transport: any PayjoinTransport, deadline: Date,
                              pause: Duration = .seconds(2),
                              clock: any Clock<Duration> = ContinuousClock()) async throws -> CheckedProposal? {
        while Date() < deadline {
            try Task.checkCancellation()
            if let reply = try await pollReply(transport: transport) {
                return try context.check(proposal: Self.proposal(fromReply: reply))
            }
            try await clock.sleep(for: pause)
        }
        return nil
    }
}
