import Foundation
import WalletCore

/// Only pre-signed recovery transactions and public chain observations live
/// here. The full channel journal, signing secrets and wallet seed stay locked.
/// A lease prevents a foreground transition from racing an older recovery plan.
public final class LightningBackgroundStore: @unchecked Sendable {
    private let lock = NSLock()
    private let journal: any LightningJournal
    private var lease: UUID?

    public init(directory: URL, key: Data) throws {
        journal = try FileLightningJournal(directory: directory, key: key, protection: .afterFirstUnlock)
    }
    init(journal: any LightningJournal) { self.journal = journal }

    func load() throws -> LightningBackgroundSnapshot? {
        try lock.withLock {
            guard lease == nil else { throw LightningChainError.busy }
            return try read()
        }
    }
    private func read() throws -> LightningBackgroundSnapshot? {
        try journal.load().map { try JSONDecoder().decode(LightningBackgroundSnapshot.self, from: $0) }
    }
    func replace(_ snapshot: LightningBackgroundSnapshot) throws {
        try lock.withLock {
            guard lease == nil else { throw LightningChainError.busy }
            try write(snapshot)
        }
    }
    func begin() throws -> (UUID, LightningBackgroundSnapshot) {
        try lock.withLock {
            guard lease == nil, let snapshot = try read() else { throw LightningError.storageFailed }
            let id = UUID(); lease = id
            return (id, snapshot)
        }
    }
    func update(_ snapshot: LightningBackgroundSnapshot, lease expected: UUID) throws {
        try lock.withLock {
            guard lease == expected else { throw LightningError.storageFailed }
            try write(snapshot)
        }
    }
    func end(_ expected: UUID) { lock.withLock { if lease == expected { lease = nil } } }
    private func write(_ snapshot: LightningBackgroundSnapshot) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try journal.store(encoder.encode(snapshot))
    }
}

struct LightningBackgroundSnapshot: Codable {
    struct Channel: Codable {
        let id: Data
        let fundingTxid: Data
        let fundingOutput: UInt32
        var funding: Transaction.Outpoint { .init(txid: fundingTxid, vout: fundingOutput) }
        let scripts: [Data]
        let spends: [ChannelResolution.Spend]
        let forceClose: Data?
        let forceCloseHeight: UInt32?
        var closingIntent: Data?
    }
    let version: Int
    let chain: Data
    let revision: UInt64
    var scan: LightningChainState
    let channelCount: Int
    var channels: [Channel]

    struct Cache {
        var channels: [Data: (fingerprint: Data, value: Channel)] = [:]
    }
    static func make(_ state: LightningEngine.State) throws -> Self {
        var cache = Cache()
        return try make(state, cache: &cache)
    }
    static func make(_ state: LightningEngine.State, cache: inout Cache) throws -> Self {
        let preimages = state.incoming.map(\.preimage) + state.channels.flatMap(\.learnedPreimages)
        let confirmed = try state.scan.transactions.map {
            try ChannelResolution.Confirmed(height: $0.height, tx: Transaction.decode($0.raw))
        }
        let channels = try state.channels.compactMap {
            try makeChannel($0, preimages: preimages, confirmed: confirmed, cache: &cache)
        }
        return Self(version: 1, chain: state.chain, revision: state.revision, scan: state.scan,
                    channelCount: state.channels.filter { $0.fundingTxid != nil }.count, channels: channels)
    }
    private static func makeChannel(_ channel: ChannelState, preimages: [Data], confirmed: [ChannelResolution.Confirmed],
                                    cache: inout Cache) throws -> Channel? {
        guard let txid = channel.fundingTxid, let vout = channel.fundingOutput,
              let policy = channel.recovery, channel.signedCommitment != nil else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = ChannelKeys.hash(try encoder.encode(channel) + encoder.encode(preimages))
        if let cached = cache.channels[channel.id], cached.fingerprint == fingerprint { return cached.value }
        let (parents, synthetic) = try recoveryParents(channel, confirmed: confirmed)
        let context = ChannelResolution.Context(channel: channel, policy: policy,
                                                confirmed: synthetic, preimages: preimages)
        var spends = channel.resolutions
        for parent in parents { spends += try context.candidates(parent: parent) }
        spends += try authorizedFeeBumps(channel)
        var seen = Set<Data>()
        spends = try spends.filter { seen.insert(try Transaction.decode($0.transaction).txid).inserted }
        var scripts = Set([try channel.fundingScript()])
        for parent in parents + synthetic.map(\.tx) {
            scripts.formUnion(parent.outputs.map(\.scriptPubKey))
        }
        for spend in spends { scripts.formUnion(try Transaction.decode(spend.transaction).outputs.map(\.scriptPubKey)) }
        let plan = Channel(id: channel.id, fundingTxid: txid, fundingOutput: UInt32(vout),
            scripts: Array(scripts), spends: spends,
            forceClose: channel.dataLossDetected ? nil : channel.signedCommitment,
            forceCloseHeight: try forceCloseHeight(channel, preimages: preimages),
            closingIntent: channel.dataLossDetected ? nil : channel.closingTransaction)
        cache.channels[channel.id] = (fingerprint, plan)
        return plan
    }

