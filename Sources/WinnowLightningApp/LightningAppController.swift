import CryptoKit
import Foundation
import LightningCore
import Observation
import WalletCore

@Observable @MainActor
final class LightningAppController {
    let network: BitcoinNetwork
    var networkNotice: String { network == .mainnet ? "Mainnet · real bitcoin" : "\(network.rawValue.capitalized) · test coins have no value" }
    private(set) var profile: LightningProfile?
    private(set) var nodeID = ""
    private(set) var channels: [LightningEngine.Channel] = []
    private(set) var balances: [LightningEngine.ChannelBalance] = []
    private(set) var payments: [LightningEngine.Payment] = []
    private(set) var funding: [LightningEngine.FundingRequest] = []
    private(set) var offers: [LightningEngine.ReceiveOffer] = []
    private(set) var ordinaryOffers: [LightningOffer] = []
    private(set) var ordinaryRequests: [LightningEngine.OrdinaryInvoiceStatus] = []
    var invoiceCapacities: [LightningEngine.InvoiceCapacity] = []
    var liquidityQuote: LiquidityQuote?
    var liquidityInfo: LightningLiquidity.Info?
    var liquidityRequestInFlight = false
    var receiveIntent: LightningReceiveIntent?
    var jitMenu: LightningJIT.Menu?
    var liquiditySession: LightningPeerSession? { session }
    private(set) var connection = "Waiting for verified chain"
    private(set) var peerWarning: String?
    private(set) var chainCurrent = false
    var error: String?
    private(set) var engine: LightningEngine?
    private(set) var driver: LightningChainDriver?
    @ObservationIgnored private var session: LightningPeerSession?
    @ObservationIgnored private let keys: any StoreKeyVault
    @ObservationIgnored private let backgroundKeys: any StoreKeyVault
    @ObservationIgnored private var backgroundStore: LightningBackgroundStore?
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var recoveryID: UUID?
    @ObservationIgnored private var cachedRecoveryBackup: LightningRecoveryBackup?
    @ObservationIgnored private var restoringRecovery = false
    private(set) var recoveryStatus: LightningEngine.RecoveryStatus?
    @ObservationIgnored private var connecting = false
    @ObservationIgnored var monitoringChanged: ((Bool) -> Void)?
    @ObservationIgnored var recoveryRelayFailed: (() -> Void)?
    @ObservationIgnored private(set) var generation: UInt64 = 0
    #if DEBUG
    @ObservationIgnored var fixtureNodeSecret: Data?
    #endif
    static let recoveryFeeSat: UInt64 = 500
    static var now: UInt64 { UInt64(Date().timeIntervalSince1970) }

    init(network: BitcoinNetwork, keys: any StoreKeyVault, backgroundKeys: (any StoreKeyVault)? = nil) {
        self.network = network; self.keys = keys; self.backgroundKeys = backgroundKeys ?? keys
    }

    private func openBackgroundStore(root: URL, create: Bool) throws -> LightningBackgroundStore {
        if let backgroundStore { return backgroundStore }
        let dir = root.appending(path: "lightning-background", directoryHint: .isDirectory)
        let account = "lightning-background-v1.\(network.rawValue)" + (recoveryID.map { ".\($0.uuidString)" } ?? "")
        let existing = try backgroundKeys.key(for: account)
        let hasJournal = FileManager.default.fileExists(atPath: dir.appending(path: "journal.v1").path)
        let interruptedRecovery = create && recoveryID != nil && existing != nil && !hasJournal
        guard (existing != nil) == hasJournal || interruptedRecovery, create || hasJournal else { throw LightningError.storageFailed }
        let key = try existing ?? backgroundKeys.establishKey(for: account)
        let store = try LightningBackgroundStore(directory: dir, key: key.withUnsafeBytes { Data($0) })
        backgroundStore = store
        return store
    }

    func prepareBackground(directory: URL) throws -> LightningBackgroundMonitor {
        guard !restoringRecovery else { throw CancellationError() }
        let selected = try selectedStorage(root: directory)
        return try LightningBackgroundMonitor(store: openBackgroundStore(root: selected, create: false),
                                       chain: NetworkParams.params(for: network).genesisHash)
    }

