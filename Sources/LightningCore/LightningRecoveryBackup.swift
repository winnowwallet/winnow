import Foundation
import WalletCore

/// Portable Lightning secrets and monitor history. These bytes must only be
/// stored inside CloudWalletBackup's authenticated appState ciphertext. The
/// Bitcoin mnemonic alone cannot recreate this independent Lightning identity.
/// Every import is recovery-only, even when a counterparty reports equal state.
public struct LightningRecoveryBackup: Codable, Sendable, Equatable {
    public static let maximumBytes = 8 * 1024 * 1024
    public let version: Int
    public let id: UUID
    public let chain: Data
    public let nodeID: Data
    public let savedAt: Date
    public let revision: UInt64
    public let channelCount: Int
    let snapshot: Data

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumBytes else { throw LightningError.storageFailed }
        return bytes
    }
    public static func decode(_ bytes: Data, chain: Data) throws -> Self {
        guard bytes.count <= maximumBytes else { throw LightningError.storageFailed }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        _ = try value.validatedState(chain: chain)
        return value
    }
    func validatedState(chain expected: Data) throws -> LightningEngine.State {
        guard version == 1, chain == expected, chain.count == 32, snapshot.count <= Self.maximumBytes,
              savedAt.timeIntervalSince1970.isFinite else { throw LightningError.storageFailed }
        let state = try JSONDecoder().decode(LightningEngine.State.self, from: snapshot)
        guard state.version == 5, state.chain == chain, state.revision == revision,
              state.channels.count == channelCount, try ChannelKeys.publicKey(secret: state.nodeSecret) == nodeID
        else { throw LightningError.storageFailed }
        try LightningEngine.validateLoaded(state)
        try Self.validateKeys(state)
        return state
    }
    private static func validateKeys(_ state: LightningEngine.State) throws {
        for channel in state.channels {
            let terms = try channel.secrets.terms(capacity: channel.capacity, format: channel.local.format)
            guard terms.funding == channel.local.funding, terms.revocation == channel.local.revocation,
                  terms.payment == channel.local.payment, terms.delayed == channel.local.delayed,
                  terms.htlc == channel.local.htlc, terms.firstPoint == channel.local.firstPoint
            else { throw LightningError.storageFailed }
        }
    }
}

extension LightningEngine {
    struct RecoveryRestore: Codable {
        let backupID: UUID
        let savedAt: Date
        let sourceRevision: UInt64
        var respondingPeers: [Data] = []
    }
    public struct RecoveryStatus: Sendable {
        public let backupID: UUID
        public let savedAt: Date
        public let sourceRevision: UInt64
        public let channelCount: Int
        public let respondingPeers: Int
    }
    public func recoveryStatus() -> RecoveryStatus? {
        state.recoveryRestore.map {
            .init(backupID: $0.backupID, savedAt: $0.savedAt, sourceRevision: $0.sourceRevision,
                  channelCount: state.channels.count, respondingPeers: $0.respondingPeers.count)
        }
    }
    public func recoveryBackup(savedAt: Date = Date()) throws -> LightningRecoveryBackup {
        try healthy()
        var exported = state
        // The routing graph is already outside the journal. Pending offers and
        // payment messages cannot be resumed safely on a replacement device.
        exported.async = AsyncState(); exported.offers = nil; exported.outbox = []
        // A just-in-time purchase binds only this device's open negotiation.
        exported.jit = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let snapshot = try encoder.encode(exported)
        let value = try LightningRecoveryBackup(version: 1, id: UUID(), chain: state.chain,
            nodeID: nodeID(), savedAt: savedAt, revision: state.revision,
            channelCount: exported.channels.count, snapshot: snapshot)
        _ = try value.encoded()
        return value
    }
    /// The caller provides a NEW, separately named, encrypted journal. Never
    /// overwrite the active journal or give restored snapshots an activation
    /// switch. Durable restriction precedes every peer connection and scan.
    public static func restoringRecovery(_ backup: LightningRecoveryBackup, chain: Data,
                                         journal: sending any LightningJournal,
                                         backgroundStore: LightningBackgroundStore? = nil) throws -> LightningEngine {
        let source = try backup.validatedState(chain: chain)
        guard try journal.load() == nil else { throw LightningError.storageFailed }
        let restored = try recoveryState(source, backup: backup)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Do not expose an engine if the durable recovery-only record failed.
        try journal.store(encoder.encode(restored))
        return try LightningEngine(chain: chain, journal: journal, backgroundStore: backgroundStore)
    }
    private static func recoveryState(_ source: State, backup: LightningRecoveryBackup) throws -> State {
        guard source.revision < UInt64.max else { throw LightningError.storageFailed }
        var restored = source
        restored.revision += 1
        restored.recoveryRestore = .init(backupID: backup.id, savedAt: backup.savedAt, sourceRevision: source.revision)
        restored.outbox = []; restored.async = AsyncState(); restored.offers = nil; restored.jit = nil
        restored.scan = LightningChainState(nextHeight: (source.scan.origin?.height ?? 0) + 1,
                                             origin: source.scan.origin, rescanRequired: true)
        restored.channels = source.channels.filter { $0.fundingTxid != nil && $0.phase != .closed }.map(recoveryChannel)
        try validateRecoveryRestore(restored)
        return restored
    }
    private static func recoveryChannel(_ original: ChannelState) -> ChannelState {
        var channel = original
        channel.dataLossDetected = true; channel.phase = .recovering
        channel.localReady = true; channel.remoteReady = false; channel.fundingIsConfirmed = false
        channel.closingTransaction = nil; channel.closingFee = nil; channel.closingFeeLimit = nil
        channel.localShutdown = nil; channel.remoteShutdown = nil
        channel.observedFundingSpend = nil; channel.fundingSpendHeight = nil
        channel.resolutions = []; channel.feeBumps = nil; channel.invoicePolicy = nil
        // A restored channel waits for its funding like any other.
        channel.zeroConf = nil; channel.incomingExtraFee = nil
        return channel
    }
    static func validateRecoveryRestore(_ state: State) throws {
        guard let recovery = state.recoveryRestore else { return }
        guard state.version == 5, recovery.sourceRevision < state.revision,
              recovery.respondingPeers.count <= 64,
              Set(recovery.respondingPeers).count == recovery.respondingPeers.count,
              state.outbox.allSatisfy({ [17, 136].contains($0.message.type) }),
              state.async.outbox.isEmpty, state.offers == nil, state.jit == nil else { throw LightningError.storageFailed }
        for channel in state.channels {
            guard channel.dataLossDetected, [.recovering, .closed].contains(channel.phase), channel.zeroConf == nil,
                  channel.closingTransaction == nil, (channel.feeBumps ?? []).isEmpty,
                  channel.fundingTxid != nil else { throw LightningError.storageFailed }
        }
    }
}
