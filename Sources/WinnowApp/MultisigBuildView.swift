import SwiftUI
import WalletCore

/// Builds a k-of-n account from members: this phone, a Ledger paired under
/// Settings → Signers, keys saved there or pasted now, or an account already
/// on this phone, whose keys then sign together. A member of several keys,
/// such as a phone with its Ledger, makes the account nested: any k of the
/// members spend, each with every key it has. An optional timelocked
/// recovery path. The finished descriptor is shown to share: every other
/// signer adds the same account under "Join with a descriptor", and a paired
/// Ledger among the members approves it on its screen here.
struct MultisigBuildView: View {
    enum RecoveryMode: String, CaseIterable, Identifiable {
        case fewerSigners, separateKey
        var id: String { rawValue }
    }

    /// One key of a member, with what to call it.
    struct Key: Identifiable, Equatable, Hashable {
        let key: String
        let label: String
        var id: String { key }
    }

    struct Member: Identifiable, Equatable {
        let id = UUID()
        var keys: [Key]

        /// "This phone + Nano X", each name once.
        var title: String {
            keys.map(\.label).reduce(into: [String]()) { names, label in
                if !names.contains(label) { names.append(label) }
            }.joined(separator: " + ")
        }
    }

    enum Picking: Identifiable {
        case newMember
        case into(UUID)
        var id: String {
            if case let .into(member) = self { return member.uuidString }
            return "new"
        }
    }

    enum Registration: Equatable {
        case registered(String)
        case failed(String)
    }

    static let phoneLabel = "This phone"

    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var members: [Member] = []
    @State private var threshold = 2
    @State private var picking: Picking?
    @State private var withRecovery = false
    @State private var recoveryMode: RecoveryMode = .fewerSigners
    @State private var recoveryThreshold = 1
    @State private var recoveryKey = ""
    @State private var recoveryDays = 30
    @State private var creating = false
    @State private var error: String?
    @State private var created: MultisigAccountRecord?
    @State private var registration: Registration?

    /// About 144 blocks a day; BIP68 counts at most 65,535 blocks.
    static func blocks(forDays days: Int) -> UInt32 {
        UInt32(min(days * 144, Int(MultisigAccount.maximumRecoveryBlocks)))
    }

    private var usedKeys: Set<String> { Set(members.flatMap { $0.keys.map(\.key) }) }

    /// Some member holds more than one key and fewer than all the members
    /// spend, so the account has a leaf per group and its recovery path
    /// takes a separate key.
    private var isNested: Bool { members.contains { $0.keys.count > 1 } && threshold < members.count }

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

    /// The paired Ledgers among the members, by name.
    private var pairedLedgerNames: [String] {
        model.signers.filter { $0.isLedger && usedKeys.contains($0.keys[0]) }.map(\.name)
    }

