import Foundation
import WalletCore

public enum LightningChainError: Error, Equatable {
    case busy, changedWatches, restartScan, missingHeader, recoveryRequired, catchUpDidNotConverge
}

struct LightningChainState: Codable {
    struct Position: Codable { let height: UInt32; let hash: Data }
    struct Observed: Codable { let height: UInt32; let blockHash: Data; let raw: Data; var transactionIndex: UInt32? }
    var nextHeight: UInt32 = 1
    // Nil in existing journals means genesis. Once a channel exists this
    // birthday never advances: newly learned funding may already be mined.
    var origin: Position?
    var positions: [Position] = []
    var transactions: [Observed] = []
    var rescanRequired = false
}

extension LightningEngine {
    func pendingChainEvents() throws -> [Event] {
        let ready = state.channels.filter { $0.phase == .ready && $0.fundingUsable }.map { Event.channelReady($0.id) }
        let payments = state.payments.filter { $0.payment.phase == .recovering || $0.chainResolution != nil }.map { Event.paymentChanged($0.payment) }
        return try ready + payments + pendingFundingBroadcasts() + pendingRecoveryBroadcasts()
    }
    func rewindForNewFunding(in next: inout State) {
        // A fundee may learn the outpoint after it has already confirmed.
        // Replay from the durable monitor birthday, including all existing
        // watches, without requiring headers below Winnow's checkpoint.
        next.scan.rescanRequired = true
    }
    public func hasChannels() -> Bool { !state.channels.isEmpty }

