import Foundation
import Observation
import WalletCore

/// The bump-fee sheet's state: the pending payment's current rate, the rate
/// asked for, the reviewed replacement and its result. A review answers only
/// the inputs it was asked about; editing the rate while one is in flight
/// discards it.
@MainActor
@Observable
final class FeeBumpReview {
    struct Reviewed {
        let request: FeeBumpReviewInputs
        let preview: FeeBumpPreview
    }

    let txid: Data
    private(set) var currentRate: Double?
    var targetRateText = ""
    private(set) var reviewed: Reviewed?
    private(set) var error: String?
    private(set) var bumping = false
    private(set) var replacementTxid: Data?

    init(txid: Data) {
        self.txid = txid
    }

    var inputs: FeeBumpReviewInputs {
        FeeBumpReviewInputs(txid: txid, targetRateText: targetRateText)
    }

    /// The current rate, a suggested one sat/vB above it, and its review.
    func load(using model: AppModel) async {
        do {
            let rate = try await model.pendingFeeRate(txid: txid)
            currentRate = rate
            targetRateText = String(format: "%.0f", ceil(rate + 1))
            try await reviewCurrentInputs(using: model)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func review(using model: AppModel) async {
        let requested = inputs
        error = nil
        reviewed = nil
        do {
            try await reviewCurrentInputs(using: model)
        } catch where requested == inputs {
            self.error = error.localizedDescription
        } catch {}
    }

    /// Editing the rate invalidates the review shown for the old one.
    func inputsChanged() {
        reviewed = nil
        error = nil
    }

    func bump(using model: AppModel) async {
        guard let reviewed else { return }
        bumping = true
        error = nil
        defer { bumping = false }
        do {
            replacementTxid = try await model.bumpFee(preview: reviewed.preview)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reviewCurrentInputs(using model: AppModel) async throws {
        let requested = inputs
        guard let rate = requested.targetRate else { return }
        let candidate = try await model.previewFeeBump(txid: requested.txid, feeRateSatPerVByte: rate)
        guard requested == inputs else { return }
        reviewed = Reviewed(request: requested, preview: candidate)
    }
}
