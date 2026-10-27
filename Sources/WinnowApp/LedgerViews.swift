import SwiftUI
import WalletCore

/// The account screen's Ledger buttons. Pairing is under Settings → Signers
/// ([SignerViews](SignerViews.swift)); the builder and Join register a
/// paired Ledger themselves, and "Register on Ledger" covers an account
/// they could not.

/// On an account that names a Ledger key this phone has not registered it
/// with: registers the account on the Ledger connected now, which approves
/// it on its screen and must derive the phone's first address.
struct LedgerRegisterButton: View {
    let record: MultisigAccountRecord
    @Environment(AppModel.self) private var model
    @State private var registering = false
    @State private var error: String?

    var body: some View {
        Button(registering ? "Check the Ledger's screen…" : "Register on Ledger") { register() }
            .accessibilityIdentifier("ledgerRegisterButton")
            .disabled(registering)
        if let error {
            Text(error).font(.footnote).foregroundStyle(.red)
                .accessibilityIdentifier("ledgerRegisterError")
        }
    }

    private func register() {
        registering = true
        error = nil
        Task {
            defer { registering = false }
            do { try await model.registerLedger(record: record) } catch { self.error = error.localizedDescription }
        }
    }
}

/// The receive card's check: the Ledger shows the address so the user can
/// compare it with the phone's before sharing it.
struct LedgerVerifyAddressButton: View {
    let record: MultisigAccountRecord
    let index: UInt32
    @Environment(AppModel.self) private var model
    @State private var checking = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        Button(checking ? "Check the Ledger's screen…" : "Verify on Ledger") { verify() }
            .accessibilityIdentifier("ledgerVerifyAddressButton")
            .disabled(checking)
        if let result {
            Text(result)
                .font(.footnote)
                .foregroundStyle(failed ? .red : .green)
                .accessibilityIdentifier("ledgerVerifyAddressResult")
        }
    }

    private func verify() {
        checking = true
        result = nil
        Task {
            defer { checking = false }
            do {
                _ = try await model.verifyLedgerAddress(record: record, index: index)
                failed = false
                result = "The Ledger derived this same address. Compare it with the one on its screen."
            } catch {
                failed = true
                result = error.localizedDescription
            }
        }
    }
}
