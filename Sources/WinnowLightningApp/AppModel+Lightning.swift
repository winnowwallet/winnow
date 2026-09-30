import CryptoKit
import Foundation
import LightningCore
import WalletCore

/// Winnow Lightning's part of the app model. AppModel.swift reaches it only
/// through `#if LIGHTNING` hooks; the ordinary WinnowApp never compiles it.
extension AppModel {
    /// The selected network's Lightning node.
    var lightning: LightningAppController? { lightningControllers[network] }

    /// One controller per network, each with its own journal and keys. The
    /// full journal key is readable only while unlocked; the background
    /// recovery store's key once the device has been unlocked since boot.
    static func makeLightningControllers(e2e: E2EMode?, storeKeys: (any StoreKeyVault)?,
                                         keychainService: String) -> [BitcoinNetwork: LightningAppController] {
        let keys = storeKeys ?? KeychainStoreKeyVault(service: keychainService, protection: .whenUnlocked)
        let backgroundKeys = storeKeys ?? KeychainStoreKeyVault(service: keychainService)
        let controllers = Dictionary(uniqueKeysWithValues: BitcoinNetwork.allCases.map {
            ($0, LightningAppController(network: $0, keys: keys, backgroundKeys: backgroundKeys))
        })
        #if DEBUG
        // A regtest UI fixture pins the node identity to its pinned wallet.
        if e2e?.forcedNetwork == .regtest, let entropy = e2e?.entropy {
            controllers[.regtest]?.fixtureNodeSecret = Data(SHA256.hash(data: Data("winnow-lightning-ui".utf8) + entropy))
        }
        #endif
        return controllers
    }

    /// Funded channels start the protection reminders; a recovery relay that
    /// did not finish counts as a failed check.
    func observeLightningChannels() {
        for (network, controller) in lightningControllers {
            controller.monitoringChanged = { [weak self] funded in
                self?.channelProtection.channelState(network: network, funded: funded)
            }
            controller.recoveryRelayFailed = { [weak self] in self?.channelProtection.scanFailed(network: network) }
        }
    }

    // MARK: - Networking

    /// The foreground opens the signing engine. A background check opens only
    /// the watch-only monitor that can relay pre-signed recovery transactions.
    func prepareLightning(directory: URL, headers: HeaderChain) async throws {
        if backgroundRunning {
            backgroundMonitor = try lightning?.prepareBackground(directory: directory)
        } else {
            try await lightning?.prepare(directory: directory, headers: headers)
        }
    }

    /// After a background check's networking stopped: an unfinished check
    /// warns (unless the app came back or is switching networks), queued
    /// reminders are handed to iOS, and the monitor releases its store.
    func finishLightningBackgroundCheck(complete: Bool, foreground: Bool) async {
        if !complete, !foreground, !changingNetwork { channelProtection.scanFailed(network: network) }
        await channelProtection.flushReminders()
        await backgroundMonitor?.finish()
        backgroundMonitor = nil
    }

    /// A manual Sync tap is not the periodic sync task. Drain it, and any
    /// stack construction already in flight, before handing files and actors
    /// to a background monitor or a new foreground generation.
    func finishStoppingLightning() async {
        while status.syncing || buildingStack { await Task.yield() }
        await lightning?.stop()
    }

    /// One switch at a time, and never across a payment, channel action or
    /// restore that holds the spending gate.
    func lightningAllowsNetworkSwitch(to newNetwork: BitcoinNetwork) -> Bool {
        guard e2e?.forcedNetwork == nil || e2e?.forcedNetwork == newNetwork else { return false }
        return newNetwork != network && !changingNetwork && operationsInFlight.isEmpty
    }

    /// One verified filter scan applies both wallet matches and channel
    /// observations. No separate Bitcoin node, RPC wallet or chain model.
    func syncWalletAndLightning(filters: FilterSync, scripts: [Data],
                                onReorg: @escaping @Sendable (UInt32) async throws -> Void,
                                onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        if backgroundRunning, lightning != nil {
            return try await syncLightningInBackground(filters: filters, scripts: scripts, onReorg: onReorg, onMatch: onMatch)
        }
        guard let lightning else {
            return try await syncBitcoinWallet(filters: filters, scripts: scripts, onReorg: onReorg, onMatch: onMatch)
        }
        return try await syncLightningInForeground(lightning, filters: filters, scripts: scripts, onReorg: onReorg, onMatch: onMatch)
    }

    private func syncLightningInBackground(filters: FilterSync, scripts: [Data],
                                           onReorg: @escaping @Sendable (UInt32) async throws -> Void,
                                           onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        guard let monitor = backgroundMonitor, let stack else { throw AppError.noStack }
        let driver = LightningChainDriver(monitor: monitor, headers: stack.chain)
        let complete = try await driver.sync(using: filters, walletScripts: scripts, maxBlocks: 2_000,
            onEvent: { events in try await relayBackgroundRecovery(events, broadcaster: stack.broadcaster) },
            onReorg: onReorg, onMatch: onMatch)
        let protected = await monitor.isComplete()
        return complete && protected
    }

    private func syncBitcoinWallet(filters: FilterSync, scripts: [Data],
                                   onReorg: @escaping @Sendable (UInt32) async throws -> Void,
                                   onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        try await filters.sync(watchScripts: scripts, maxBlocks: backgroundRunning ? 2_000 : nil,
                               onReorg: onReorg, onMatch: onMatch)
        return await filters.nextScanHeight > filters.chain.height
    }

