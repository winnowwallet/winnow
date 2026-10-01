import Foundation
import WalletCore

/// Both the full engine and the keyless background monitor use the same
/// verified-chain adapter, including reorg and incomplete-scan handling.
protocol LightningChainMonitor: Actor {
    func chainHash() -> Data
    func hasChannels() -> Bool
    func chainStatus() -> LightningEngine.ChainStatus
    func chainWatches() throws -> FilterWatchSet
    func startChainScan(height: UInt32, hash: Data) throws
    func chainDisconnected()
    func chainCaughtUp(height: UInt32) throws
    func scannedBlock(_ block: FilterScannedBlock) throws -> [LightningEngine.Event]
    func blocksDisconnected(to height: UInt32, hash: Data) throws
    func pendingChainEvents() throws -> [LightningEngine.Event]
}
extension LightningEngine: LightningChainMonitor {}

/// Cannot sign, pay, fund or contact a Lightning peer. It can only publish
/// transactions authorized and signed by the foreground channel engine.
public actor LightningBackgroundMonitor: LightningChainMonitor {
    private let store: LightningBackgroundStore
    private let lease: UUID
    private var snapshot: LightningBackgroundSnapshot
    private var currentHeight: UInt32?
    private var closed = false

    public init(store: LightningBackgroundStore, chain: Data) throws {
        let (lease, snapshot) = try store.begin()
        guard snapshot.version == 1, snapshot.chain == chain else {
            store.end(lease); throw LightningError.storageFailed
        }
        self.store = store; self.lease = lease; self.snapshot = snapshot
    }
    deinit { store.end(lease) }
    public func finish() { closed = true; currentHeight = nil; store.end(lease) }
    public func isComplete() -> Bool { currentHeight != nil && snapshot.channels.count == snapshot.channelCount }
    func chainHash() -> Data { snapshot.chain }
    func hasChannels() -> Bool { snapshot.channelCount != 0 }
    func chainStatus() -> LightningEngine.ChainStatus {
        .init(nextHeight: snapshot.scan.nextHeight, revision: snapshot.revision,
              rescanRequired: snapshot.scan.rescanRequired,
              origin: .init(height: snapshot.scan.origin?.height ?? 0, hash: snapshot.scan.origin?.hash ?? snapshot.chain),
              positions: snapshot.scan.positions.map { .init(height: $0.height, hash: $0.hash) })
    }
    func chainWatches() throws -> FilterWatchSet {
        guard !closed else { throw LightningError.storageFailed }
        var scripts = Set(snapshot.channels.flatMap(\.scripts))
        for transaction in snapshot.scan.transactions {
            scripts.formUnion(try Transaction.decode(transaction.raw).outputs.map(\.scriptPubKey))
        }
        return .init(scripts: Array(scripts), revision: snapshot.revision)
    }
    func startChainScan(height: UInt32, hash: Data) throws {
        guard snapshot.channelCount == 0, hash.count == 32, height < UInt32.max else { throw LightningError.invalidState }
        var next = snapshot
        next.scan = .init(nextHeight: height + 1, origin: .init(height: height, hash: hash))
        try persist(next)
    }
    func chainDisconnected() { currentHeight = nil }
    func chainCaughtUp(height: UInt32) throws {
        guard !closed, snapshot.channelCount == 0 || snapshot.scan.nextHeight > height else { throw LightningChainError.recoveryRequired }
        currentHeight = height
    }
    func scannedBlock(_ block: FilterScannedBlock) throws -> [LightningEngine.Event] {
        guard !closed, block.watchRevision == snapshot.revision else { throw LightningChainError.changedWatches }
        if block.height < snapshot.scan.nextHeight { return [] }
        guard block.height == snapshot.scan.nextHeight, block.height < UInt32.max else { throw LightningChainError.restartScan }
        guard block.header.previousHash == (snapshot.scan.positions.last?.hash ?? snapshot.scan.origin?.hash ?? snapshot.chain)
        else { throw LightningChainError.recoveryRequired }
        var next = snapshot
        if let body = block.block {
            guard body.header == block.header, body.hasValidMerkleRoot else { throw LightningError.invalidCommitment }
            try observe(body, height: block.height, in: &next)
        }
        next.scan.positions.append(.init(height: block.height, hash: block.header.hash))
        next.scan.positions = Array(next.scan.positions.suffix(2048))
        next.scan.nextHeight = block.height + 1
        try persist(next)
        return []
    }
    private func observe(_ body: Block, height: UInt32, in next: inout LightningBackgroundSnapshot) throws {
        var watched = Set(next.channels.map { $0.funding.txid })
        watched.formUnion(try next.scan.transactions.map { try Transaction.decode($0.raw).txid })
        for (transactionIndex, tx) in body.transactions.enumerated() where watched.contains(tx.txid) || tx.inputs.contains(where: { watched.contains($0.previousOutput.txid) }) {
            guard next.scan.transactions.count < 8192 else { throw LightningChainError.recoveryRequired }
            if !next.scan.transactions.contains(where: { (try? Transaction.decode($0.raw).txid) == tx.txid }) {
                next.scan.transactions.append(.init(height: height, blockHash: body.hash, raw: tx.serialized(includeWitness: true), transactionIndex: UInt32(transactionIndex)))
            }
            watched.insert(tx.txid)
        }
    }
    func blocksDisconnected(to height: UInt32, hash: Data) throws {
        currentHeight = nil
        let origin = chainStatus().origin
        guard height >= origin.height, height < UInt32.max,
              height == origin.height ? hash == origin.hash : snapshot.scan.positions.contains(where: { $0.height == height && $0.hash == hash })
        else { throw LightningChainError.recoveryRequired }
        var next = snapshot
        next.scan.positions.removeAll { $0.height > height }
        next.scan.transactions.removeAll { $0.height > height }
        next.scan.nextHeight = height + 1; next.scan.rescanRequired = false
        // A published close remains an intent across reorgs. Foreground must
        // adopt it before reconnecting; it must never revoke this commitment.
        try persist(next)
    }
    func pendingChainEvents() throws -> [LightningEngine.Event] {
        guard !closed, let height = currentHeight else { throw LightningError.invalidState }
        let confirmed = try snapshot.scan.transactions.map {
            try ChannelResolution.Confirmed(height: $0.height, tx: Transaction.decode($0.raw))
        }
        var next = snapshot
        var events: [LightningEngine.Event] = []
        for index in next.channels.indices {
            let channel = next.channels[index]
            let spent = confirmed.contains { $0.tx.inputs.contains { $0.previousOutput == channel.funding } }
            if !spent {
                if channel.closingIntent == nil, let deadline = channel.forceCloseHeight, height >= deadline {
                    next.channels[index].closingIntent = channel.forceClose
                }
                if let raw = next.channels[index].closingIntent { events.append(.broadcastClose(channelID: channel.id, transaction: raw)) }
            }
            for spend in channel.spends where try ChannelResolution.available(spend, confirmed: confirmed, height: height) {
                events.append(.broadcastRecovery(channelID: channel.id, transaction: spend.transaction))
            }
        }
        // Save force-close intentions before any caller can broadcast them.
        try persist(next)
        return events
    }
    private func persist(_ next: LightningBackgroundSnapshot) throws {
        guard !closed else { throw LightningError.storageFailed }
        try store.update(next, lease: lease)
        snapshot = next
    }
}
