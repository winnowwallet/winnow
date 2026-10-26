import SwiftUI
import WalletCore

/// Builds a k-of-n account from this phone's key, the other signers' keys
/// (other Winnows show theirs under "This phone's key" when joining) and
/// optionally a Ledger's, with an optional timelocked recovery path. Keys
/// pasted together, a phone's with its Ledger's, count as one signer, and
/// the Ledger can count with this phone the same way: the account is then
/// nested, any k of its members spending with every key each has. The
/// finished descriptor is shown to share: every other signer adds the same
/// account by pasting it under "Join with a descriptor".
struct MultisigBuildView: View {
    enum RecoveryMode: String, CaseIterable, Identifiable {
        case fewerSigners, separateKey
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var otherMembers: [[String]] = []
    @State private var includeLedger = false
    @State private var ledgerWithPhone = false
    @State private var threshold = 2
    @State private var withRecovery = false
    @State private var recoveryMode: RecoveryMode = .fewerSigners
    @State private var recoveryThreshold = 1
    @State private var recoveryKey = ""
    @State private var recoveryDays = 30
    @State private var creating = false
    @State private var error: String?
    @State private var created: MultisigAccountRecord?

    /// About 144 blocks a day; BIP68 counts at most 65,535 blocks.
    static func blocks(forDays days: Int) -> UInt32 {
        UInt32(min(days * 144, Int(MultisigAccount.maximumRecoveryBlocks)))
    }

    /// The keys of one pasted member: one per line or space.
    static func member(from text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Signers as the policy counts them: members, not keys.
    private var signerCount: Int { 1 + otherMembers.count + (includeLedger && !ledgerWithPhone ? 1 : 0) }

    /// Some member holds more than one key, so the account has a leaf per
    /// group of members and its recovery path takes a separate key.
    private var isNested: Bool { (includeLedger && ledgerWithPhone) || otherMembers.contains { $0.count > 1 } }

    private var recoveryPlan: MultisigAccount.RecoveryPlan? {
        guard withRecovery else { return nil }
        let blocks = Self.blocks(forDays: recoveryDays)
        switch recoveryMode {
        case .fewerSigners: return .fewerSigners(threshold: recoveryThreshold, blocks: blocks)
        case .separateKey:
            return .separateKeys(threshold: 1, keys: [recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)],
                                 blocks: blocks)
        }
    }