    private static func authorizedFeeBumps(_ channel: ChannelState) throws -> [ChannelResolution.Spend] {
        guard !channel.dataLossDetected else { return [] }
        let records = channel.feeBumps ?? []
        let replaced = Set(records.compactMap(\.replacesTxid))
        return try records.compactMap { record in
            guard let raw = record.signedTransaction else { return nil }
            let tx = try Transaction.decode(raw)
            guard !replaced.contains(tx.txid) else { return nil }
            return ChannelResolution.Spend(tx, delay: record.kind == .htlc ? 1 : 0, height: tx.locktime,
                unconfirmedParent: record.kind == .commitment ? record.parentTransaction : nil)
        }
    }

    private static func recoveryParents(_ channel: ChannelState, confirmed: [ChannelResolution.Confirmed]) throws
        -> ([Transaction], [ChannelResolution.Confirmed]) {
        var parents: [Transaction] = []
        var synthetic = confirmed
        for bump in channel.feeBumps ?? [] where bump.kind == .htlc {
            if let raw = bump.signedTransaction { synthetic.append(try .init(height: 0, tx: Transaction.decode(raw))) }
        }
        // Pre-sign descendants of known second stages. A peer can augment an
        // anchor stage and change its txid; claiming that new descendant needs
        // foreground signing after the verified chain reveals the transaction.
        if !channel.dataLossDetected {
            let local = try channel.commitment(localOwner: true)
            parents.append(try Transaction.decode(channel.signedCommitment!))
            synthetic += try local.htlcOutputs.map {
                try .init(height: 0, tx: ChannelTransactions.htlcTransaction(commitment: local, output: $0))
            }
        }
        let last = channel.remoteNumber + (channel.awaitingRevocation ? 1 : 0)
        for number in 0...last {
            let remote = try channel.commitment(localOwner: false, number: number)
            parents.append(remote.transaction)
            synthetic += try remote.htlcOutputs.map {
                try .init(height: 0, tx: ChannelTransactions.htlcTransaction(commitment: remote, output: $0))
            }
        }
        if let raw = channel.observedFundingSpend { parents.append(try Transaction.decode(raw)) }
        if let raw = channel.closingTransaction { parents.append(try Transaction.decode(raw)) }
        return (parents, synthetic)
    }
    private static func forceCloseHeight(_ channel: ChannelState, preimages: [Data]) throws -> UInt32? {
        guard channel.phase == .ready else { return nil }
        let deadlines: [UInt32] = try channel.view(localOwner: true, number: channel.localNumber).htlcs.compactMap { htlc in
            if htlc.offered { return htlc.expiry }
            if preimages.contains(where: { ChannelKeys.hash($0) == htlc.paymentHash }) {
                return htlc.expiry > 6 ? htlc.expiry - 6 : 0
            }
            return nil
        }
        return deadlines.min()
    }

}
