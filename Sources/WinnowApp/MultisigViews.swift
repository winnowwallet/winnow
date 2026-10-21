import WalletCore
import SwiftUI

/// Raw k-of-n multisig accounts, in Advanced mode's Wallet tab only: a
/// descriptor in, addresses and coins out, and spends as PSBT text passed
/// between signers. Nothing here appears in Simple mode.
enum MultisigRoute: Hashable {
    case add
    case pairLedger
    case account(String)
    case psbt(String)
}

/// The Wallet tab's multisig section.
struct MultisigSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if let notice = model.multisigStorageNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("multisigStorageNotice")
            }
            ForEach(model.multisigAccounts) { record in
                NavigationLink(value: MultisigRoute.account(record.id)) {
                    LabeledContent(record.name, value: satsText(record.balance))
                }
                .accessibilityIdentifier("multisigAccount-\(record.id)")
            }
            NavigationLink(value: MultisigRoute.add) { Text("Add multisig account") }
                .accessibilityIdentifier("multisigAddButton")
            NavigationLink(value: MultisigRoute.pairLedger) { Text("Pair a Ledger (2-of-2)") }
                .accessibilityIdentifier("multisigPairLedgerButton")
        } header: {
            Text("Multisig")
        } footer: {
            Text("k-of-n Taproot accounts with other signers: tr(NUMS, sortedmulti_a(k, …)) descriptors and PSBTs, nothing more. Any k signers can spend. A paired Ledger signs over Bluetooth after showing the payment on its screen.")
        }
    }

    @ViewBuilder
    static func destination(_ route: MultisigRoute) -> some View {
        switch route {
        case .add: MultisigAddView()
        case .pairLedger: LedgerPairView()
        case let .account(id): MultisigAccountView(recordID: id)
        case let .psbt(id): MultisigPSBTView(recordID: id)
        }
    }
}

/// A title and a value whose text keeps its own accessibility identifier,
/// which `LabeledContent` merges away.
struct MultisigValueRow: View {
    let title: String
    let value: String
    let identifier: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(identifier)
        }
    }
}

/// A literal (an address, a key expression) wrapped by character so no
/// hyphen is drawn inside it, with a copy button.
struct MultisigLiteralRow: View {
    let text: String
    let copyIdentifier: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ReviewAddress(address: text)
            Button(copied ? "Copied" : "Copy") {
                ClipboardPolicy.interchange.apply(text)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier(copyIdentifier)
        }
    }
}

// MARK: - Add

