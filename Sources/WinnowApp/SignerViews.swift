import SwiftUI
import WalletCore

/// Names for keys on screen: fingerprints, and a signer's name where the
/// phone knows one.
enum SignerLabel {
    /// "6824f543", or "?" for text that is not a signer key.
    static func fingerprint(of key: String, network: BitcoinNetwork) -> String {
        guard let origin = (try? MultisigAccount.signerKey(key, network: network))?.origin else { return "?" }
        return String(format: "%08x", origin.fingerprint)
    }

    /// "5992698d" for a Ledger, "6824f543 · 1a2b3c4d" for saved keys.
    static func keysText(_ record: SignerRecord, network: BitcoinNetwork) -> String {
        record.keys.map { fingerprint(of: $0, network: network) }.joined(separator: " · ")
    }
}

/// Settings → Signers: this phone's key, the Ledgers it paired and the keys
/// other people sent, which Wallet → Multisig builds accounts from.
struct SignersSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            NavigationLink { SignersView() } label: {
                LabeledContent("Signers", value: summary)
            }
            .accessibilityIdentifier("signersButton")
        } footer: {
            Text("Pair a Ledger once, and save the keys other people send; multisig accounts under Wallet are built from them.")
        }
    }

    private var summary: String {
        let ledgers = model.signers.filter(\.isLedger).count
        let saved = model.signers.count - ledgers
        let parts = [ledgers == 0 ? nil : "\(ledgers) Ledger\(ledgers == 1 ? "" : "s")",
                     saved == 0 ? nil : "\(saved) saved"].compactMap { $0 }
        return parts.isEmpty ? "This phone" : parts.joined(separator: ", ")
    }
}

struct SignersView: View {
    @Environment(AppModel.self) private var model
    @State private var error: String?

    var body: some View {
        Form {
            if let notice = model.signerStorageNotice {
                Section {
                    Text(notice).font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("signerStorageNotice")
                }
            }
            ownSection
            ledgersSection
            keysSection
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Signers")
    }

    private var ownSection: some View {
        Section {
            if let key = try? model.multisigKeyExpression() {
                MultisigValueRow(title: "Fingerprint", value: SignerLabel.fingerprint(of: key, network: model.network),
                                 identifier: "signersOwnFingerprint")
                MultisigLiteralRow(text: key, copyIdentifier: "signersOwnKeyCopy")
            } else {
                Text("This wallet has no shareable account key.").foregroundStyle(.secondary)
            }
        } header: {
            Text("This phone")
        } footer: {
            Text("Send this key to whoever builds an account you join. To count this phone and its Ledger as one signer of their account, send both keys together from Wallet → Multisig → Join with a descriptor.")
        }
    }

    private var ledgersSection: some View {
        Section {
            ForEach(model.signers.filter(\.isLedger)) { record in
                NavigationLink { SignerDetailView(recordID: record.id) } label: { SignerRow(record: record) }
            }
            NavigationLink { LedgerPairView() } label: { Text("Pair a Ledger") }
                .accessibilityIdentifier("signersPairLedgerButton")
        } header: {
            Text("Ledgers")
        } footer: {
            Text("Paired once, a Ledger can be a member of any account you build, or sign with this phone as one member; the account is then approved on its screen.")
        }
    }

    private var keysSection: some View {
        Section {
            ForEach(model.signers.filter { !$0.isLedger }) { record in
                NavigationLink { SignerDetailView(recordID: record.id) } label: { SignerRow(record: record) }
            }
            NavigationLink { SignerKeysAddView() } label: { Text("Save keys someone sent") }
                .accessibilityIdentifier("signersAddKeysButton")
        } header: {
            Text("Other people's keys")
        } footer: {
            Text("One key, or a phone's and its Ledger's sent together, which then count as one signer.")
        }
    }
}

struct SignerRow: View {
    let record: SignerRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.name)
            Text(SignerLabel.keysText(record, network: model.network) + (record.keys.count > 1 ? " · one signer" : ""))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("signerRow-\(record.id)")
    }
}

/// One signer: rename it, read its keys, or remove it.
struct SignerDetailView: View {
    let recordID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?

    private var record: SignerRecord? { model.signers.first { $0.id == recordID } }

