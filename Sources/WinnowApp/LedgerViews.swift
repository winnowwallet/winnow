import SwiftUI
import WalletCore

/// Pairs a Ledger as the second signer of a new 2-of-2 account, in Advanced
/// mode's Multisig section. The Ledger's key comes from its own Bitcoin app;
/// the user checks the account on the Ledger's screen and approves it there.
struct LedgerPairView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pairing = false
    @State private var error: String?

    private var nameIsUsable: Bool {
        DisplayName.normalized(name).map(LedgerWalletPolicy.isValidName) ?? false
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ledgerNameField")
            } footer: {
                Text("The Ledger shows this name when it signs: plain letters, digits and punctuation, at most 64.")
            }

            Section {
                Text("1. Unlock the Ledger and open its Bitcoin app, version 2.1.2 or later (Bitcoin Test on signet).")
                Text("2. Tap Pair. The first time, confirm the same pairing code on the phone and the Ledger.")
                Text("3. On the Ledger, check the account and both keys, then approve.")
            } header: {
                Text("Steps")
            } footer: {
                Text("The account is tr(NUMS, sortedmulti_a(2, this phone, the Ledger)). Spending needs both: neither this phone nor the Ledger can pay alone, and losing either one loses the account.")
            }

            Section {
                Button(pairing ? "Pairing…" : "Pair") { pair() }
                    .accessibilityIdentifier("ledgerPairButton")
                    .disabled(pairing || !nameIsUsable)
                if pairing { ProgressView() }
            }

            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("ledgerPairError")
                }
            }
        }
        .navigationTitle("Pair a Ledger")
    }

    private func pair() {
        pairing = true
        error = nil
        Task {
            defer { pairing = false }
            do {
                try await model.pairLedger(name: name)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// On the Join screen: reads this phone's Ledger's key and shows it with the
/// phone's, the share another phone's builder pastes to count the two as
/// one signer of a nested account.
struct LedgerKeyShareRows: View {
    let phoneKey: String
    @Environment(AppModel.self) private var model
    @State private var reading = false
    @State private var ledgerKey: String?
    @State private var error: String?

    var body: some View {
        if let ledgerKey {
            VStack(alignment: .leading, spacing: 4) {
                Text("This phone and its Ledger, as one signer").font(.caption).foregroundStyle(.secondary)
                MultisigLiteralRow(text: phoneKey + "\n" + ledgerKey, copyIdentifier: "multisigMemberShareCopy")
            }
        } else {
            Button(reading ? "Reading the Ledger…" : "Add this phone's Ledger key") { read() }
                .accessibilityIdentifier("multisigLedgerKeyButton")
                .disabled(reading)
        }
        if let error {
            Text(error).font(.footnote).foregroundStyle(.red)
        }
    }

    private func read() {
        reading = true
        error = nil
        Task {
            defer { reading = false }
            do { ledgerKey = try await model.ledgerKeyExpression() } catch { self.error = error.localizedDescription }
        }
    }
}

/// On a joined account that names a Ledger key this phone has not paired:
/// registers the account on this phone's Ledger, which approves it on its
/// screen and must derive the phone's first address.
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
