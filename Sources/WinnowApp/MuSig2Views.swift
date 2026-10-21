import WalletCore
import SwiftUI

/// Raw MuSig2 accounts, in Advanced mode's Wallet tab only: a descriptor in,
/// addresses and coins out, and spends as PSBT text passed between signers.
/// Nothing here appears in Simple mode.
enum MuSig2Route: Hashable {
    case add
    case account(String)
    case psbt(String)
}

/// The Wallet tab's MuSig2 section.
struct MuSig2Section: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if let notice = model.muSig2StorageNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("musig2StorageNotice")
            }
            ForEach(model.muSig2Accounts) { record in
                NavigationLink(value: MuSig2Route.account(record.id)) {
                    LabeledContent(record.name, value: satsText(record.balance))
                }
                .accessibilityIdentifier("musig2Account-\(record.id)")
            }
            NavigationLink(value: MuSig2Route.add) { Text("Add MuSig2 account") }
                .accessibilityIdentifier("musig2AddButton")
        } header: {
            Text("MuSig2")
        } footer: {
            Text("n-of-n Taproot accounts with other signers: tr(musig(…)/<0;1>/*) descriptors and PSBTs, nothing more. Every signer signs every payment.")
        }
    }

    @ViewBuilder
    static func destination(_ route: MuSig2Route) -> some View {
        switch route {
        case .add: MuSig2AddView()
        case let .account(id): MuSig2AccountView(recordID: id)
        case let .psbt(id): MuSig2PSBTView(recordID: id)
        }
    }
}

/// A title and a value whose text keeps its own accessibility identifier,
/// which `LabeledContent` merges away.
struct MuSig2ValueRow: View {
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
struct MuSig2LiteralRow: View {
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

struct MuSig2AddView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var descriptor = ""
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false
    /// The card's key, read with a tap; saved with the account when the
    /// descriptor names it.
    @State private var satochipKey: Satochip.ParticipantKey?
    @State private var askingPIN = false
    @State private var readingCard = false

    private var keyExpression: String? { try? model.muSig2KeyExpression() }

    /// The pasted text read as an account for this phone, or why not.
    private var validation: Result<MuSig2Account, any Error>? {
        let text = descriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Result { try model.muSig2Account(validating: text) }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("musig2NameField")
            } footer: {
                Text("Winnow watches the account from the next block it scans. Coins the account received before that are not found.")
            }