    func requireNetwork(_ model: AppModel, generation expected: UInt64? = nil) throws {
        guard model.network == network, !model.changingNetwork,
              expected == nil || expected == generation else { throw CancellationError() }
    }

    func prepare(directory root: URL, headers: HeaderChain) async throws {
        guard !restoringRecovery else { throw CancellationError() }
        try await prepareStorage(directory: root, headers: headers, epoch: generation)
    }
    private func checkPreparation(_ epoch: UInt64, recovery: Bool) throws {
        try Task.checkCancellation()
        guard generation == epoch, !restoringRecovery || recovery else { throw CancellationError() }
    }
    private func prepareStorage(directory root: URL, headers: HeaderChain, epoch: UInt64, recovery: Bool = false) async throws {
        guard await headers.params.genesisHash == NetworkParams.params(for: network).genesisHash else { throw LightningError.invalidHash }
        try checkPreparation(epoch, recovery: recovery)
        if engine == nil {
            let selected = try selectedStorage(root: root)
            let dir = selected.appending(path: "lightning", directoryHint: .isDirectory)
            let account = journalAccount()
            let existing = try keys.key(for: account)
            let hasJournal = FileManager.default.fileExists(atPath: dir.appending(path: "journal.v1").path)
            guard (existing != nil) == hasJournal else { throw LightningError.storageFailed }
            let key = try existing ?? keys.establishKey(for: account)
            let journal = try FileLightningJournal(directory: dir, key: key.withUnsafeBytes { Data($0) })
            #if DEBUG
            let nodeSecret = fixtureNodeSecret
            #else
            let nodeSecret: Data? = nil
            #endif
            let opened = try LightningEngine(chain: NetworkParams.params(for: network).genesisHash, nodeSecret: nodeSecret,
                journal: journal, backgroundStore: openBackgroundStore(root: selected, create: true))
            directory = dir
            let savedProfile = try loadProfile()
            let recommended = await recommendedProfile(for: opened)
            try checkPreparation(epoch, recovery: recovery)
            let loaded = savedProfile ?? recommended
            engine = opened; profile = loaded
            liquidityQuote = try loadLiquidityQuote()
            receiveIntent = try loadReceiveIntent()
        }
        guard let engine else { throw LightningError.storageFailed }
        try await engine.resumeFromBackground()
        try checkPreparation(epoch, recovery: recovery)
        try await engine.persistIdentity()
        try checkPreparation(epoch, recovery: recovery)
        try await engine.prepareInvoiceRouting()
        try checkPreparation(epoch, recovery: recovery)
        driver = LightningChainDriver(engine: engine, headers: headers)
        try await refresh()
        try checkPreparation(epoch, recovery: recovery)
    }
    private func loadProfile() throws -> LightningProfile? {
        guard let file = directory?.appending(path: "profile.json"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        let sealed = try StoreSeal(store: "lightning-profile", keys: keys).read(Data(contentsOf: file), network: network)
        guard !sealed.predatesSealing else { throw LightningError.storageFailed }
        return try LightningProfile.parse(String(decoding: sealed.payload, as: UTF8.self), network: network)
    }
    func saveProfile(_ proposed: LightningProfile, model: AppModel) async throws {
        try requireNetwork(model)
        try proposed.validate(network: network)
        guard let directory, let engine else { throw AppModel.AppError.noStack }
        try await requireProfileChangeAllowed(proposed, engine: engine)
        let epoch = generation
        try await model.authenticateSensitiveAction(reason: "Approve this \(network.rawValue) Lightning provider and recovery policy")
        defer { model.keychainAuthentication.revoke() }
        try Task.checkCancellation()
        try requireNetwork(model, generation: epoch)
        let sameEndpoint = profile?.peer == proposed.peer && profile?.host == proposed.host && profile?.port == proposed.port
        // Drop only an unapproved stale quote before changing its binding.
        // A crash between these writes retains the old valid provider.
        if profile != proposed { try storeLiquidityQuote(nil); liquidityQuote = nil; liquidityInfo = nil }
        try StoreSeal(store: "lightning-profile", keys: keys).write(JSONEncoder().encode(proposed), network: network,
            to: directory.appending(path: "profile.json")) { data, file in
                try data.write(to: file, options: [.atomic, .completeFileProtection])
            }
        // Receiving-path or fee updates do not change the authenticated TCP
        // peer. Keep that session while the new profile becomes durable.
        if !sameEndpoint { await stop() }
        profile = proposed
        try requireNetwork(model)
        await model.syncNow()
        await resume(model: model)
    }
    /// A recovering wallet keeps its channels' peers; an approved setup order
    /// or an open channel keeps its provider.
    private func requireProfileChangeAllowed(_ proposed: LightningProfile, engine: LightningEngine) async throws {
        if recoveryStatus != nil {
            guard channels.contains(where: { $0.peer == proposed.peerKey }) else { throw LightningError.invalidState }
        }
        guard liquidityQuote?.accepted != true || proposed == profile else { throw LightningError.invalidState }
        if let current = profile, current.peerKey != proposed.peerKey, recoveryStatus == nil {
            guard await engine.channels().allSatisfy({ $0.phase == .closed }),
                  liquidityQuote?.accepted != true else { throw LightningError.invalidState }
        }
    }
    func stop() async {
        generation &+= 1
        let previous = session; session = nil
        await engine?.chainDisconnected(); await previous?.stop()
        chainCurrent = false; connection = "Paused"
    }
    func resume(model: AppModel) async {
        guard !restoringRecovery else { return }
        do {
            let epoch = generation
            try requireNetwork(model)
            try await refresh()
            try requireNetwork(model, generation: epoch)
            model.e2e?.journal("lightning.resume", fields: ["connection": connection, "connecting": String(connecting), "chainCurrent": String(chainCurrent)])
            guard chainCurrent else { return }
            try await resumeApprovedFeeBumps(model: model)
            guard let engine, let profile, !connecting else { return }
            if await session?.status == .connected {
                try await resumeSubmittedFunding(model: model)
                try await session?.flush()
                return
            }
            connecting = true; defer { connecting = false }
            let next = LightningPeerSession(engine: engine, peer: profile.peerKey, host: profile.host, port: profile.port,
                                            features: profile.supportsJIT ? .jitClient : .asyncClient) { [weak self, weak model] events in
                guard let self, let model else { throw CancellationError() }
                try await self.requireNetwork(model, generation: epoch)
                try await self.handle(events, model: model)
            }
            session = next
            try await next.start()
            guard epoch == generation else { await next.stop(); return }
            try await configureRecovery(model: model)
            try await resumeSubmittedFunding(model: model)
            try await refresh()
            error = nil
        } catch {
            self.error = error.localizedDescription; try? await refresh()
            model.e2e?.journal("lightning.connectionFailed", fields: ["error": String(describing: error)])
        }
    }
    func refresh() async throws {
        guard let engine else { return }
        let epoch = generation, selectedProfile = profile, selectedSession = session
        let nextID = try await engine.nodeID().hex
        let nextRecovery = await engine.recoveryStatus()
        let nextChannels = await engine.channels(), nextPayments = await engine.payments()
        let nextBalances = try await engine.channelBalances(), nextFunding = try await engine.fundingRequests()
        let nextOffers = try await offerSnapshot(engine, recovery: nextRecovery, profile: selectedProfile)
        let current = await engine.isChainCurrent()
        let status = await selectedSession?.status, warning = await selectedSession?.lastPeerWarning
        try checkRecoveryRestore(epoch)
        nodeID = nextID; recoveryStatus = nextRecovery; channels = nextChannels; payments = nextPayments
        balances = nextBalances; funding = nextFunding
        offers = nextOffers.async; ordinaryOffers = nextOffers.ordinary; ordinaryRequests = nextOffers.requests
        invoiceCapacities = nextOffers.capacities; chainCurrent = current
        connection = connectionDescription(status, current: current); peerWarning = warning
        monitoringChanged?(nextChannels.contains(where: \.needsMonitoring))
    }
    private struct OfferSnapshot {
        var async: [LightningEngine.ReceiveOffer] = []
        var ordinary: [LightningOffer] = []
        var requests: [LightningEngine.OrdinaryInvoiceStatus] = []
        var capacities: [LightningEngine.InvoiceCapacity] = []
    }
    private func offerSnapshot(_ engine: LightningEngine, recovery: LightningEngine.RecoveryStatus?, profile: LightningProfile?) async throws -> OfferSnapshot {
        guard recovery == nil else { return OfferSnapshot() }
        let offers = try await engine.receiveOffers(now: Self.now)
        let ordinary = try await engine.ordinaryReceiveOffers(now: Self.now)
        let requests = try await engine.ordinaryInvoiceRequests(now: Self.now)
        var capacities: [LightningEngine.InvoiceCapacity] = []
        if let profile { capacities = try await engine.invoiceCapacities(peer: profile.peerKey) }
        return OfferSnapshot(async: offers, ordinary: ordinary, requests: requests, capacities: capacities)
    }
    private func connectionDescription(_ status: LightningPeerSession.Status?, current: Bool) -> String {
        switch status {
        case .connected: current ? "Connected" : "Verifying chain"
        case .connecting: "Connecting"
        case .failed(let reason): "Disconnected: \(reason)"
        default: current ? "Ready to connect" : "Waiting for verified chain"
        }
    }
    func handle(_ events: [LightningEngine.Event], model: AppModel) async throws {
        try requireNetwork(model)
        let epoch = generation
        guard let stack = model.stack, let wallet = model.wallet else { throw AppModel.AppError.noStack }
        for event in events {
            try requireNetwork(model, generation: epoch)
            try await handleFundingEvent(event, wallet: wallet, broadcaster: stack.broadcaster, model: model, epoch: epoch)
            if case .channelReady = event { try await configureRecovery(model: model) }
        }
        try await handleRecoveryEvents(events.filter(isRecoveryEvent), wallet: wallet, broadcaster: stack.broadcaster, model: model, epoch: epoch)
        try await refresh()
    }
    private func handleFundingEvent(_ event: LightningEngine.Event, wallet: Wallet, broadcaster: TxBroadcaster, model: AppModel, epoch: UInt64) async throws {
        guard case .broadcastFunding(_, let raw) = event else { return }
        guard let reservation = await wallet.fundingReservations.first(where: { $0.rawTransaction == raw }) else { throw LightningError.storageFailed }
        try requireNetwork(model, generation: epoch)
        _ = try await broadcaster.broadcast(raw, feeRateSatPerVByte: reservation.feeRateSatPerVByte)
        try await wallet.commitFundingBroadcast(requestID: reservation.requestID, rawTransaction: raw)
    }
    private func isRecoveryEvent(_ event: LightningEngine.Event) -> Bool {
        switch event {
        case .broadcastClose, .broadcastRecovery: true
        default: false
        }
    }
    private func handleRecoveryEvents(_ events: [LightningEngine.Event], wallet: Wallet, broadcaster: TxBroadcaster, model: AppModel, epoch: UInt64) async throws {
        guard !events.isEmpty else { return }
        try requireNetwork(model, generation: epoch)
        do { try await relayBackgroundRecovery(events, broadcaster: broadcaster) }
        catch { recoveryRelayFailed?(); throw error }
        try requireNetwork(model, generation: epoch)
        for event in events { try await acknowledgeFeeBump(event, wallet: wallet) }
    }
    private func configureRecovery(model: AppModel) async throws {
        try requireNetwork(model)
        let epoch = generation
        guard profile != nil, let engine, let wallet = model.wallet else { return }
        let needingRecovery = Set(try await engine.channelsNeedingRecoveryConfiguration())
        for channel in await engine.channels() where needingRecovery.contains(channel.id) {
            let destination = try await recoveryDestination(wallet: wallet)
            try requireNetwork(model, generation: epoch)
            try await engine.configureRecovery(channelID: channel.id, peer: channel.peer, destination: destination, feeSat: Self.recoveryFeeSat)
        }
    }
    /// Unilateral recovery pays to a fresh address of this wallet.
    func recoveryDestination(wallet: Wallet) async throws -> Data {
        try AddressDecoder.scriptPubKey(for: await wallet.freshReceiveAddress(), network: network)
    }
    func loadLiquidityQuote() throws -> LiquidityQuote? {
        guard let quote = try storedLiquidityQuote() else { return nil }
        guard quote.profile == profile else { throw LightningError.storageFailed }
        return quote
    }
    private func storedLiquidityQuote() throws -> LiquidityQuote? {
        guard let file = directory?.appending(path: "liquidity.json"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        let sealed = try StoreSeal(store: "lightning-liquidity", keys: keys).read(Data(contentsOf: file), network: network)
        guard !sealed.predatesSealing else { throw LightningError.storageFailed }
        return try JSONDecoder().decode(LiquidityQuote.self, from: sealed.payload)
    }
    func storeLiquidityQuote(_ quote: LiquidityQuote?) throws {
        guard let file = directory?.appending(path: "liquidity.json") else { throw LightningError.storageFailed }
        if let quote {
            try StoreSeal(store: "lightning-liquidity", keys: keys).write(JSONEncoder().encode(quote), network: network, to: file) { data, path in
                try data.write(to: path, options: [.atomic, .completeFileProtection])
            }
        } else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    func setReceiveAmount(_ amountSat: UInt64, model: AppModel) throws {
        try requireNetwork(model)
        let intent = try LightningReceiveIntent(amountSat: amountSat, network: network)
        guard let file = directory?.appending(path: "receive-intent.json") else { throw LightningError.storageFailed }
        try StoreSeal(store: "lightning-receive-intent", keys: keys).write(JSONEncoder().encode(intent), network: network, to: file) { data, path in
            try data.write(to: path, options: [.atomic, .completeFileProtection])
        }
        receiveIntent = intent
    }

    private func loadReceiveIntent() throws -> LightningReceiveIntent? {
        guard let file = directory?.appending(path: "receive-intent.json"), FileManager.default.fileExists(atPath: file.path) else { return nil }
        let sealed = try StoreSeal(store: "lightning-receive-intent", keys: keys).read(Data(contentsOf: file), network: network)
        guard !sealed.predatesSealing else { throw LightningError.storageFailed }
        let intent = try JSONDecoder().decode(LightningReceiveIntent.self, from: sealed.payload)
        try intent.validate(network: network)
        return intent
    }

    private struct RecoverySelection: Codable {
        let id: UUID
        let network: String
        var walletDescriptor: String?
    }
    private func journalAccount() -> String {
        if let recoveryID { return "lightning-recovery-v1.\(network.rawValue).\(recoveryID.uuidString)" }
        return network == .regtest ? "lightning-journal-v2" : "lightning-journal-v2.\(network.rawValue)"
    }
    private func selectedStorage(root: URL) throws -> URL {
        guard let selection = try loadRecoverySelection(root: root) else { recoveryID = nil; return root }
        recoveryID = selection.id
        return recoveryStorage(root: root, id: selection.id)
    }
    private func loadRecoverySelection(root: URL) throws -> RecoverySelection? {
        let file = root.appending(path: "lightning-recovery-selection.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let sealed = try StoreSeal(store: "lightning-recovery-selection", keys: backgroundKeys).read(Data(contentsOf: file), network: network)
        guard !sealed.predatesSealing else { throw LightningError.storageFailed }
        let selection = try JSONDecoder().decode(RecoverySelection.self, from: sealed.payload)
        guard selection.network == network.rawValue else { throw LightningError.invalidHash }
        return selection
    }
    /// A channel journal or recovery namespace on disk, whether or not this
    /// session opened it.
    func hasStoredChannels(root: URL) -> Bool {
        ["lightning/journal.v1", "lightning-recovery"].contains {
            FileManager.default.fileExists(atPath: root.appending(path: $0).path)
        }
    }
    func requireRecoveryWalletMatch(root: URL, importing descriptor: String?) throws {
        guard let selection = try loadRecoverySelection(root: root) else { return }
        guard let descriptor, descriptor == selection.walletDescriptor else {
            throw WalletError.invalidBundle("Finish restoring the matching encrypted Lightning recovery file before creating or importing another wallet.")
        }
    }
    private func recoveryStorage(root: URL, id: UUID) -> URL {
        root.appending(path: "lightning-recovery", directoryHint: .isDirectory).appending(path: id.uuidString, directoryHint: .isDirectory)
    }
    /// Without a saved choice, a wallet keeps the provider it already uses: a
    /// channel's peer, then a stored setup order's provider. Only a wallet with
    /// neither gets the current default, so a new default never moves anyone.
    private func recommendedProfile(for engine: LightningEngine) async -> LightningProfile? {
        let channels = await engine.channels()
        let peers = (recoveryID == nil ? channels.filter { $0.phase != .closed } : channels).map(\.peer)
        if let match = LightningProviders.available(network: network).first(where: { peers.contains($0.profile.peerKey) }) {
            return match.profile
        }
        guard recoveryID == nil else { return nil }
        return (try? storedLiquidityQuote())?.profile ?? LightningProviders.recommended(network: network)
    }

    func loadFeeBumpAuthorizations() throws -> [FeeBumpReview] {
        guard let file = directory?.appending(path: "approved-fee-bumps.json"), FileManager.default.fileExists(atPath: file.path) else { return [] }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 4 * 1024 * 1024 else { throw LightningError.storageFailed }
        return try decodeFeeBumpAuthorizations(Data(contentsOf: file))
    }
    private func decodeFeeBumpAuthorizations(_ bytes: Data) throws -> [FeeBumpReview] {
        let sealed = try StoreSeal(store: "lightning-approved-fees", keys: keys).read(bytes, network: network)
        guard !sealed.predatesSealing else { throw LightningError.storageFailed }
        let values = try JSONDecoder().decode([FeeBumpReview].self, from: sealed.payload)
        guard values.count <= 32 else { throw LightningError.storageFailed }
        return values
    }
    func storeFeeBumpAuthorization(_ review: FeeBumpReview) throws {
        var existing = try loadFeeBumpAuthorizations()
        existing.removeAll { $0.requestID == review.requestID }
        existing.append(review)
        try writeFeeBumpAuthorizations(existing)
    }
    func removeFeeBumpAuthorization(_ id: String, quoteID: Data) throws {
        let remaining = try loadFeeBumpAuthorizations().filter { $0.requestID != id || $0.quote.id != quoteID }
        try writeFeeBumpAuthorizations(remaining)
    }
    private func writeFeeBumpAuthorizations(_ reviews: [FeeBumpReview]) throws {
        guard reviews.count <= 32, let file = directory?.appending(path: "approved-fee-bumps.json") else { throw LightningError.storageFailed }
        let bytes = try JSONEncoder().encode(reviews)
        guard bytes.count <= 4 * 1024 * 1024 else { throw LightningError.storageFailed }
        try StoreSeal(store: "lightning-approved-fees", keys: keys).write(bytes, network: network, to: file) { data, file in
            try data.write(to: file, options: [.atomic, .completeFileProtection])
        }
    }
    func recoveryPayload() async throws -> LightningRecoveryBackup? {
        guard let engine else { return nil }
        let revision = await engine.currentRevision()
        if cachedRecoveryBackup?.revision != revision { cachedRecoveryBackup = try await engine.recoveryBackup() }
        return cachedRecoveryBackup
    }
    /// This opens a new encrypted namespace, commits recovery-only state, and
    /// then selects it. A interrupted import can never activate the old journal.
    func restoreRecovery(_ backup: LightningRecoveryBackup, root: URL, headers: HeaderChain, walletDescriptor: String? = nil) async throws {
        guard !restoringRecovery else { throw LightningError.invalidState }
        restoringRecovery = true
        defer { restoringRecovery = false }
        // Stop the session as well as invalidating suspended preparations.
        await stop()
        let epoch = generation
        _ = try LightningRecoveryBackup.decode(backup.encoded(), chain: NetworkParams.params(for: network).genesisHash)
        guard await headers.params.genesisHash == backup.chain else { throw LightningError.invalidHash }
        try checkRecoveryRestore(epoch)
        try await prepareRecoverySource(root: root, headers: headers)
        try checkRecoveryRestore(epoch)
        if await engine?.recoveryStatus()?.backupID == backup.id { return }
        let currentChannels = await engine?.channels() ?? []
        try checkRecoveryRestore(epoch)
        guard currentChannels.allSatisfy({ !$0.needsMonitoring }) else { throw LightningError.invalidState }
        let restoringEpoch = generation &+ 1
        await stop()
        try checkRecoveryRestore(restoringEpoch)
        try await installRecoveryNamespace(backup, root: root, headers: headers, walletDescriptor: walletDescriptor, epoch: restoringEpoch)
    }
    private func prepareRecoverySource(root: URL, headers: HeaderChain) async throws {
        let hasOriginal = FileManager.default.fileExists(atPath: root.appending(path: "lightning/journal.v1").path)
        let hasSelection = FileManager.default.fileExists(atPath: root.appending(path: "lightning-recovery-selection.json").path)
        if engine == nil, hasOriginal || hasSelection {
            try await prepareStorage(directory: root, headers: headers, epoch: generation, recovery: true)
        }
    }
    private func checkRecoveryRestore(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
    }
    private func clearRecoveryCache() {
        driver = nil; engine = nil; backgroundStore = nil; cachedRecoveryBackup = nil; recoveryID = nil; directory = nil
    }
    private func installRecoveryNamespace(_ backup: LightningRecoveryBackup, root: URL, headers: HeaderChain, walletDescriptor: String?, epoch: UInt64) async throws {
        clearRecoveryCache()
        var selected = false
        do {
            try await commitRecoverySelection(backup, root: root, headers: headers, walletDescriptor: walletDescriptor, epoch: epoch)
            selected = true
            try await refresh()
            try checkRecoveryRestore(epoch)
        } catch {
            if !selected { clearRecoveryCache() }
            throw error
        }
    }
    private func commitRecoverySelection(_ backup: LightningRecoveryBackup, root: URL, headers: HeaderChain, walletDescriptor: String?, epoch: UInt64) async throws {
        try checkRecoveryRestore(epoch)
        recoveryID = backup.id
        let selected = recoveryStorage(root: root, id: backup.id), dir = selected.appending(path: "lightning", directoryHint: .isDirectory)
        let account = journalAccount()
        let key = try keys.key(for: account) ?? keys.establishKey(for: account)
        let journal = try FileLightningJournal(directory: dir, key: key.withUnsafeBytes { Data($0) })
        let restored = try await restoredEngine(backup, journal: journal, root: selected)
        let recommended = await recommendedProfile(for: restored)
        try checkRecoveryRestore(epoch)
        let selection = RecoverySelection(id: backup.id, network: network.rawValue, walletDescriptor: walletDescriptor)
        try StoreSeal(store: "lightning-recovery-selection", keys: backgroundKeys).write(JSONEncoder().encode(selection), network: network,
            to: root.appending(path: "lightning-recovery-selection.json")) { data, file in
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        directory = dir; engine = restored; profile = recommended
        liquidityQuote = nil; receiveIntent = nil; invoiceCapacities = []
        driver = LightningChainDriver(engine: restored, headers: headers)
    }
    private func restoredEngine(_ backup: LightningRecoveryBackup, journal: sending FileLightningJournal, root: URL) async throws -> LightningEngine {
        let background = try openBackgroundStore(root: root, create: true)
        guard try journal.load() != nil else {
            return try LightningEngine.restoringRecovery(backup, chain: NetworkParams.params(for: network).genesisHash,
                journal: journal, backgroundStore: background)
        }
        let opened = try LightningEngine(chain: NetworkParams.params(for: network).genesisHash, journal: journal, backgroundStore: background)
        guard let status = await opened.recoveryStatus(), status.backupID == backup.id,
              status.sourceRevision == backup.revision else { throw LightningError.storageFailed }
        return opened
    }
}
