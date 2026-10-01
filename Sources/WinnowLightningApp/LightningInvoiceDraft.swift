import Foundation
import LightningCore
import Observation

/// The invoice form's inputs and its one route discovery. A review reaches
/// the sheet only while the inputs and network it was prepared for are
/// unchanged; editing them discards whatever is in flight.
@MainActor
@Observable
final class LightningInvoiceDraft {
    struct Inputs: Equatable {
        let invoice: String, amount: String, fee: String
    }

    var invoice = ""
    var amount = ""
    var fee = "50"
    var review: LightningReview?
    private(set) var busy = false
    private(set) var error: String?
    @ObservationIgnored private var discovery: Task<Void, Never>?

    var inputs: Inputs { Inputs(invoice: invoice, amount: amount, fee: fee) }

    func prepareReview(controller: LightningAppController, model: AppModel) {
        guard !busy else { return }
        busy = true; error = nil
        let requested = inputs, network = model.network
        discovery = Task {
            defer { busy = false }
            do {
                let prepared = try await controller.reviewInvoice(requested.invoice, amountText: requested.amount,
                                                                  maximumFeeText: requested.fee, model: model)
                try Task.checkCancellation()
                guard inputs == requested, model.network == network else { throw LightningInvoiceError.changed }
                review = .invoice(prepared)
            } catch let failure where !Task.isCancelled && !(failure is CancellationError) {
                // A discarded discovery's failure belongs to inputs no longer shown.
                error = failure.localizedDescription
            } catch {}
        }
    }

    /// Edits and a network change discard the discovery and its result.
    func invalidate() {
        cancel(); review = nil; error = nil
    }

    /// Leaving the form ends the discovery.
    func cancel() { discovery?.cancel() }

    func report(_ error: any Error) { self.error = error.localizedDescription }

    /// Waits for the current discovery, for callers that sequence on it.
    func finish() async { await discovery?.value }
}