            Section {
                if let keyExpression {
                    MuSig2LiteralRow(text: keyExpression, copyIdentifier: "musig2KeyExpressionCopy")
                    CopyableIdentifier(value: "tr(musig(\(keyExpression),OTHER_KEY)/<0;1>/*)", abbreviated: true,
                                       label: "Copy template", accessibilityID: "musig2TemplateCopy")
                } else {
                    Text("This wallet has no shareable account key.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("This phone's key")
            } footer: {
                Text("One musig() participant must be this key. Every participant is an extended public key with its origin and no suffix of its own; the descriptor ends in /<0;1>/*.")
            }

            Section {
                if let satochipKey {
                    MuSig2LiteralRow(text: satochipKey.keyExpression(network: model.hdKeyNetwork),
                                     copyIdentifier: "musig2SatochipKeyCopy")
                        .accessibilityIdentifier("musig2SatochipKey")
                }
                Button(readingCard ? "Reading…" : (satochipKey == nil ? "Read Satochip key" : "Read again")) {
                    askingPIN = true
                }
                .accessibilityIdentifier("musig2SatochipReadButton")
                .disabled(readingCard)
            } header: {
                Text("Satochip card")
            } footer: {
                Text("Optional. Tap the card to make a 2-of-2 between this phone and it. Set the card up and turn on its 2FA with the checker first.")
            }

            Section("Descriptor") {
                TextField("tr(musig(…)/<0;1>/*)", text: $descriptor, axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(3 ... 8)
                    .accessibilityIdentifier("musig2DescriptorField")
                Button("Paste") { descriptor = model.pasteboardText() ?? "" }
                    .accessibilityIdentifier("musig2DescriptorPasteButton")
                switch validation {
                case let .success(account):
                    LabeledContent("Participants", value: String(account.participants.count))
                    if satochipKey != nil {
                        Text(satochipRegistration == nil ? "The Satochip read above is not in this descriptor."
                            : "One participant is the Satochip read above.")
                            .font(.footnote)
                            .foregroundStyle(satochipRegistration == nil ? Color.orange : Color.secondary)
                            .accessibilityIdentifier("musig2SatochipInDescriptor")
                    }
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
                        .accessibilityIdentifier("musig2DescriptorError")
                case nil:
                    EmptyView()
                }
            }

            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Add MuSig2 account")
        .sheet(isPresented: $askingPIN) {
            SatochipPINSheet(purpose: "Read the card's key") { pin in readCard(pin: pin) }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") { save() }
                    .accessibilityIdentifier("musig2SaveButton")
                    .disabled(saving || DisplayName.normalized(name) == nil
                        || (try? validation?.get()) == nil)
            }
        }
    }

    private func readCard(pin: String) {
        readingCard = true
        error = nil
        Task {
            defer { readingCard = false }
            do {
                let key = try await model.readSatochipKey(pin: pin)
                satochipKey = key
                if descriptor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    descriptor = try model.muSig2Descriptor(withSatochip: key)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// The card's registration when the descriptor names its key.
    private var satochipRegistration: SatochipRegistration? {
        guard let satochipKey, let account = try? validation?.get() else { return nil }
        let registration = SatochipRegistration(satochipKey)
        return registration.belongs(to: account) ? registration : nil
    }

    private func save() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await model.addMuSig2Account(name: name, descriptor: descriptor, satochip: satochipRegistration)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Account

struct MuSig2AccountView: View {
    let recordID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirmRemove = false

    private var record: MuSig2AccountRecord? { model.muSig2Accounts.first { $0.id == recordID } }

    var body: some View {
        Form {
            if let record, let account = try? model.muSig2Account(for: record) {
                Section {
                    MuSig2ValueRow(title: "Balance", value: satsText(record.balance), identifier: "musig2Balance")
                    LabeledContent("Signers", value: "\(account.participants.count) of \(account.participants.count)")
                    if let card = record.satochip {
                        LabeledContent("Satochip", value: String(format: "%08x", card.masterFingerprint))
                            .accessibilityIdentifier("musig2AccountSatochip")
                    }
                }
                receiveSection(record, account)
                Section("Spend") {
                    NavigationLink(value: MuSig2Route.psbt(record.id)) { Text("New or pasted PSBT") }
                        .accessibilityIdentifier("musig2PSBTButton")
                }
                coinsSection(record)
                Section("Descriptor") {
                    CopyableTextBlock(text: record.descriptor)
                }
                Section {
                    Button("Remove account", role: .destructive) { confirmRemove = true }
                        .accessibilityIdentifier("musig2RemoveButton")
                }
            } else {
                Text("This MuSig2 account is no longer on this phone.")
                    .foregroundStyle(.secondary)
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(record?.name ?? "MuSig2")
        .confirmationDialog("Remove this account from this phone?", isPresented: $confirmRemove,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { remove() }
        } message: {
            Text("Only an empty account can be removed. The other signers keep theirs.")
        }
    }

    @ViewBuilder
    private func receiveSection(_ record: MuSig2AccountRecord, _ account: MuSig2Account) -> some View {
        Section {
            if let address = try? account.address(index: record.nextReceiveIndex) {
                QRCodeView(content: address)
                    .frame(maxWidth: 220)
                    .frame(maxWidth: .infinity)
                MuSig2LiteralRow(text: address, copyIdentifier: "musig2ReceiveAddressCopy")
            }
            Button("New address") {
                Task {
                    do { try await model.newMuSig2ReceiveAddress(id: record.id) } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .accessibilityIdentifier("musig2NewAddressButton")
        } header: {
            Text("Receive · index \(record.nextReceiveIndex)")
        } footer: {
            Text("The same address on every signer's device: check it there before sharing it.")
        }
    }

    @ViewBuilder
    private func coinsSection(_ record: MuSig2AccountRecord) -> some View {
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
                try await model.removeMuSig2Account(id: recordID)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - PSBT

/// One raw screen for a spend: create a PSBT or paste one, check it against
/// the account's own coins, then round 1 (nonce), round 2 (partial
/// signature), and broadcast. Round-1 secret nonces live only in this
/// screen's memory: leaving, backgrounding or a restart scrubs them, and the
/// exchange starts again on every device.
struct MuSig2PSBTView: View {
    let recordID: String
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var address = ""
    @State private var amountText = ""
    @State private var feeRateText = ""
    @State private var pasted = ""
    @State private var working: PSBT?
    @State private var review: MuSig2Account.SpendReview?
    @State private var reviewError: String?
    @State private var output: String?
    @State private var error: String?
    @State private var busy = false
    @State private var broadcastTxid: Data?
    /// Round-1 secret nonces per input (participant key → secret nonce).
    /// Never persisted, never shown, consumed by round 2.
    @State private var secretNonces: [Int: [Data: Data]] = [:]
    @State private var nonceSessionStarted = false
    @State private var signedThisSession = false
    @State private var operationEpoch = SensitivePresentationEpoch()
    @State private var operationTask: Task<Void, Never>?
    /// The card's round-1 nonces (public nonce and its encrypted secret
    /// nonce) for this exchange. The card accepts each once.
    @State private var cardNonces: [Int: Satochip.CardNonce] = [:]
    @State private var cardSigned = false
    @State private var approvals: Satochip.Approvals?
    @State private var approvalsError: String?
    @State private var cardAction: CardAction?

    /// What the next card tap does; the PIN sheet asks for it.
    enum CardAction: String, Identifiable {
        case nonce, sign
        var id: String { rawValue }
    }

    private var record: MuSig2AccountRecord? { model.muSig2Accounts.first { $0.id == recordID } }
    private var participantCount: Int? {
        record.flatMap { try? model.muSig2Account(for: $0) }?.participants.count
    }
    private var minNonces: Int { working?.inputs.map(\.musig2PubNonces.count).min() ?? 0 }
    private var minPartials: Int { working?.inputs.map(\.musig2PartialSigs.count).min() ?? 0 }

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
                        .accessibilityIdentifier("musig2PaymentSent")
                    CopyableIdentifier(value: broadcastTxid.displayHex, accessibilityID: "musig2TxidCopy")
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
                            .accessibilityIdentifier("musig2Error")
                    }
                }
                if let output {
                    Section("PSBT to share") {
                        CopyableTextBlock(text: output)
                    }
                }
            }
        }
        .navigationTitle("MuSig2 PSBT")
        .task {
            guard feeRateText.isEmpty else { return }
            let rate = await model.resolvedFeeRate(priority: .medium, override: nil)
            if feeRateText.isEmpty { feeRateText = String(format: "%.1f", rate) }
        }
        .task(id: trustedState) { refreshReview() }
        .sheet(item: $cardAction) { action in
            SatochipPINSheet(purpose: action == .nonce ? "Add the card's nonce" : "Sign with the card") { pin in
                switch action {
                case .nonce: attachCardNonces(pin: pin)
                case .sign: signWithCard(pin: pin)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { clearSensitiveState() }
        }
        .onDisappear { clearSensitiveState() }
    }

    private var createSection: some View {
        Section {
            TextField("Address", text: $address)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("musig2AddressField")
            TextField("Amount (sats)", text: $amountText)
                .keyboardType(.numberPad)
                .accessibilityIdentifier("musig2AmountField")
            TextField("Fee rate (sat/vB)", text: $feeRateText)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier("musig2FeeRateField")
            Button("Create PSBT") { create() }
                .accessibilityIdentifier("musig2CreateButton")
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
                MuSig2ValueRow(title: "Fee", value: satsText(review.fee), identifier: "musig2Fee")
                if let participantCount {
                    MuSig2ValueRow(title: "Nonces", value: "\(minNonces) of \(participantCount)",
                                   identifier: "musig2NonceCount")
                    MuSig2ValueRow(title: "Partial signatures", value: "\(minPartials) of \(participantCount)",
                                   identifier: "musig2PartialCount")
                }
            } else {
                Label("Winnow cannot safely review this PSBT", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(reviewError ?? "The account or PSBT is unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("musig2ReviewError")
            }
        } header: {
            Text("Check this payment")
        } footer: {
            Text("Check the addresses, amounts and fee on every signer's device before signing.")
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if let participantCount {
            Section {
                Button("Add nonce") { attachNonces() }
                    .accessibilityIdentifier("musigNonceButton")
                    .disabled(busy || review == nil || nonceSessionStarted
                        || minNonces >= participantCount || minPartials > 0)
                if record?.satochip != nil {
                    Button("Tap card for nonce") { cardAction = .nonce }
                        .accessibilityIdentifier("musig2CardNonceButton")
                        .disabled(busy || review == nil || !cardNonces.isEmpty
                            || minNonces >= participantCount || minPartials > 0)
                    Button(approvals == nil ? "Paste approvals" : "Approvals for \(approvals!.byInput.count) input(s)") {
                        pasteApprovals()
                    }
                    .accessibilityIdentifier("musig2ApprovalsPasteButton")
                    .disabled(busy || cardSigned)
                    if let approvalsError {
                        Text(approvalsError).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("musig2ApprovalsError")
                    }
                    Button("Tap card to sign") { cardAction = .sign }
                        .accessibilityIdentifier("musig2CardSignButton")
                        .disabled(busy || review == nil || cardNonces.isEmpty || cardSigned
                            || minNonces < participantCount)
                }
                Button("Add partial signature") { sign() }
                    .accessibilityIdentifier("musigSignButton")
                    .disabled(busy || review == nil || !nonceSessionStarted || signedThisSession
                        || secretNonces.isEmpty || minNonces < participantCount || minPartials >= participantCount)
                Button(busy ? "Working…" : "Finalize and broadcast") { broadcast() }
                    .accessibilityIdentifier("musigBroadcastButton")
                    .disabled(busy || review == nil || minPartials < participantCount)
                if minNonces > 0 {
                    Button("Start the exchange again") { restartExchange() }
                        .accessibilityIdentifier("musigRestartButton")
                        .disabled(busy)
                }
            } header: {
                Text("Signing")
            } footer: {
                Text(nextStep(required: participantCount))
                    .accessibilityIdentifier("musigNextStep")
            }
        }
    }

    private func nextStep(required: Int) -> String {
        if minPartials >= required { return "Every partial signature is here. Finalize and broadcast." }
        if record?.satochip != nil {
            if minNonces < required, cardNonces.isEmpty, nonceSessionStarted || minNonces == 0 {
                return nonceSessionStarted ? "Tap the card for its nonce. Keep this screen open."
                    : "Round 1: add this phone's nonce, then tap the card for its nonce."
            }
            if minNonces >= required, !cardSigned {
                return approvals == nil
                    ? "Copy the PSBT below to the checker, approve it there, then paste the approvals and tap the card to sign."
                    : "Tap the card to sign, then add this phone's partial signature."
            }
            if cardSigned, !signedThisSession { return "The card signed. Add this phone's partial signature." }
        }
        if signedThisSession { return "Share the PSBT below with the other signers, then combine their partial signatures here." }
        if nonceSessionStarted, minNonces >= required {
            return "Every nonce is here. Check the payment, then add this phone's partial signature. Keep this screen open."
        }
        if nonceSessionStarted {
            return "Share the PSBT below, then combine the other signers' nonces here. Keep this screen open: leaving it discards this phone's nonce."
        }
        if minNonces > 0 {
            return "This PSBT already has nonces, but this screen holds none of this phone's. Start the exchange again: every signer adds a fresh nonce."
        }
        return "Round 1: add this phone's nonce, then share the PSBT with the other signers."
    }

    // MARK: Actions

    private func create() {
        guard let record, let amount = Int64(amountText), let rate = Double(feeRateText) else { return }
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                install(try await model.createMuSig2Spend(record: record, address: address, amount: amount,
                                                          feeRateSatPerVByte: rate))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func addPasted() {
        error = nil
        do {
            let incoming = try PSBT(base64: pasted.trimmingCharacters(in: .whitespacesAndNewlines))
            let candidate = try working?.combined(with: [incoming]) ?? incoming
            guard let record else { throw AppModel.MuSig2ActionError.unknownAccount }
            _ = try model.reviewMuSig2Spend(candidate, record: record)
            install(candidate)
            pasted = ""
            model.journalPSBT(stage: "musig2-combined", psbt: candidate)
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
            return
        }
        do {
            review = try model.reviewMuSig2Spend(working, record: record)
            reviewError = nil
        } catch {
            review = nil
            reviewError = error.localizedDescription
        }
    }

    private func attachNonces() {
        guard let working, let record else { return }
        run { token in
            let result = try await model.attachMuSig2Nonces(working, record: record)
            guard accepts(token) else {
                var discarded = result.secretNonces
                AppModel.scrub(&discarded)
                return
            }
            secretNonces = result.secretNonces
            nonceSessionStarted = true
            install(result.psbt)
        }
    }

    private func sign() {
        guard let working, let record else { return }
        let nonces = secretNonces
        run { token in
            let signed = try await model.signMuSig2Spend(working, record: record, secretNonces: nonces)
            AppModel.scrub(&secretNonces)
            guard accepts(token) else { return }
            signedThisSession = true
            install(signed)
        }
    }

    private func attachCardNonces(pin: String) {
        guard let working, let record else { return }
        run { token in
            let result = try await model.attachSatochipNonces(working, record: record, pin: pin)
            guard accepts(token) else { return }
            cardNonces = result.nonces
            install(result.psbt)
        }
    }

    private func pasteApprovals() {
        approvalsError = nil
        do {
            let parsed = try Satochip.Approvals(text: model.pasteboardText() ?? "")
            if let working, parsed.txid != (try working.unsignedTransaction().txid.displayHex) {
                throw AppModel.MuSig2ActionError.approvalsForAnotherPayment
            }
            approvals = parsed
        } catch {
            approvals = nil
            approvalsError = error.localizedDescription
        }
    }

    private func signWithCard(pin: String) {
        guard let working, let record else { return }
        let nonces = cardNonces
        let approvals = approvals
        run { token in
            let signed = try await model.signWithSatochip(working, record: record, pin: pin, nonces: nonces,
                                                          approvals: approvals)
            guard accepts(token) else { return }
            cardSigned = true
            install(signed)
        }
    }

    private func broadcast() {
        guard let working, let record else { return }
        run { token in
            let txid = try await model.broadcastMuSig2Spend(working, record: record)
            AppModel.scrub(&secretNonces)
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

    /// Strips every nonce, partial signature and final signature, so all
    /// signers start round 1 again from the same unsigned spend.
    private func restartExchange() {
        guard var proposal = working else { return }
        for index in proposal.inputs.indices {
            proposal.inputs[index].pairs.removeAll {
                [PSBT.InType.musig2PubNonce, PSBT.InType.musig2PartialSig,
                 PSBT.InType.tapKeySignature, PSBT.InType.finalScriptWitness].contains($0.type)
            }
        }
        AppModel.scrub(&secretNonces)
        nonceSessionStarted = false
        signedThisSession = false
        clearCardState()
        install(proposal)
    }

    private func clearCardState() {
        cardNonces = [:]
        cardSigned = false
        approvals = nil
        approvalsError = nil
        cardAction = nil
    }

    private func clearSensitiveState() {
        operationEpoch.invalidate()
        operationTask?.cancel()
        operationTask = nil
        busy = false
        AppModel.scrub(&secretNonces)
        nonceSessionStarted = false
        signedThisSession = false
        clearCardState()
        working = nil
        output = nil
        pasted = ""
        review = nil
        reviewError = nil
    }
}


/// Asks for the card's PIN for one tap. The PIN goes to the card through its
/// secure channel and is not kept.
struct SatochipPINSheet: View {
    let purpose: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Card PIN", text: $pin)
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("satochipPINField")
                } footer: {
                    Text("After Continue, hold the Satochip near the top of the iPhone until it is done. Wrong PINs count against the card's limit.")
                }
            }
            .navigationTitle(purpose)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        let entered = pin
                        pin = ""
                        dismiss()
                        onSubmit(entered)
                    }
                    .accessibilityIdentifier("satochipPINContinue")
                    .disabled(!(4 ... 16).contains(pin.utf8.count))
                }
            }
        }
        .presentationDetents([.medium])
    }
}
