import Foundation
import LightningCore
import SwiftUI
import WalletCore

struct LightningView: View {
    @Environment(AppModel.self) private var model
    let controller: LightningAppController
    @State private var setup = false
    @State private var send = false
    @State private var sendInvoice = false
    @State private var sendOffer = false
    @State private var receive = false
    @State private var capacity = ""
    @State private var backup = false
    @State private var bump = false
    @State private var bumpChannelID: Data?
    @FocusState private var editingCapacity: Bool
    @State private var review: LightningReview?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(controller.networkNotice).font(.headline)
                    Text("Experimental Lightning. Background checks can relay pre-signed channel recovery transactions, but this beta has no external watchtower.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Each network has its own wallet and channels. Save an encrypted Lightning recovery file and its separate recovery phrase before relying on this device alone.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Connection", value: controller.connection)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Connection").accessibilityValue(controller.connection)
                        .accessibilityIdentifier("lightningConnection")
                    if let error = controller.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("lightningError") }
                    if let warning = controller.peerWarning { Text(warning).foregroundStyle(.secondary) }
                    Button("Sync and reconnect") { run { await model.syncNow() } }.accessibilityIdentifier("lightningSync")
                }
                Section("Chain checks") { BackgroundSyncStatusView() }
                providerSection
                channelSection
                receiveSection
                Section("Payments") {
                    Button("Pay Lightning invoice") { sendInvoice = true }.accessibilityIdentifier("lightningSendInvoice")
                    Button("Pay reusable offer or ₿name") { sendOffer = true }.accessibilityIdentifier("lightningSendOrdinaryOffer")
                    Button("Pay an async receive offer") { send = true }.accessibilityIdentifier("lightningSend")
                        .disabled(!controller.channels.contains(where: { $0.phase == .ready }))
                    ForEach(controller.payments.reversed(), id: \.id) { payment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(payment.incoming ? "Received" : "Sent") \(payment.amountMsat / 1000) sats")
                            Text(payment.phase.displayName).foregroundStyle(payment.phase == .settled ? .green : .secondary)
                                .accessibilityIdentifier("lightningPaymentPhase.\(payment.id.hex)")
                            if let fee = payment.feeMsat { Text("Fee: \(fee) msat").font(.caption) }
                            Text(payment.hash.hex).font(.caption.monospaced()).textSelection(.enabled)
                                .accessibilityLabel("Payment hash").accessibilityValue(payment.hash.hex)
                                .accessibilityIdentifier("lightningPaymentHash.\(payment.hash.hex)")
                        }
                    }
                }
            }
            .navigationTitle("Lightning")
            .toolbar {
                if editingCapacity {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") { editingCapacity = false }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("lightningCapacityHideKeyboard")
                    }
                }
            }
            .disabled(busy)
            .sheet(isPresented: $setup) { LightningSetupView(controller: controller) }
            .sheet(isPresented: $sendInvoice) { LightningInvoiceSendView(controller: controller) }
            .sheet(isPresented: $sendOffer) { LightningOfferSendView(controller: controller) }
            .sheet(isPresented: $send) { LightningSendView(controller: controller) }
            .sheet(isPresented: $receive) { LightningReceiveView(controller: controller) }
            .sheet(isPresented: $backup) { LightningBackupView() }
            .sheet(isPresented: $bump) {
                if let channel = controller.channels.first(where: { $0.id == bumpChannelID }) {
                    LightningFeeBumpView(controller: controller, channel: channel)
                }
            }
            .sheet(item: $review) { LightningReviewView(controller: controller, review: $0) }
            .task {
                while !Task.isCancelled {
                    do { try await controller.refresh(); try await Task.sleep(for: .seconds(1)) }
                    catch is CancellationError { return }
                    catch { controller.error = error.localizedDescription; return }
                }
            }
        }
    }
    private var providerSection: some View {
        Section("Provider") {
            Text(controller.profile?.name ?? "No provider configured")
            if let profile = controller.profile { Text(profile.endpoint).font(.caption.monospaced()) }
            Button("Configure provider") { setup = true }.accessibilityIdentifier("lightningSetup")
            LabeledContent("Your node ID") {
                Text(controller.nodeID).font(.caption.monospaced()).textSelection(.enabled)
                    .accessibilityLabel("Your node ID").accessibilityValue(controller.nodeID)
                    .accessibilityIdentifier("lightningNodeID")
            }
            Button("Copy node ID") { UIPasteboard.general.string = controller.nodeID }.disabled(controller.nodeID.isEmpty)
        }
    }
    private var channelSection: some View {
        Section("Channels") {
            Button("Lightning recovery file") { backup = true }.accessibilityIdentifier("lightningBackup")
            if controller.recoveryStatus != nil {
                Text("Recovery mode: reconnect to original counterparties and sync for returned funds. Payments and old commitment broadcasts are disabled.")
                    .accessibilityIdentifier("lightningRecoveryOnly")
            }
            if controller.channels.allSatisfy({ $0.phase == .closed }) {
                Text("This funds a channel with your Bitcoin for spending. To set up receiving capacity, use Receive Lightning.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("Capacity in sats", text: $capacity).keyboardType(.numberPad).accessibilityIdentifier("lightningCapacity")
                    .focused($editingCapacity)
                Button("Request a channel") { editingCapacity = false; run {
                    guard let amount = UInt64(capacity) else { throw LightningError.invalidAmount }
                    try await controller.openChannel(capacitySat: amount, model: model)
                } }.disabled(controller.profile == nil || capacity.isEmpty).accessibilityIdentifier("lightningOpen")
            }
            ForEach(controller.channels, id: \.id) { channel in
                VStack(alignment: .leading) {
                    Text(channel.signedCommitment == nil && !channel.needsMonitoring
                         ? "\(channel.capacitySat) sats requested · \(channel.phase.rawValue)"
                         : "\(channel.capacitySat) sats · \(channel.phase.rawValue)")
                        .accessibilityIdentifier("lightningChannelPhase")
                    if let balance = controller.balances.first(where: { $0.id == channel.id }) {
                        Text("Local balance: \(balance.localMsat / 1000) sats").font(.caption)
                    } else if [.opening, .accepted].contains(channel.phase) {
                        Text("Requested capacity · funding not completed").font(.caption).foregroundStyle(.secondary)
                    }
                    if [.ready, .closing].contains(channel.phase) {
                        Button("Review channel close") { run {
                            review = try await .close(controller.reviewClose(channel, force: false, model: model))
                        } }
                            .buttonStyle(.borderless).accessibilityIdentifier("lightningClose")
                        Button("Review force close", role: .destructive) { run {
                            review = try await .close(controller.reviewClose(channel, force: true, model: model))
                        } }
                            .buttonStyle(.borderless).accessibilityIdentifier("lightningForceClose")
                    }
                    if channel.format.hasAnchors && controller.recoveryStatus == nil && channel.needsMonitoring {
                        Button("Review recovery fee bump") { bumpChannelID = channel.id; bump = true }
                            .buttonStyle(.borderless).accessibilityIdentifier("lightningFeeBump")
                    }
                }
            }
            ForEach(controller.funding, id: \.temporaryID) { request in
                Button("Review funding \(request.amountSat) sats") { run {
                    review = try await .funding(controller.reviewFunding(request, model: model))
                } }.accessibilityIdentifier("lightningFundingReview")
            }
        }
    }
    private var receiveSection: some View {
        Section("Receive") {
            Button("Receive Lightning") { receive = true }.accessibilityIdentifier("lightningReceive")
            Button("Create reusable offer") { run { try await controller.registerOrdinaryOffer(model: model) } }
                .disabled(controller.maximumReceivableSat == 0).accessibilityIdentifier("lightningCreateOrdinaryOffer")
            ForEach(controller.ordinaryOffers, id: \.bytes) { offer in
                Text(offer.string).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
                    .accessibilityIdentifier("lightningOrdinaryReceiveOffer").accessibilityValue(offer.string)
                ShareLink("Share reusable offer", item: offer.string)
                Button("Copy reusable offer") { ClipboardPolicy.interchange.apply(offer.string) }
            }
            Button("Create async receive offer") { run { try await controller.registerOffer(model: model) } }
                .disabled(controller.profile?.receive == nil).accessibilityIdentifier("lightningCreateOffer")
            ForEach(controller.offers, id: \.id) { offer in
                Text("Reusable until \(Date(timeIntervalSince1970: TimeInterval(offer.expiresAt)).formatted())").font(.caption)
                Text(offer.offer.string).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
                    .accessibilityLabel("Receive offer").accessibilityValue(offer.offer.string)
                    .accessibilityIdentifier("lightningReceiveOffer")
                ShareLink("Share receive offer", item: offer.offer.string).accessibilityIdentifier("lightningShareOffer")
                Button("Copy receive offer") { UIPasteboard.general.string = offer.offer.string }.accessibilityIdentifier("lightningCopyOffer")
            }
            Text("Share your reusable receive offer in your favorite messenger. The recipient must return before the payment expires.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action(); controller.error = nil }
            catch { controller.error = error.localizedDescription }
        }
    }
}

extension LightningEngine.PaymentPhase {
    var displayName: String {
        switch self {
        case .preparing: "Preparing"
        case .inFlight: "Committing payment"
        case .awaitingRecipient: "Awaiting recipient"
        case .recovering: "Recovering on chain"
        case .settled: "Settled"
        case .failed: "Failed"
        }
    }
}
