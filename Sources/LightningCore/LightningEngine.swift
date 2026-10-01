import Foundation
import P256K
import WalletCore

/// Owns channel, monitor and protocol outbox state together. Networking owns
/// ephemeral Noise sessions; Winnow owns Bitcoin funding and validated chain.
public actor LightningEngine {
    public enum ChannelPhase: String, Sendable, Codable {
        case opening, accepted, awaitingFundingSignature, awaitingConfirmation, ready, closing, closed, recovering
    }
    public struct Channel: Sendable {
        public let id: Data, peer: Data
        public let capacitySat: UInt64
        public let phase: ChannelPhase
        public let format: ChannelFormat
        public let signedCommitment: Data?
        /// Funding remains exposed until a cooperative close has six verified confirmations.
        public let needsMonitoring: Bool
        /// A bought just-in-time channel working before its funding confirms.
        public var trustedUnconfirmed = false
    }
    public struct Outbound: Codable, Sendable, Equatable {
        public let sequence: UInt64
        public let peer: Data, channelID: Data
        public let message: LightningWire.Message
    }
    public enum Event: Sendable {
        case fundingRequired(temporaryID: Data, amountSat: UInt64, scriptPubKey: Data)
        case broadcastFunding(channelID: Data, transaction: Data)
        case channelReady(Data)
        case paymentChanged(Payment)
        case broadcastClose(channelID: Data, transaction: Data)
        case broadcastRecovery(channelID: Data, transaction: Data)
    }
    struct State: Codable {
        var version = 5
        var revision: UInt64 = 0
        var nextSequence: UInt64 = 0
        var chain: Data
        var nodeSecret: Data
        var channels: [ChannelState] = []
        var outbox: [Outbound] = []
        var payments: [PaymentRecord] = []
        var incoming: [ReceiveRequest] = []
        var scan = LightningChainState()
        var async = AsyncState()
        var offers: OrdinaryOfferState? = nil
        var recoveryRestore: RecoveryRestore? = nil
        var jit: [JITPurchase]? = nil
    }
    let journal: any LightningJournal
    let backgroundStore: LightningBackgroundStore?
    private var backgroundCache = LightningBackgroundSnapshot.Cache()
    var needsBackgroundSchemaUpgrade = false
    var state: State
    var failed = false
    var chainIsCurrent = false
    var chainHeight: UInt32 = 0
    var peers: [Data: LightningFeatures] = [:]
    var reestablishing = Set<Data>()
    var publicRoutingGraph: LightningRoutingGraph?
    var invoicePolicies: [UInt64: InvoicePolicy] = [:]

    public init(chain: Data, nodeSecret: Data? = nil, journal: sending any LightningJournal,
                backgroundStore: LightningBackgroundStore? = nil) throws {
        guard chain.count == 32 else { throw LightningError.invalidHash }
        self.journal = journal
        self.backgroundStore = backgroundStore
        if let bytes = try journal.load() {
            var loaded = try JSONDecoder().decode(State.self, from: bytes)
            guard [2, 3, 4, 5].contains(loaded.version), loaded.chain == chain else { throw LightningError.storageFailed }
            needsBackgroundSchemaUpgrade = loaded.version < 4
            loaded.version = 5
            guard nodeSecret == nil || nodeSecret == loaded.nodeSecret else { throw LightningError.storageFailed }
            try Self.validateLoaded(loaded)
            state = loaded
        } else {
            let secret = try nodeSecret ?? P256K.Signing.PrivateKey().dataRepresentation
            _ = try ChannelKeys.publicKey(secret: secret)
            state = State(chain: chain, nodeSecret: secret)
        }
    }
    public func channels() -> [Channel] {
        state.channels.map { Channel(id: $0.id, peer: $0.peer, capacitySat: $0.capacity, phase: $0.phase, format: $0.local.format,
                                     signedCommitment: $0.dataLossDetected ? nil : $0.signedCommitment,
                                     needsMonitoring: $0.fundingTxid != nil && $0.phase != .closed,
                                     trustedUnconfirmed: $0.zeroConf != nil && !$0.fundingIsConfirmed) }
    }
    public func chainHash() -> Data { state.chain }
    /// The adapter calls this only after its verified header/filter scan has
    /// caught up. Every restart starts paused, including fresh network sessions.
    public func chainCaughtUp(height: UInt32 = 0) throws { try healthy(); chainHeight = height; chainIsCurrent = true }
    public func nodeID() throws -> Data { try ChannelKeys.publicKey(secret: state.nodeSecret) }
    public func chainDisconnected() { chainIsCurrent = false }
    public func peerInitialized(_ peer: Data, features: LightningFeatures) throws {
        try healthy(); _ = try ChannelKeys.point(peer)
        try features.validateRequired(supported: [0, 6, 8, 12, 14, 22, 24, LightningFeatures.shutdownAnySegwit, 38, 44, 46, 50, 728])
        guard features.supports(12), features.supports(44) else { throw LightningError.invalidMessage }
        if state.recoveryRestore != nil { try prepareRecoveryReestablishment(peer) }
        else { try forgetUnsignedInbound(peer: peer); try prepareReestablishment(peer) }
        peers[peer] = features
    }
    public func peerDisconnected(_ peer: Data) { peers.removeValue(forKey: peer) }
    public func pendingMessages(peer: Data) throws -> [Outbound] {
        try connected(peer)
        if state.recoveryRestore != nil { return state.outbox.filter { $0.peer == peer && [17, 136].contains($0.message.type) } }
        return state.outbox.filter { item in
            guard item.peer == peer, !reestablishing.contains(item.channelID) || item.message.type == 136 else { return false }
            guard let channel = state.channels.first(where: { $0.id == item.channelID }) else { return true }
            // Opening and reestablishment remain possible while funding is
            // unconfirmed. Never publish payment/revocation work after a reorg.
            return channel.fundingUsable || [32, 33, 34, 35, 136].contains(item.message.type)
        }
    }
    @discardableResult
    public func openChannel(peer: Data, capacitySat: UInt64, feePerKW: UInt32, format: ChannelFormat? = nil) throws -> Data {
        try operational(peer)
        guard state.channels.count < 64 else { throw LightningError.invalidState }
        guard (20_000..<(1 << 24)).contains(capacitySat) else { throw LightningError.invalidAmount }
        let temporary = try P256K.Signing.PrivateKey().dataRepresentation, secrets = try ChannelSecrets()
        let resolved = format ?? (peers[peer]?.supports(22) == true ? .anchors : .staticRemoteKey)
        guard !resolved.hasAnchors || peers[peer]?.supports(22) == true else { throw LightningError.invalidMessage }
        let terms = try secrets.terms(capacity: capacitySat, format: resolved)
        let open = ChannelNegotiation.Open(chain: state.chain, temporaryID: temporary, capacity: capacitySat,
            pushMsat: 0, feePerKW: feePerKW, terms: terms)
        let message = try open.message()
        let channel = ChannelState(peer: peer, temporaryID: temporary, capacity: capacitySat, pushMsat: 0,
            feePerKW: feePerKW, isFunder: true, secrets: secrets, local: terms, phase: .opening)
        var next = state; next.channels.append(channel)
        try Self.enqueue(message, channel: channel, in: &next)
        try persist(next)
        return temporary
    }
    /// Funding is already reserved and signed by Winnow. No signature is
    /// released until the exact funding bytes and initial monitor are durable.
    public func provideFunding(temporaryID: Data, peer: Data, transaction: Transaction, output: UInt16) throws {
        try operational(peer)
        let index = try channelIndex(temporaryID, peer: peer)
        var channel = state.channels[index]
        guard channel.phase == .accepted, channel.isFunder else { throw LightningError.invalidState }
        try channel.checkFunding(transaction, output: output)
        channel.fundingTxid = transaction.txid; channel.fundingOutput = output
        channel.fundingTransaction = transaction.serialized(includeWitness: true)
        channel.phase = .awaitingFundingSignature
        var writer = LightningWire.Writer(); writer.append(temporaryID); writer.append(transaction.txid)
        writer.u16(output); writer.append(try channel.remoteSignature())
        var next = state; next.channels[index] = channel
        rewindForNewFunding(in: &next)
        try Self.enqueue(.init(type: 34, payload: writer.data), channel: channel, in: &next)
        try persist(next)
    }
    public func receive(peer: Data, message: LightningWire.Message) throws -> [Event] {
        try connected(peer)
        if state.recoveryRestore != nil { return try receiveRecoveryMessage(peer: peer, message: message) }
        return try receiveChannelMessage(peer: peer, message: message)
    }
    private func receiveChannelMessage(peer: Data, message: LightningWire.Message) throws -> [Event] {
        switch message.type {
        case 32: return try receiveOpen(peer: peer, message: message)
        case 33: return try receiveAccept(peer: peer, message: message)
        case 34: return try receiveFundingCreated(peer: peer, message: message)
        case 35: return try receiveFundingSigned(peer: peer, message: message)
        case 36: return try receiveReady(peer: peer, message: message)
        case 136: return try receiveReestablish(peer: peer, message: message)
        case 128, 130, 131, 134, 135: return try receiveUpdate(peer: peer, message: message)
        case 132: return try receiveCommitment(peer: peer, message: message)
        case 133: return try receiveRevocation(peer: peer, message: message)
        case 38, 39: return try receiveClose(peer: peer, message: message)
        default: throw LightningError.invalidMessage
        }
    }
    func channelIndex(_ id: Data, peer: Data) throws -> Int {
        guard let index = state.channels.firstIndex(where: { $0.peer == peer && ($0.id == id || $0.temporaryID == id) })
        else { throw LightningError.invalidState }
        return index
    }
    func healthy() throws { guard !failed else { throw LightningError.storageFailed } }
    func operational(_ peer: Data) throws {
        try requireUsableChannels()
        try connected(peer)
    }
    func connected(_ peer: Data) throws {
        try healthy()
        guard chainIsCurrent, peers[peer] != nil else { throw LightningError.invalidState }
    }
    func requireUsableChannels() throws {
        try healthy()
        guard state.recoveryRestore == nil else { throw LightningError.invalidState }
    }
    func persist(_ proposed: State) throws {
        try healthy()
        var next = proposed
        guard state.revision < UInt64.max else { throw LightningError.storageFailed }
        next.revision = state.revision + 1
        // Every write preserves the restore restriction, including future
        // adapters: an imported journal can never become an active channel.
        try Self.validateRecoveryRestore(next)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            // The locked monitor must be updated BEFORE saving/publishing a
            // revocation. A crash between stores leaves recovery ahead and
            // foreground fails closed; it can never expose an older commitment.
            try backgroundStore?.replace(LightningBackgroundSnapshot.make(next, cache: &backgroundCache))
            try journal.store(encoder.encode(next))
            state = next
        } catch { failed = true; throw LightningError.storageFailed }
    }
    static func enqueue(_ message: LightningWire.Message, channel: ChannelState, in state: inout State) throws {
        guard state.nextSequence < UInt64.max, state.outbox.count < 1024 else { throw LightningError.invalidState }
        state.outbox.append(Outbound(sequence: state.nextSequence, peer: channel.peer, channelID: channel.id, message: message))
        state.nextSequence += 1
    }
    static func acknowledge(_ types: Set<UInt16>, channel: ChannelState, in state: inout State) {
        state.outbox.removeAll {
            $0.peer == channel.peer && ($0.channelID == channel.id || $0.channelID == channel.temporaryID) && types.contains($0.message.type)
        }
    }
    static func validateLoaded(_ state: State) throws {
        try validateOrdinaryOffers(state.offers)
        try validateAnchorFeeBumps(state)
        try validateRecoveryRestore(state)
        let origin = state.scan.origin
        guard state.scan.nextHeight > (origin?.height ?? 0),
              origin == nil || (origin!.hash.count == 32 && (origin!.height != 0 || origin!.hash == state.chain)),
              state.scan.positions.allSatisfy({ $0.height > (origin?.height ?? 0) && $0.height < state.scan.nextHeight && $0.hash.count == 32 })
        else { throw LightningError.storageFailed }
        let sequences = state.outbox.map(\.sequence) + state.async.outbox.map(\.sequence)
        guard state.channels.count <= 64, state.outbox.count <= 1024, state.async.outbox.count <= 1024,
              state.payments.count <= 4096, state.async.outgoing.count <= 4096, state.async.receives.count <= 128,
              Set(sequences).count == sequences.count,
              sequences.allSatisfy({ $0 < state.nextSequence }) else { throw LightningError.storageFailed }
        guard (state.jit?.count ?? 0) <= maximumJITPurchases else { throw LightningError.storageFailed }
        for channel in state.channels {
            _ = try ChannelKeys.point(channel.peer)
            try channel.local.validate(capacity: channel.capacity)
            guard channel.temporaryID.count == 32, channel.zeroConf == nil || !channel.isFunder,
                  channel.localAlias != 0, channel.remoteAlias != 0 else { throw LightningError.storageFailed }
            if channel.remote != nil { try channel.validateNegotiation() }
        }
    }
}
