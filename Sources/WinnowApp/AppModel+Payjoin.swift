import Foundation
import WalletCore

/// Paying a `bitcoin:` request that offers BIP 77 payjoin. The review shows
/// the ordinary payment plus what a payjoin may add — the receiver's own
/// coins, and up to the agreed fee contribution from our change — and the
/// user authorizes that envelope. After the original is built and passes
/// the ordinary gate, it goes to the receiver's mailbox through the relay;
/// a proposal that comes back is held to the BIP 78 checklist and then to
/// `SendPreview.authorizes(payjoinProposal:)` before our inputs are signed.
/// No proposal within the wait, a refused one, or a transport failure all
/// end the same way BIP 78 allows: the reviewed original is broadcast.
///
/// Exercised by `PayjoinSendFlowTests` (AppTests) and the signet journey's
/// payjoin leg.
extension AppModel {
    /// What a payjoin offer adds to a reviewed send.
    struct PayjoinRequest: Equatable {
        var parameters: PayjoinParameters
        var relay: URL
        /// The most the receiver may take from the change output for fees.
        var maxFeeContribution: Int64
        var required: Bool
    }

    enum PayjoinPhase: Equatable {
        case posting
        case waiting
    }

    /// How a payjoin send ended, for the receipt.
    enum PayjoinOutcome: Equatable {
        case joined(receiverInputs: Int, contribution: Int64)
        case plain(reason: String)

        var text: String {
            switch self {
            case let .joined(inputs, contribution):
                "Payjoin: the receiver added \(inputs) input\(inputs == 1 ? "" : "s") and \(contribution) sats of your change went to fees."
            case let .plain(reason):
                "Sent without payjoin: \(reason)."
            }
        }
    }

