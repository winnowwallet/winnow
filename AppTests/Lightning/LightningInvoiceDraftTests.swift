@testable import WinnowLightning
import Foundation
import LightningCore
import WalletCore
import XCTest

/// The invoice form's review: text the app cannot pay is reported without a
/// review, and an edit discards a discovery in flight without a stale error.
@MainActor
final class LightningInvoiceDraftTests: XCTestCase {
    private func controller() async throws -> LightningAppController {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lightning-invoice-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let controller = LightningAppController(network: .regtest, keys: InMemoryStoreKeyVault())
        try await controller.prepare(directory: dir, headers: HeaderChain(params: .regtest))
        return controller
    }
    private func invoice(age: UInt64 = 0) throws -> String {
        try Bolt11Invoice.encode(network: .regtest, amountMsat: 5000, hash: Data(repeating: 8, count: 32),
            secret: Data(repeating: 9, count: 32), nodeSecret: Data(repeating: 21, count: 32), route: nil,
            timestamp: UInt64(Date().timeIntervalSince1970) - age)
    }
    private func review(_ draft: LightningInvoiceDraft, controller: LightningAppController, model: AppModel) async -> String? {
        draft.prepareReview(controller: controller, model: model)
        XCTAssertTrue(draft.busy)
        draft.prepareReview(controller: controller, model: model)
        await draft.finish()
        XCTAssertFalse(draft.busy)
        XCTAssertNil(draft.review)
        return draft.error
    }

    func testInputTheAppCannotPayIsReportedWithoutAReview() async throws {
        let controller = try await controller(), model = makeModel(network: .regtest), draft = LightningInvoiceDraft()
        let cases: [(String, String, String)] = try [
            ("lnbcrt1notaninvoice", "50", "malformed"),
            (invoice(), "fifty", LightningError.invalidAmount.localizedDescription),
            (invoice(age: 7200), "50", LightningInvoiceError.expired.localizedDescription),
            (invoice(), "100001", LightningInvoiceError.unavailable.localizedDescription),
            (invoice(), "50", LightningInvoiceError.unavailable.localizedDescription),
        ]
        for (text, fee, expected) in cases {
            draft.invoice = text; draft.fee = fee; draft.invalidate()
            let error = await review(draft, controller: controller, model: model)
            if expected == "malformed" { XCTAssertNotNil(error) } else { XCTAssertEqual(error, expected, "\(fee) for \(text)") }
        }
    }

    func testAnEditDiscardsTheDiscoveryAndItsFailure() async throws {
        let controller = try await controller(), model = makeModel(network: .regtest), draft = LightningInvoiceDraft()
        draft.invoice = try invoice()
        draft.prepareReview(controller: controller, model: model)
        draft.fee = "60"; draft.invalidate()
        await draft.finish()
        XCTAssertFalse(draft.busy)
        XCTAssertNil(draft.review)
        XCTAssertNil(draft.error, "the failure answered inputs no longer shown")
    }
}