    var body: some View {
        Form {
            if let record {
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("signerNameField")
                        .onSubmit { rename() }
                } footer: {
                    Text(record.isLedger ? "A paired Ledger. Its key sits at the Ledger's multisig path on this network."
                        : "\(record.keys.count == 1 ? "A key" : "\(record.keys.count) keys that sign together,") someone sent you.")
                }
                Section("Keys") {
                    ForEach(record.keys, id: \.self) { key in
                        MultisigLiteralRow(text: key, copyIdentifier: "signerKeyCopy-\(key.suffix(8))")
                    }
                }
                Section {
                    Button("Remove signer", role: .destructive) { remove() }
                        .accessibilityIdentifier("signerRemoveButton")
                } footer: {
                    Text("Accounts already built with it are not changed.")
                }
            } else {
                Text("This signer is no longer on this phone.").foregroundStyle(.secondary)
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(record?.name ?? "Signer")
        .onAppear { name = record?.name ?? "" }
        .onDisappear { rename() }
    }

    private func rename() {
        guard let record, let normalized = DisplayName.normalized(name), normalized != record.name else { return }
        Task {
            do { try await model.renameSigner(id: record.id, name: normalized) } catch { self.error = error.localizedDescription }
        }
    }

    private func remove() {
        Task {
            do {
                try await model.removeSigner(id: recordID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Pairs a Ledger: its key comes from its own Bitcoin app over Bluetooth
/// and is filed among this phone's signers under the name given here.
struct LedgerPairView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pairing = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ledgerNameField")
            } footer: {
                Text("What this phone calls the Ledger, such as Nano X.")
            }

            Section {
                Text("1. Unlock the Ledger and open its Bitcoin app, version 2.1.2 or later (Bitcoin Test on signet).")
                Text("2. Tap Pair. The first time, confirm the same pairing code on the phone and the Ledger.")
                Text("3. The Ledger's multisig key is saved here. Nothing is approved on the Ledger until an account uses it.")
            } header: {
                Text("Steps")
            }

            Section {
                Button(pairing ? "Pairing…" : "Pair") { pair() }
                    .accessibilityIdentifier("ledgerPairButton")
                    .disabled(pairing || DisplayName.normalized(name) == nil)
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

/// Saves keys someone sent as one signer: a single key, or a phone's and
/// its Ledger's pasted together.
struct SignerKeysAddView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?

    private var keys: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }

    /// Why the pasted text is not a signer, if it is not.
    private var parseError: String? {
        for key in keys {
            do { _ = try MultisigAccount.signerKey(key, network: model.network) } catch { return error.localizedDescription }
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("signerKeysNameField")
            } footer: {
                Text("Whose keys these are, such as Bob, or Bob's phone and Ledger.")
            }
            Section {
                Button("Paste keys") { text = model.pasteboardText() ?? "" }
                    .accessibilityIdentifier("signerKeysPasteButton")
                ForEach(keys, id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(SignerLabel.fingerprint(of: key, network: model.network))
                            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        ReviewAddress(address: key)
                    }
                }
                if let parseError {
                    Text(parseError).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("signerKeysError")
                } else if keys.count > 1 {
                    Text("\(keys.count) keys that always sign together: one signer.").font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Another Winnow shows its key under Wallet → Multisig → Join with a descriptor → This phone's key, alone or together with its Ledger's. Any signer's key works: [fingerprint/path]xpub…/<0;1>/*.")
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("signerKeysError") }
            }
        }
        .navigationTitle("Save keys")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { save() }
                    .accessibilityIdentifier("signerKeysSaveButton")
                    .disabled(saving || DisplayName.normalized(name) == nil || keys.isEmpty || parseError != nil)
            }
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.addSignerKeys(name: name, text: text)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// On the Join screen: this phone's key together with each paired Ledger's,
/// the share another phone's builder takes to count the two as one member.
struct MemberShareRows: View {
    let phoneKey: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let ledgers = model.signers.filter(\.isLedger)
        if ledgers.isEmpty {
            Text("Pair a Ledger under Settings → Signers to share this phone's key and the Ledger's together, as one signer.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(ledgers) { ledger in
            VStack(alignment: .leading, spacing: 4) {
                Text("This phone and \(ledger.name), as one signer").font(.caption).foregroundStyle(.secondary)
                MultisigLiteralRow(text: phoneKey + "\n" + ledger.keys[0], copyIdentifier: "multisigMemberShareCopy-\(ledger.id)")
            }
        }
    }
}