    /// The account these members make, or why they do not, shown before
    /// Create; a recovery key not pasted yet is left out of it.
    private var preview: Result<MultisigAccount, any Error>? {
        guard members.count >= 2 else { return nil }
        let recovery = withRecovery && recoveryMode == .separateKey && recoveryKey.isEmpty ? nil : recoveryPlan
        return Result {
            let descriptor = try MultisigAccount.descriptor(members: members.map { $0.keys.map(\.key) }, threshold: threshold,
                                                            recovery: recovery, network: model.network)
            return try MultisigAccount(descriptor: descriptor, network: model.network)
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
                } footer: {
                    Text("A Ledger shows the name when it registers the account: plain letters, digits and punctuation.")
                }
                membersSection
                thresholdSection
                recoverySection
                createSection
                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("multisigBuildError") }
                }
            }
        }
        .navigationTitle("New multisig account")
        .onAppear(perform: seed)
        .onChange(of: members.count) { _, count in
            threshold = min(max(threshold, 1), max(count, 1))
            recoveryThreshold = min(max(recoveryThreshold, 1), max(count, 1))
        }
        .onChange(of: isNested) { _, nested in
            if nested { recoveryMode = .separateKey }
        }
        .sheet(item: $picking) { picking in
            SignerPickerSheet(exclude: usedKeys) { keys in add(keys, to: picking) }
        }
    }

    /// This phone is the first member; the user adds the rest.
    private func seed() {
        guard members.isEmpty, let key = try? model.multisigKeyExpression() else { return }
        members = [Member(keys: [Key(key: key, label: Self.phoneLabel)])]
    }

    private func add(_ keys: [Key], to picking: Picking) {
        let fresh = keys.filter { !usedKeys.contains($0.key) }
        guard !fresh.isEmpty else { return }
        if case let .into(id) = picking, let index = members.firstIndex(where: { $0.id == id }) {
            members[index].keys += fresh
        } else {
            members.append(Member(keys: fresh))
        }
    }

    private func remove(_ key: Key, from member: Member) {
        guard let index = members.firstIndex(where: { $0.id == member.id }) else { return }
        members[index].keys.removeAll { $0 == key }
        if members[index].keys.isEmpty { members.remove(at: index) }
    }

    private var membersSection: some View {
        Section {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                MemberRow(member: member, index: index, onAddKey: { picking = .into(member.id) },
                          onRemove: { remove($0, from: member) })
            }
            Button("Add a member") { picking = .newMember }
                .accessibilityIdentifier("multisigBuildAddMemberButton")
        } header: {
            Text("Members · \(members.count)")
        } footer: {
            Text("A member is one signer: this phone, a paired Ledger, keys someone sent, or an account already on this phone. A member of several keys, such as a phone with its Ledger, spends only with all of them. Pair Ledgers and save keys under Settings → Signers.")
        }
    }

    /// One member: its keys, each by fingerprint and name, with a way to add
    /// a key that signs with it and to take a key out.
    struct MemberRow: View {
        let member: Member
        let index: Int
        let onAddKey: () -> Void
        let onRemove: (Key) -> Void
        @Environment(AppModel.self) private var model

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(member.title).font(.headline)
                    Spacer()
                    Button("Add a key that signs with this member", systemImage: "plus.circle", action: onAddKey)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("multisigBuildMemberAddKey-\(index)")
                }
                ForEach(member.keys) { key in
                    HStack {
                        Text(SignerLabel.fingerprint(of: key.key, network: model.network) + "  " + key.label)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if key.label != MultisigBuildView.phoneLabel {
                            Button(role: .destructive) { onRemove(key) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove this key")
                        }
                    }
                }
                if member.keys.count > 1 {
                    Text("\(member.keys.count) keys, one signer").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("multisigBuildMember-\(index)")
        }
    }

    private var thresholdSection: some View {
        Section {
            Stepper("Any \(threshold) of \(members.count) members spend", value: $threshold, in: 1 ... max(members.count, 1))
                .accessibilityIdentifier("multisigBuildThresholdStepper")
            previewRow
        }
    }

    @ViewBuilder
    private var previewRow: some View {
        switch preview {
        case let .success(account):
            Text(Self.previewText(account)).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("multisigBuildPolicyPreview")
        case let .failure(failure):
            Text(failure.localizedDescription).font(.footnote).foregroundStyle(.red)
                .accessibilityIdentifier("multisigBuildPolicyPreview")
        case nil:
            Text("Add at least one more member.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// "2 of 3 members: 3 ways to spend, each needing every key of its
    /// members, up to 3 keys." Pinned by AppTests/SignerRosterTests.
    static func previewText(_ account: MultisigAccount) -> String {
        guard account.isNested else {
            return "\(account.policySummary): any \(account.threshold) of the \(account.signers.count) keys sign a spend."
        }
        let largest = account.signersLeaves.map(\.keys.count).max() ?? 0
        return "\(account.policySummary): \(account.signersLeaves.count) ways to spend, each needing every key of its members, up to \(largest) keys. A member missing one of its keys cannot help."
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
                    Stepper("Any \(recoveryThreshold) of the \(members.count) signers", value: $recoveryThreshold,
                            in: 1 ... max(members.count, 1))
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

    private var createSection: some View {
        Section {
            Button(creating ? "Creating…" : "Create account") { create() }
                .accessibilityIdentifier("multisigBuildCreateButton")
                .disabled(creating || DisplayName.normalized(name) == nil || (try? preview?.get()) == nil
                    || (withRecovery && recoveryMode == .separateKey && recoveryKey.isEmpty))
        } footer: {
            Text(pairedLedgerNames.isEmpty
                ? "Winnow watches the account from the next block it scans."
                : "Then open the Bitcoin app on \(pairedLedgerNames.joined(separator: " and ")) (Bitcoin Test on signet; 2.2.1 or later for a recovery path or a nested account): the account is approved on its screen.")
        }
    }

    private func createdSection(_ record: MultisigAccountRecord) -> some View {
        Section {
            Text("Account created").font(.headline).foregroundStyle(.green)
                .accessibilityIdentifier("multisigBuildCreated")
            switch registration {
            case let .registered(ledger):
                Text("Approved on \(ledger).").font(.footnote).foregroundStyle(.green)
                    .accessibilityIdentifier("multisigBuildLedgerRegistered")
            case let .failed(reason):
                Text("The account is on this phone, but the Ledger did not register it: \(reason)")
                    .font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("multisigBuildLedgerError")
                LedgerRegisterButton(record: model.multisigAccounts.first { $0.id == record.id } ?? record)
            case nil:
                EmptyView()
            }
            QRCodeView(content: record.descriptor)
                .frame(maxWidth: 260)
                .frame(maxWidth: .infinity)
            CopyableTextBlock(text: record.descriptor)
            NavigationLink(value: MultisigRoute.account(record.id)) { Text("Open the account") }
        } footer: {
            Text("Every other signer adds this same descriptor under Join with a descriptor. Check that each one shows the same first address. A member whose Ledger is paired on their phone approves the account on it as they join.")
        }
    }

    private func create() {
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let record = try await model.createMultisigAccount(name: name, threshold: threshold,
                                                                   members: members.map { $0.keys.map(\.key) },
                                                                   recovery: recoveryPlan)
                created = record
                await register(record)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// A paired Ledger among the members approves the account now.
    private func register(_ record: MultisigAccountRecord) async {
        guard let ledger = pairedLedgerNames.first else { return }
        do {
            if try await model.registerPairedLedger(record: record) != nil { registration = .registered(ledger) }
        } catch {
            registration = .failed(error.localizedDescription)
        }
    }
}

/// Picks a member's keys: a paired Ledger, keys someone sent, an account
/// already on this phone (its keys, which then sign together), or keys
/// pasted now. A key already among the members cannot be picked twice.
struct SignerPickerSheet: View {
    let exclude: Set<String>
    let onPick: ([MultisigBuildView.Key]) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pasteError: String?

    var body: some View {
        NavigationStack {
            Form {
                ledgersSection
                savedSection
                accountsSection
                pasteSection
            }
            .navigationTitle("Add a member")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func pick(_ keys: [MultisigBuildView.Key]) {
        onPick(keys)
        dismiss()
    }

    private var ledgersSection: some View {
        Section("Ledgers") {
            let ledgers = model.signers.filter(\.isLedger)
            if ledgers.isEmpty {
                Text("None paired. Pair one under Settings → Signers.").foregroundStyle(.secondary)
            }
            ForEach(ledgers) { record in signerButton(record) }
        }
    }

    private var savedSection: some View {
        Section("Saved keys") {
            let saved = model.signers.filter { !$0.isLedger }
            if saved.isEmpty {
                Text("None saved. Save keys someone sent under Settings → Signers, or paste them below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(saved) { record in signerButton(record) }
        }
    }

    private func signerButton(_ record: SignerRecord) -> some View {
        Button { pick(record.keys.map { .init(key: $0, label: record.name) }) } label: {
            SignerRow(record: record)
        }
        .foregroundStyle(.primary)
        .disabled(record.keys.contains(where: exclude.contains))
        .accessibilityIdentifier("signerPick-\(record.id)")
    }

    private var accountsSection: some View {
        Section {
            if model.multisigAccounts.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            }
            ForEach(model.multisigAccounts) { record in accountRow(record) }
        } header: {
            Text("Accounts on this phone")
        } footer: {
            Text("A whole account as one member: every one of its keys then signs. Only an account that already needs all its keys can be one.")
        }
    }

    @ViewBuilder
    private func accountRow(_ record: MultisigAccountRecord) -> some View {
        if let account = try? model.multisigAccount(for: record) {
            let eligible = !account.isNested && account.threshold == account.signers.count
            let keys = account.signerExpressions
            Button {
                pick(keys.map { .init(key: $0, label: record.name) })
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name)
                    Text(eligible ? "\(keys.count) keys, one signer" : "\(account.policySummary): cannot be one member yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .disabled(!eligible || keys.contains(where: exclude.contains))
            .accessibilityIdentifier("signerPickAccount-\(record.id)")
        }
    }

    private var pasteSection: some View {
        Section {
            Button("Paste keys from the clipboard") { paste() }
                .accessibilityIdentifier("signerPickerPasteButton")
            if let pasteError {
                Text(pasteError).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("signerPickerPasteError")
            }
        } footer: {
            Text("One key, or several that always sign together, as another Winnow shows them under Join with a descriptor.")
        }
    }

    private func paste() {
        let keys = (model.pasteboardText() ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        guard !keys.isEmpty else {
            pasteError = "The clipboard holds no key."
            return
        }
        do {
            let labelled = try keys.map { key -> MultisigBuildView.Key in
                let single = try MultisigAccount.signerKey(key, network: model.network)
                return .init(key: key, label: "Pasted " + String(format: "%08x", single.origin?.fingerprint ?? 0))
            }
            pick(labelled)
        } catch {
            pasteError = error.localizedDescription
        }
    }
}