    var body: some View {
        Form {
            if let created {
                createdSection(created)
            } else {
                Section {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("multisigBuildNameField")
                }
                signersSection
                thresholdSection
                recoverySection
                Section {
                    Button(creating ? "Creating…" : "Create account") { create() }
                        .accessibilityIdentifier("multisigBuildCreateButton")
                        .disabled(creating || DisplayName.normalized(name) == nil || signerCount < 2
                            || (withRecovery && recoveryMode == .separateKey && recoveryKey.isEmpty))
                } footer: {
                    Text(includeLedger
                        ? "Open the Bitcoin app on the Ledger (Bitcoin Test on signet), version 2.2.1 or later for a recovery path or a nested account. It reads the Ledger's key, then asks you to approve the account on the Ledger."
                        : "Winnow watches the account from the next block it scans.")
                }
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("multisigBuildError") }
                }
            }
        }
        .navigationTitle("New multisig account")
        .onChange(of: signerCount) { _, count in
            threshold = min(max(threshold, 1), count)
            recoveryThreshold = min(max(recoveryThreshold, 1), count)
        }
        .onChange(of: isNested) { _, nested in
            if nested { recoveryMode = .separateKey }
        }
    }

    private var signersSection: some View {
        Section {
            if let key = try? model.multisigKeyExpression() {
                VStack(alignment: .leading, spacing: 4) {
                    Text(includeLedger && ledgerWithPhone ? "This phone, with its Ledger" : "This phone")
                        .font(.caption).foregroundStyle(.secondary)
                    MultisigLiteralRow(text: key, copyIdentifier: "multisigBuildOwnKeyCopy")
                }
            }
            ForEach(otherMembers.indices, id: \.self) { index in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if otherMembers[index].count > 1 {
                            Text("\(otherMembers[index].count) keys, one signer").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(otherMembers[index], id: \.self) { key in
                            ReviewAddress(address: key)
                        }
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) { otherMembers.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove this signer")
                }
            }
            Button("Paste a signer's key") {
                let member = Self.member(from: model.pasteboardText() ?? "")
                if !member.isEmpty, !otherMembers.contains(member) { otherMembers.append(member) }
            }
            .accessibilityIdentifier("multisigBuildPasteKeyButton")
            Toggle("Include a Ledger", isOn: $includeLedger)
                .accessibilityIdentifier("multisigBuildLedgerToggle")
            if includeLedger {
                Toggle("Count the Ledger with this phone as one signer", isOn: $ledgerWithPhone)
                    .accessibilityIdentifier("multisigBuildLedgerWithPhoneToggle")
            }
        } header: {
            Text("Signers · \(signerCount)")
        } footer: {
            Text("Another Winnow shows its key under Join with a descriptor → This phone's key, alone or together with its Ledger's. Any signer's key works: [fingerprint/path]xpub…/<0;1>/*. Keys pasted together count as one signer, which spends only with all of them.")
        }
    }

    private var thresholdSection: some View {
        Section {
            Stepper("Any \(threshold) of \(signerCount) spend at once", value: $threshold, in: 1 ... max(signerCount, 1))
                .accessibilityIdentifier("multisigBuildThresholdStepper")
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        Section {
            Toggle("Recovery after a delay", isOn: $withRecovery)
                .accessibilityIdentifier("multisigBuildRecoveryToggle")
            if withRecovery {
                if isNested {
                    Text("After the delay: a recovery key").foregroundStyle(.secondary)
                } else {
                    Picker("After the delay", selection: $recoveryMode) {
                        Text("Fewer signers").tag(RecoveryMode.fewerSigners)
                        Text("A recovery key").tag(RecoveryMode.separateKey)
                    }
                    .pickerStyle(.segmented)
                }
                switch recoveryMode {
                case .fewerSigners:
                    Stepper("Any \(recoveryThreshold) of the \(signerCount) signers", value: $recoveryThreshold,
                            in: 1 ... max(signerCount, 1))
                        .accessibilityIdentifier("multisigBuildRecoveryThresholdStepper")
                case .separateKey:
                    if recoveryKey.isEmpty {
                        Button("Paste the recovery key") {
                            recoveryKey = model.pasteboardText()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        }
                        .accessibilityIdentifier("multisigBuildPasteRecoveryKeyButton")
                    } else {
                        ReviewAddress(address: recoveryKey)
                        Button("Remove the recovery key", role: .destructive) { recoveryKey = "" }
                    }
                }
                Stepper("After \(recoveryDays) days (\(Self.blocks(forDays: recoveryDays)) blocks)", value: $recoveryDays,
                        in: 1 ... 455)
                    .accessibilityIdentifier("multisigBuildRecoveryDaysStepper")
            }
        } footer: {
            if withRecovery {
                Text(isNested
                    ? "The delay counts from when each coin is received. Once it passes, the recovery key can spend that coin alone. A nested account's recovery path is a separate key: fewer of the same members would need a leaf per group."
                    : "The delay counts from when each coin is received. Once it passes, the recovery path can spend that coin without the other signers, so move coins before then if you do not want that.")
            }
        }
    }

    private func createdSection(_ record: MultisigAccountRecord) -> some View {
        Section {
            Text("Account created").font(.headline).foregroundStyle(.green)
                .accessibilityIdentifier("multisigBuildCreated")
            QRCodeView(content: record.descriptor)
                .frame(maxWidth: 260)
                .frame(maxWidth: .infinity)
            CopyableTextBlock(text: record.descriptor)
            NavigationLink(value: MultisigRoute.account(record.id)) { Text("Open the account") }
        } footer: {
            Text("Every other signer adds this same descriptor under Join with a descriptor. Check that each one shows the same first address. A member with a Ledger then registers the account on it from the account screen.")
        }
    }

    private func create() {
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                created = try await model.createMultisigAccount(name: name, threshold: threshold, otherMembers: otherMembers,
                                                                includeLedger: includeLedger, ledgerWithPhone: ledgerWithPhone,
                                                                recovery: recoveryPlan)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