struct MultisigAddView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var descriptor = ""
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    private var keyExpression: String? { try? model.multisigKeyExpression() }

    /// The pasted text read as an account for this phone, or why not.
    private var validation: Result<MultisigAccount, any Error>? {
        let text = descriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Result { try model.multisigAccount(validating: text) }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("multisigNameField")
            } footer: {
                Text("Winnow watches the account from the next block it scans. Coins the account received before that are not found.")
            }

            Section {
                if let keyExpression {
                    MultisigLiteralRow(text: keyExpression, copyIdentifier: "multisigKeyExpressionCopy")
                    CopyableIdentifier(
                        value: "tr(\(Taproot.unspendableInternalKey.hex),sortedmulti_a(2,\(keyExpression),OTHER_KEY))",
                        abbreviated: true, label: "Copy 2-of-2 template", accessibilityID: "multisigTemplateCopy")
                } else {
                    Text("This wallet has no shareable account key.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("This phone's key")
            } footer: {
                Text("One signer must be this key. Every signer is an extended public key with its origin and the /<0;1>/* suffix; the internal key is the unspendable NUMS point.")
            }

            Section("Descriptor") {
                TextField("tr(NUMS,sortedmulti_a(k,…))", text: $descriptor, axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(3 ... 8)
                    .accessibilityIdentifier("multisigDescriptorField")
                Button("Paste") { descriptor = model.pasteboardText() ?? "" }
                    .accessibilityIdentifier("multisigDescriptorPasteButton")
                switch validation {
                case let .success(account):
                    LabeledContent("Policy", value: "\(account.threshold) of \(account.signers.count)")
                    if let address = try? account.address(index: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("First address").font(.caption).foregroundStyle(.secondary)
                            ReviewAddress(address: address)
                        }
                    }
                case let .failure(failure):
                    Text(failure.localizedDescription)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("multisigDescriptorError")
                case nil:
                    EmptyView()
                }
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Add multisig account")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { save() }
                    .accessibilityIdentifier("multisigSaveButton")
                    .disabled(saving || DisplayName.normalized(name) == nil
                        || (try? validation?.get()) == nil)
            }
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.addMultisigAccount(name: name, descriptor: descriptor)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Account

struct MultisigAccountView: View {
    let recordID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirmRemove = false

    private var record: MultisigAccountRecord? { model.multisigAccounts.first { $0.id == recordID } }

    var body: some View {
        Form {
            if let record, let account = try? model.multisigAccount(for: record) {
                Section {
                    MultisigValueRow(title: "Balance", value: satsText(record.balance), identifier: "multisigBalance")
                    MultisigValueRow(title: "Policy", value: "\(account.threshold) of \(account.signers.count)",
                                     identifier: "multisigPolicy")
                    if let ledger = record.ledger {
                        MultisigValueRow(title: "Ledger", value: String(format: "%08x", ledger.masterFingerprint),
                                         identifier: "multisigLedgerFingerprint")
                    }
                }
                receiveSection(record, account)
                Section("Spend") {
                    NavigationLink(value: MultisigRoute.psbt(record.id)) { Text("New or pasted PSBT") }
                        .accessibilityIdentifier("multisigPSBTButton")
                }
                coinsSection(record)
                Section("Descriptor") {
                    CopyableTextBlock(text: record.descriptor)
                }
                Section {
                    Button("Remove account", role: .destructive) { confirmRemove = true }
                        .accessibilityIdentifier("multisigRemoveButton")
                }
            } else {
                Text("This multisig account is no longer on this phone.")
                    .foregroundStyle(.secondary)
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(record?.name ?? "Multisig")
        .confirmationDialog("Remove this account from this phone?", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { remove() }
        } message: {
            Text("Only an empty account can be removed. The other signers keep theirs.")
        }
    }

    @ViewBuilder
    private func receiveSection(_ record: MultisigAccountRecord, _ account: MultisigAccount) -> some View {
        Section {
            if let address = try? account.address(index: record.nextReceiveIndex) {
                QRCodeView(content: address)
                    .frame(maxWidth: 220)
                    .frame(maxWidth: .infinity)
                MultisigLiteralRow(text: address, copyIdentifier: "multisigReceiveAddressCopy")
            }
            if record.ledger != nil {
                LedgerVerifyAddressButton(record: record, index: record.nextReceiveIndex)
            }
            Button("New address") {
                Task {
                    do { try await model.newMultisigReceiveAddress(id: record.id) } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .accessibilityIdentifier("multisigNewAddressButton")
        } header: {
            Text("Receive · index \(record.nextReceiveIndex)")
        } footer: {
            Text("The same address on every signer's device: check it there before sharing it.")
        }
    }

    @ViewBuilder
    private func coinsSection(_ record: MultisigAccountRecord) -> some View {
        Section("Coins") {
            if record.utxos.isEmpty {
                Text("No coins yet.").foregroundStyle(.secondary)
            }
            ForEach(record.utxos, id: \.outpoint) { coin in
                VStack(alignment: .leading, spacing: 2) {
                    Text(satsText(coin.amount)).font(.system(.callout, design: .monospaced))
                    // One line per coin: outpoint, address slot, confirmation.
                    Text("\(coin.txid.displayHex.prefix(16))…:\(coin.vout) · \(coin.chain == .change ? "change" : "receive") \(coin.index) · \(coin.height == 0 ? "pending" : "block \(coin.height)")")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func remove() {
        Task {
            do {
                try await model.removeMultisigAccount(id: recordID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - PSBT

/// One raw screen for a spend: create a PSBT or paste one, check it against
/// the account's own coins, add this phone's signature, combine the other
/// signers' copies, and broadcast once enough signatures verify. Signers
/// sign independently and in any order; there is no round state to lose.
struct MultisigPSBTView: View {
    let recordID: String
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var address = ""
    @State private var amountText = ""
    @State private var feeRateText = ""
    @State private var pasted = ""
    @State private var working: PSBT?
    @State private var review: MultisigAccount.SpendReview?
    @State private var reviewError: String?
    @State private var approvals: Set<Int> = []
    @State private var output: String?
    @State private var error: String?
    @State private var busy = false
    @State private var broadcastTxid: Data?
    @State private var operationEpoch = SensitivePresentationEpoch()
    @State private var operationTask: Task<Void, Never>?

    private var record: MultisigAccountRecord? { model.multisigAccounts.first { $0.id == recordID } }
    private var account: MultisigAccount? { record.flatMap { try? model.multisigAccount(for: $0) } }
    private var ownPositions: Set<Int> { record.map { model.multisigOwnSignerPositions($0) } ?? [] }
    /// The paired Ledger's signer position, when the account has one.
    private var ledgerPosition: Int? {
        guard let ledger = record?.ledger, let account else { return nil }
        return account.signers.firstIndex {
            $0.origin?.fingerprint == ledger.masterFingerprint && $0.origin?.path == ledger.keyPath
        }
    }

    /// Rechecks the proposal whenever the account's coins or frontiers move.
    private struct TrustedState: Equatable {
        var utxos: [WalletUTXO]
        var nextReceiveIndex: UInt32
        var nextChangeIndex: UInt32
    }

    private var trustedState: TrustedState? {
        record.map { TrustedState(utxos: $0.utxos, nextReceiveIndex: $0.nextReceiveIndex,
                                  nextChangeIndex: $0.nextChangeIndex) }
    }

    var body: some View {
        Form {
            if let broadcastTxid {
                Section {
                    Text("Payment sent")
                        .font(.headline)
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("multisigPaymentSent")
                    CopyableIdentifier(value: broadcastTxid.displayHex, accessibilityID: "multisigTxidCopy")
                }
            } else {
                if working == nil { createSection }
                pasteSection
                if working != nil {
                    reviewSection
                    actionsSection
                }
                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("multisigError")
                    }
                }
                if let output {
                    Section("PSBT to share") {
                        CopyableTextBlock(text: output)
                    }
                }
            }
        }
        .navigationTitle("Multisig PSBT")
        .task {
            guard feeRateText.isEmpty else { return }
            let rate = await model.resolvedFeeRate(priority: .medium, override: nil)
            if feeRateText.isEmpty { feeRateText = String(format: "%.1f", rate) }
        }
        .task(id: trustedState) { refreshReview() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { clearState() }
        }
        .onDisappear { clearState() }
    }

    private var createSection: some View {
        Section {
            TextField("Address", text: $address)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("multisigAddressField")
            TextField("Amount (sats)", text: $amountText)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("multisigAmountField")
            TextField("Fee rate (sat/vB)", text: $feeRateText)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("multisigFeeRateField")
            Button("Create PSBT") { create() }
                .accessibilityIdentifier("multisigCreateButton")
                .disabled(busy || Int64(amountText) == nil || Double(feeRateText) == nil
                    || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("New payment")
        } footer: {
            Text("Change returns to this account's next change address. The fee may be at most a tenth of the coins spent.")
        }
    }

    private var pasteSection: some View {
        Section {
            TextField("Paste a PSBT (Base64)", text: $pasted, axis: .vertical)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .lineLimit(1 ... 4)
                .accessibilityIdentifier("psbtField")
            Button("Paste from clipboard") { pasted = model.pasteboardText() ?? "" }
                .accessibilityIdentifier("psbtPasteButton")
            Button(working == nil ? "Use this PSBT" : "Combine") { addPasted() }
                .accessibilityIdentifier("addPSBTButton")
                .disabled(busy || pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text(working == nil ? "Or paste a PSBT" : "Another signer's PSBT")
        } footer: {
            Text("A pasted PSBT is combined with the one here. Winnow signs only a spend of coins this account already has.")
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        Section {
            if let review {
                ForEach(review.outputs.indices, id: \.self) { index in
                    let line = review.outputs[index]
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(line.isAccountOwned ? "Back to this account" : "Pays")
                                .font(.caption)
                                .foregroundStyle(line.isAccountOwned ? Color.secondary : Color.primary)
                            Spacer()
                            Text(satsText(line.amount)).font(.system(.callout, design: .monospaced))
                        }
                        ReviewAddress(address: AddressDecoder.address(for: line.scriptPubKey, network: model.network)
                            ?? line.scriptPubKey.hex)
                    }
                }
                LabeledContent("Inputs", value: satsText(review.inputTotal))
                MultisigValueRow(title: "Fee", value: satsText(review.fee), identifier: "multisigFee")
                if let account {
                    MultisigValueRow(title: "Signatures", value: "\(approvals.count) of \(account.threshold)",
                                     identifier: "multisigSignatureCount")
                }
            } else {
                Label("Winnow cannot safely review this PSBT", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(reviewError ?? "The account or PSBT is unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("multisigReviewError")
            }
        } header: {
            Text("Check this payment")
        } footer: {
            Text("Check the addresses, amounts and fee on every signer's device before signing.")
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if let account {
            let signedHere = !ownPositions.isEmpty && ownPositions.isSubset(of: approvals)
            Section {
                Button("Add this phone's signature") { sign() }
                    .accessibilityIdentifier("multisigSignButton")
                    .disabled(busy || review == nil || signedHere || approvals.count >= account.threshold)
                if let ledgerPosition {
                    Button("Sign with Ledger") { signWithLedger() }
                        .accessibilityIdentifier("multisigLedgerSignButton")
                        .disabled(busy || review == nil || approvals.contains(ledgerPosition)
                            || approvals.count >= account.threshold)
                }
                Button(busy ? "Working…" : "Finalize and broadcast") { broadcast() }
                    .accessibilityIdentifier("multisigBroadcastButton")
                    .disabled(busy || review == nil || approvals.count < account.threshold)
            } header: {
                Text("Signing")
            } footer: {
                Text(nextStep(threshold: account.threshold, signedHere: signedHere))
                    .accessibilityIdentifier("multisigNextStep")
            }
        }
    }

    private func nextStep(threshold: Int, signedHere: Bool) -> String {
        if approvals.count >= threshold { return "Enough signatures verify. Finalize and broadcast." }
        if let ledgerPosition, !approvals.contains(ledgerPosition) {
            return signedHere
                ? "Sign with the Ledger: check the payment on its screen before approving."
                : "Add this phone's signature and the Ledger's, in either order. Check the payment on the Ledger's screen."
        }
        if signedHere {
            return "Share the PSBT below with the other signers, then combine their signed copies here."
        }
        return "Check the payment, then add this phone's signature. Signers can sign in any order."
    }

    // MARK: Actions

    private func create() {
        guard let record, let amount = Int64(amountText), let rate = Double(feeRateText) else { return }
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                install(try await model.createMultisigSpend(record: record, address: address, amount: amount,
                                                            feeRateSatPerVByte: rate))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func addPasted() {
        error = nil
        do {
            guard let record else { return }
            let incoming = try PSBT(base64: pasted.trimmingCharacters(in: .whitespacesAndNewlines))
            let candidate: PSBT
            if let working {
                candidate = try model.combineMultisigSpend(working, with: incoming, record: record)
            } else {
                _ = try model.reviewMultisigSpend(incoming, record: record)
                candidate = incoming
            }
            install(candidate)
            pasted = ""
            model.journalPSBT(stage: "multisig-combined", psbt: candidate)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func install(_ psbt: PSBT) {
        working = psbt
        output = try? psbt.base64V0()
        refreshReview()
    }

    private func refreshReview() {
        guard let working, let record else {
            review = nil
            reviewError = nil
            approvals = []
            return
        }
        do {
            review = try model.reviewMultisigSpend(working, record: record)
            reviewError = nil
            approvals = model.multisigApprovals(working, record: record)
        } catch {
            review = nil
            reviewError = error.localizedDescription
            approvals = []
        }
    }

    private func sign() {
        guard let working, let record else { return }
        run { token in
            let signed = try await model.signMultisigSpend(working, record: record)
            guard accepts(token) else { return }
            install(signed)
        }
    }

    private func signWithLedger() {
        guard let working, let record else { return }
        run { token in
            let signed = try await model.signMultisigSpendWithLedger(working, record: record)
            guard accepts(token) else { return }
            install(signed)
        }
    }

    private func broadcast() {
        guard let working, let record else { return }
        run { token in
            let txid = try await model.broadcastMultisigSpend(working, record: record)
            guard accepts(token) else { return }
            broadcastTxid = txid
        }
    }

    /// One operation at a time; a result from a presentation that has since
    /// been invalidated never reaches the screen.
    private func run(_ body: @escaping @MainActor (SensitivePresentationEpoch.Token) async throws -> Void) {
        operationTask?.cancel()
        let token = operationEpoch.begin()
        busy = true
        error = nil
        operationTask = Task { @MainActor in
            do {
                try await body(token)
            } catch is CancellationError {
            } catch {
                if accepts(token) { self.error = error.localizedDescription }
            }
            if accepts(token) {
                busy = false
                operationTask = nil
            }
        }
    }

    private func accepts(_ token: SensitivePresentationEpoch.Token) -> Bool {
        operationEpoch.accepts(token, whilePresentationIsAllowed: scenePhase != .background)
    }

    /// Leaving or backgrounding drops the proposal; the shared PSBT text is
    /// the only copy that travels between signers.
    private func clearState() {
        operationEpoch.invalidate()
        operationTask?.cancel()
        operationTask = nil
        busy = false
        working = nil
        output = nil
        pasted = ""
        review = nil
        reviewError = nil
        approvals = []
    }
}