    /// Only the verified-chain adapter sets this, before the first channel.
    /// With no channel history there is nothing to monitor in older blocks.
    public func startChainScan(height: UInt32, hash: Data) throws {
        try healthy()
        guard state.channels.isEmpty, height < UInt32.max, hash.count == 32,
              height != 0 || hash == state.chain else { throw LightningError.invalidState }
        var next = state
        next.scan = LightningChainState(nextHeight: height + 1, origin: .init(height: height, hash: hash))
        try persist(next)
        chainHeight = height
    }
    public struct ChainStatus: Sendable {
        public struct Position: Sendable { public let height: UInt32; public let hash: Data }
        public let nextHeight: UInt32, revision: UInt64
        public let rescanRequired: Bool
        public let origin: Position
        public let positions: [Position]
    }
    public func chainStatus() -> ChainStatus {
        ChainStatus(nextHeight: state.scan.nextHeight, revision: state.revision,
                    rescanRequired: state.scan.rescanRequired,
                    origin: .init(height: state.scan.origin?.height ?? 0, hash: state.scan.origin?.hash ?? state.chain),
                    positions: state.scan.positions.map { .init(height: $0.height, hash: $0.hash) })
    }
    public func chainWatches() throws -> FilterWatchSet {
        try healthy()
        var scripts = Set<Data>()
        for channel in state.channels {
            if channel.remote != nil { scripts.insert(try channel.fundingScript()) }
            if let close = channel.closingTransaction {
                for output in try Transaction.decode(close).outputs { scripts.insert(output.scriptPubKey) }
            }
        }
        for observed in state.scan.transactions {
            for output in try Transaction.decode(observed.raw).outputs { scripts.insert(output.scriptPubKey) }
        }
        return FilterWatchSet(scripts: Array(scripts), revision: state.revision)
    }
    /// Header and filter provenance belongs to Winnow. The adapter supplies
    /// only headers found in its verified HeaderChain, in ancestry order.
    public func scannedBlock(_ block: FilterScannedBlock) throws -> [Event] {
        try healthy()
        guard block.watchRevision == state.revision else { throw LightningChainError.changedWatches }
        if block.height < state.scan.nextHeight { return [] }
        guard block.height == state.scan.nextHeight, block.height < UInt32.max else { throw LightningChainError.restartScan }
        let previous = state.scan.positions.last?.hash ?? state.scan.origin?.hash ?? state.chain
        guard block.header.previousHash == previous else { throw LightningChainError.recoveryRequired }
        if let body = block.block {
            guard body.header == block.header, body.hasValidMerkleRoot else { throw LightningError.invalidCommitment }
        }
        var next = state
        if let body = block.block { try observe(body, height: block.height, in: &next) }
        next.scan.positions.append(.init(height: block.height, hash: block.header.hash))
        next.scan.positions = Array(next.scan.positions.suffix(2048))
        next.scan.nextHeight = block.height + 1
        var events = try updateChainChannels(height: block.height, in: &next)
        try Self.forgetUnfundedZeroConf(height: block.height, in: &next)
        events += try updateRecovery(height: block.height, in: &next)
        events += try reconcileChainPayments(height: block.height, in: &next)
        try persist(next)
        chainHeight = block.height
        return events
    }
    private func observe(_ block: Block, height: UInt32, in next: inout State) throws {
        var watchedTxids = Set(next.channels.compactMap(\.fundingTxid))
        for transaction in next.scan.transactions { watchedTxids.insert(try Transaction.decode(transaction.raw).txid) }
        for (transactionIndex, transaction) in block.transactions.enumerated() {
            guard watchedTxids.contains(transaction.txid) || transaction.inputs.contains(where: { watchedTxids.contains($0.previousOutput.txid) }) else { continue }
            guard next.scan.transactions.count < 8192 else { throw LightningChainError.recoveryRequired }
            if !next.scan.transactions.contains(where: { (try? Transaction.decode($0.raw).txid) == transaction.txid }) {
                next.scan.transactions.append(.init(height: height, blockHash: block.hash, raw: transaction.serialized(includeWitness: true), transactionIndex: UInt32(transactionIndex)))
            }
            // A child in the same block must be considered immediately.
            watchedTxids.insert(transaction.txid)
        }
    }
    private func updateChainChannels(height: UInt32, in next: inout State) throws -> [Event] {
        var events: [Event] = []
        let observed = try next.scan.transactions.map { ($0.height, try Transaction.decode($0.raw)) }
        for index in next.channels.indices {
            var channel = next.channels[index]
            guard let txid = channel.fundingTxid, let output = channel.fundingOutput else { continue }
            if let spend = observed.first(where: { item in item.1.inputs.contains { $0.previousOutput == .init(txid: txid, vout: UInt32(output)) } }) {
                channel.observedFundingSpend = spend.1.serialized(includeWitness: true)
                channel.fundingSpendHeight = spend.0
                let cooperative = channel.closingFee.flatMap { try? channel.closeTransaction(fee: $0).txid } == spend.1.txid
                let finalized = cooperative && UInt64(height) + 1 >= UInt64(spend.0) + 6
                channel.phase = channel.dataLossDetected ? .recovering : (finalized ? .closed : .closing)
                events += markPaymentsRecovering(channelID: channel.id, in: &next)
                next.outbox.removeAll { $0.peer == channel.peer && $0.channelID == channel.id }
            } else if let funding = observed.first(where: { $0.1.txid == txid }) {
                try channel.checkFunding(funding.1, output: output)
                if UInt64(height) + 1 >= UInt64(funding.0) + UInt64(channel.minimumDepth) {
                    channel.fundingIsConfirmed = true
                    if !channel.localReady {
                        try markFundingReady(&channel, in: &next)
                        if channel.phase == .ready { events.append(.channelReady(channel.id)) }
                    }
                }
            }
            next.channels[index] = channel
        }
        return events
    }
    private func markFundingReady(_ channel: inout ChannelState, in next: inout State) throws {
        guard channel.signedCommitment != nil, channel.phase == .awaitingConfirmation else { throw LightningError.invalidState }
        channel.localReady = true
        channel.fundingIsConfirmed = true
        if channel.remoteReady { channel.phase = .ready }
        try Self.enqueue(Self.readyMessage(channel), channel: channel, in: &next)
    }
    public func blocksDisconnected(to height: UInt32, hash: Data) throws {
        try healthy(); chainIsCurrent = false
        let origin = chainStatus().origin
        guard height < UInt32.max,
              height >= origin.height,
              height == origin.height ? hash == origin.hash : state.scan.positions.contains(where: { $0.height == height && $0.hash == hash })
        else { throw LightningChainError.recoveryRequired }
        var next = state
        next.scan.positions.removeAll { $0.height > height }
        next.scan.transactions.removeAll { $0.height > height }
        next.scan.nextHeight = height + 1
        next.scan.rescanRequired = false
        rollBackChainPayments(to: height, in: &next)
        for index in next.channels.indices {
            if next.channels[index].phase == .closed { next.channels[index].phase = .closing }
            let funding = next.scan.transactions.first { (try? Transaction.decode($0.raw).txid) == next.channels[index].fundingTxid }
            next.channels[index].fundingIsConfirmed = funding.map {
                UInt64(height) + 1 >= UInt64($0.height) + UInt64(next.channels[index].minimumDepth)
            } ?? false
            if let spent = next.channels[index].fundingSpendHeight, spent > height {
                next.channels[index].observedFundingSpend = nil; next.channels[index].fundingSpendHeight = nil
                // Never resume payments automatically after a closing transaction
                // is disconnected. Re-broadcast the durable close/recovery work.
            }
        }
        try persist(next)
        chainHeight = height
    }
}