    /// The reference clients' public relays; one is the default so a `pj=`
    /// request works out of the box. Advanced settings override it per
    /// network; regtest has no public relay.
    static func payjoinRelayURL(custom: String, network: BitcoinNetwork) -> URL? {
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard let url = URL(string: trimmed), let host = url.host, RoutedHTTPClient.permits(url),
                  url.scheme?.lowercased() == "https" || (url.scheme?.lowercased() == "http" && isLoopback(host))
            else { return nil }
            return url
        }
        switch network {
        case .mainnet, .signet: return URL(string: "https://payjoin.achow101.com")
        case .regtest: return nil
        }
    }

    var payjoinRelayURL: URL? {
        Self.payjoinRelayURL(custom: e2e?.control()?.payjoinRelay ?? payjoinRelayString, network: network)
    }

    /// Why payjoin cannot be attempted right now, or nil.
    var payjoinUnavailableReason: String? {
        if !activePeerGateways.permitsPayjoin {
            return "I2P-only routing makes no HTTP request"
        }
        if payjoinRelayURL == nil {
            return payjoinRelayString.isEmpty ? "no payjoin relay is set for this network"
                : "the payjoin relay in Settings is not an https URL"
        }
        return nil
    }

    /// Decides at review time whether the offer is taken up, and with which
    /// envelope, so the review shows exactly what `send` will do.
    func attachPayjoin(from uri: PaymentURI, to preview: inout SendPreview) throws {
        guard let parameters = uri.payjoin else { return }
        var reason = payjoinUnavailableReason
        if reason == nil, parameters.expiry <= Date() { reason = "the request has expired" }
        if reason == nil, !preview.silentPayments.isEmpty { throw AppError.payjoinCannotPaySilentPayment }
        if let reason {
            guard !uri.payjoinRequired else { throw AppError.payjoinUnavailable(reason) }
            preview.payjoinUnavailable = reason
            return
        }
        guard let relay = payjoinRelayURL else { return }
        preview.payjoin = PayjoinRequest(
            parameters: parameters, relay: relay,
            maxFeeContribution: Wallet.payjoinFeeContribution(feeRateSatPerVByte: preview.feeRateSatPerVByte,
                                                               change: preview.change),
            required: uri.payjoinRequired)
    }

    /// Posts the authorized original, waits for the receiver within the
    /// budget, signs a proposal that passes both gates, and otherwise
    /// broadcasts the original. Returns the txid of whatever was sent.
    func sendThroughPayjoin(preview: SendPreview, prepared: Wallet.PreparedSend, wallet: Wallet) async throws -> Data {
        guard let request = preview.payjoin, let payee = preview.payments.first else {
            throw AppError.sendReviewChanged
        }
        lastPayjoinOutcome = nil
        defer { payjoinPhase = nil }
        var outcome: Result<CheckedProposal?, Error>
        do {
            let context = try await wallet.payjoinContext(for: prepared, payee: payee,
                                                          feeRateSatPerVByte: preview.feeRateSatPerVByte)
            // The envelope the review showed is the one the receiver is offered.
            guard context.maxFeeContribution == request.maxFeeContribution else { throw AppError.sendReviewChanged }
            outcome = .success(try await exchangeWithReceiver(request: request, context: context))
        } catch {
            outcome = .failure(error)
        }
        if case let .success(checked?) = outcome, preview.authorizes(payjoinProposal: checked) {
            do {
                // Signing runs the last BIP 78 check, the fee-rate floor on
                // the signed transaction; a refusal there falls back like
                // any other, and only a failed broadcast is an error.
                let signed = try await wallet.signPayjoinProposal(checked, prepared: prepared)
                let txid = try await broadcast(signed, feeRateSatPerVByte: preview.feeRateSatPerVByte)
                try await wallet.commitPayjoin(prepared, payee: payee, transaction: signed, checked: checked)
                lastPayjoinOutcome = .joined(receiverInputs: checked.receiverInputCount, contribution: checked.contributedFee)
                e2e?.journal("payjoin.joined", fields: ["txid": txid.displayHex,
                                                        "receiverInputs": String(checked.receiverInputCount),
                                                        "contribution": String(checked.contributedFee)])
                return txid
            } catch let error as PayjoinProposalError {
                outcome = .failure(error)
            }
        }
        let reason = Self.fallbackReason(outcome)
        lastPayjoinOutcome = .plain(reason: reason)
        e2e?.journal("payjoin.fallback", fields: ["reason": reason])
        let txid = try await broadcast(prepared.built.transaction, feeRateSatPerVByte: preview.feeRateSatPerVByte)
        try await wallet.commit(prepared)
        return txid
    }

    private static func fallbackReason(_ outcome: Result<CheckedProposal?, Error>) -> String {
        switch outcome {
        case .success(nil): "the receiver did not answer in time"
        case .success: "the receiver's proposal failed review"
        case .failure(is CancellationError): "you chose not to wait"
        case let .failure(error as PayjoinSessionError):
            switch error {
            case let .receiverError(code): "the receiver declined (\(code))"
            case .sessionExpired: "the request expired"
            default: "the payjoin directory could not be reached"
            }
        case .failure(is PayjoinProposalError): "the receiver's proposal failed review"
        case .failure: "the payjoin relay could not be reached"
        }
    }

    /// The directory round trip: POST the original, poll for the proposal
    /// until the wait budget ends or the user skips the wait.
    private func exchangeWithReceiver(request: PayjoinRequest, context: PayjoinContext) async throws -> CheckedProposal? {
        let client = RoutedHTTPClient(proxy: activePeerGateways.payjoinProxy, enabled: activePeerGateways.permitsPayjoin)
        defer { client.cancel() }
        let session = try PayjoinSession(parameters: request.parameters, relay: request.relay)
        payjoinPhase = .posting
        try await session.postOriginal(context, transport: client)
        payjoinPhase = .waiting
        let deadline = Date().addingTimeInterval(payjoinWaitBudget)
        let wait = Task { try await session.awaitProposal(context: context, transport: client, deadline: deadline) }
        payjoinWait = wait
        defer { payjoinWait = nil }
        do {
            return try await wait.value
        } catch {
            // A skip cancels the task mid-request; the HTTP layer reports
            // that as its own cancellation error, not Swift's.
            if wait.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// "Send without payjoin": ends the wait; the original goes out.
    func skipPayjoinWait() {
        payjoinWait?.cancel()
    }
}

extension AppModel.SendPreview {
    /// Whether a checked proposal is still the payment the user reviewed,
    /// widened only as the review said it could be: our inputs exactly and
    /// in order, every payment output with its script and at least its
    /// amount, the change output reduced by at most the agreed contribution,
    /// the fee never lower, and what leaves the wallet never more than
    /// amount + fee + contribution. Silent payments never ride in a payjoin.
    func authorizes(payjoinProposal checked: CheckedProposal) -> Bool {
        guard let request = payjoin, silentPayments.isEmpty,
              let transaction = try? checked.psbt.unsignedTransaction() else { return false }
        let ours = checked.senderInputIndices.compactMap { index -> ReviewedOutpoint? in
            guard transaction.inputs.indices.contains(index) else { return nil }
            let outpoint = transaction.inputs[index].previousOutput
            return ReviewedOutpoint(txid: outpoint.txid, vout: outpoint.vout)
        }
        guard ours == selectedOutpoints, ours.count == checked.senderInputIndices.count else { return false }
        guard reviewedOutputsPresent(in: transaction.outputs, contribution: request.maxFeeContribution) else { return false }
        return checked.contributedFee <= request.maxFeeContribution && checked.proposedFee >= fee
            && checked.senderSpend <= amountSent + fee + request.maxFeeContribution
    }

    /// Every reviewed payment output with its script and at least its
    /// amount, and the change output (when reviewed) with its script and at
    /// least the reviewed amount less `contribution`; each claims one output.
    private func reviewedOutputsPresent(in outputs: [Transaction.Output], contribution: Int64) -> Bool {
        var unmatched = outputs
        for payment in payments {
            guard let index = unmatched.firstIndex(where: {
                $0.scriptPubKey == payment.scriptPubKey && $0.value >= payment.amount
            }) else { return false }
            unmatched.remove(at: index)
        }
        guard let change, let amount = changeAmount else { return true }
        guard let index = unmatched.firstIndex(where: { $0.scriptPubKey == change.scriptPubKey }) else { return false }
        return unmatched[index].value >= amount - contribution
    }
}