    private func syncLightningInForeground(_ lightning: LightningAppController, filters: FilterSync, scripts: [Data],
                                           onReorg: @escaping @Sendable (UInt32) async throws -> Void,
                                           onMatch: @escaping @Sendable (BlockMatch) async throws -> Void) async throws -> Bool {
        let generation = lightning.generation
        guard let driver = lightning.driver else { throw AppError.noStack }
        let complete = try await driver.sync(using: filters, walletScripts: scripts, onEvent: { [weak self] events in
            guard let self else { throw CancellationError() }
            try await lightning.requireNetwork(self, generation: generation)
            try await lightning.handle(events, model: self)
        }, onReorg: onReorg, onMatch: onMatch)
        try await finishLightningScan(complete: complete, controller: lightning, generation: generation)
        return complete
    }

    private func finishLightningScan(complete: Bool, controller: LightningAppController, generation: UInt64) async throws {
        try controller.requireNetwork(self, generation: generation)
        if complete { await controller.resume(model: self) }
    }

    // MARK: - Keeping the research wallet

    /// Channel recovery destinations belong to this wallet's keys. Replacing
    /// the wallet while retaining its channel journal can strand those funds.
    /// Check the file as well as memory so this also holds before boot and
    /// after another creation/import completes across an authentication await.
    func requireLightningWalletPreserved(importing descriptor: String? = nil) throws {
        guard let lightning else { return }
        let savedWallet = walletURL().map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        guard walletID == nil, !savedWallet else {
            throw AppError.storageDamaged("Keep this research wallet on the device: replacing it could lose the keys needed to recover Lightning channel funds.")
        }
        if let root = storageDirectory() { try lightning.requireRecoveryWalletMatch(root: root, importing: descriptor) }
    }

    func requireLightningWalletRemovable() throws {
        guard lightning == nil else {
            throw AppError.storageDamaged("Keep this research wallet on the device: its Lightning journal may still be needed to recover channel funds.")
        }
    }

    // MARK: - Portable recovery file

    /// The encrypted recovery file's contents: the seed-bearing wallet bundle,
    /// its private context, and the channels' recovery keys.
    func portableLightningBackupContents() async throws -> CloudBackupContents {
        guard let wallet, let lightning else { throw AppError.noWallet }
        let selectedNetwork = network, selectedWallet = walletID
        try await authenticateSensitiveAction(reason: "Export encrypted Bitcoin and Lightning recovery keys")
        defer { keychainAuthentication.revoke() }
        try Task.checkCancellation()
        var bundle = try await wallet.recoveryBundle(includeMnemonic: true)
        bundle.vaults = try await vaultStore.backupRecords()
        guard let recovery = try await lightning.recoveryPayload() else {
            throw WalletError.invalidBundle("Lightning has not opened its channel journal yet. Connect once, then save the recovery file.")
        }
        let state = PortableLightningState(context: try await cloudAppState(for: bundle), lightning: recovery)
        try state.validate(for: bundle)
        try Task.checkCancellation()
        guard network == selectedNetwork, walletID == selectedWallet else { throw CancellationError() }
        return try CloudBackupContents(bundle: bundle, appState: state.encoded())
    }

    /// Restores the file's channels in recovery mode, and its wallet unless
    /// that same wallet is already here. Holds the spending gate throughout,
    /// so no payment, channel action or network switch interleaves.
    func restorePortableLightningBackup(_ contents: CloudBackupContents) async throws -> ImportReport? {
        try await exclusively(.spending) { try await restorePortableContents(contents) }
    }

    private func restorePortableContents(_ contents: CloudBackupContents) async throws -> ImportReport? {
        let state = try PortableLightningState.decode(contents.appState, for: contents.bundle)
        let selectedNetwork = network
        guard contents.bundle.network == selectedNetwork.rawValue else { throw AppError.wrongNetwork(contents.bundle.network) }
        try await authenticateSensitiveAction(reason: "Restore encrypted Bitcoin and Lightning recovery keys")
        defer { keychainAuthentication.revoke() }
        try Task.checkCancellation()
        guard network == selectedNetwork else { throw CancellationError() }
        if walletID != nil {
            try await restorePortableContext(state, onto: contents.bundle)
            return nil
        }
        // Commit the separate recovery-only journal before installing Bitcoin
        // keys. A crash during the import can never boot a restored channel as
        // an active channel; retry selects the same durable recovery namespace.
        try requireLightningWalletPreserved(importing: contents.bundle.descriptor)
        try await restoreLightningPayload(state.lightning, descriptor: contents.bundle.descriptor)
        let report = try await importWallet(bundle: contents.bundle, authenticate: false) { restoredID in
            guard self.walletID == restoredID, self.network == selectedNetwork else { throw CancellationError() }
            try await self.applyCloudAppState(state.context)
        }
        finishOnboarding()
        return report
    }

    /// The same wallet is already here: add its channels' recovery keys and
    /// the accounts this device lacks, and never replace the wallet itself.
    private func restorePortableContext(_ state: PortableLightningState, onto bundle: ImportBundle) async throws {
        guard walletDescriptor?.serialized() == bundle.descriptor else { throw WalletError.descriptorMismatch }
        try await restoreLightningPayload(state.lightning, descriptor: bundle.descriptor)
        try await applyCloudAppState(state.context)
        try await vaultStore.mergeMissingRecoveryRecords(bundle.vaults ?? [])
        await refresh()
        finishOnboarding()
    }

    private func restoreLightningPayload(_ backup: LightningRecoveryBackup, descriptor: String?) async throws {
        guard let lightning, let root = storageDirectory() else { throw AppError.noStack }
        guard let descriptor else { throw WalletError.invalidBundle("Lightning recovery requires its matching Bitcoin wallet descriptor.") }
        let headers = try stack?.chain ?? HeaderChain(params: NetworkParams.params(for: network))
        try await lightning.restoreRecovery(backup, root: root, headers: headers, walletDescriptor: descriptor)
    }
}
