import Foundation

extension LightningEngine {
    public func isChainCurrent() -> Bool { chainIsCurrent }
    public func currentRevision() -> UInt64 { state.revision }
    public struct FundingRequest: Sendable, Equatable {
        public let temporaryID: Data, peer: Data, scriptPubKey: Data
        public let amountSat: UInt64
    }
    /// Derived from durable accepted channels, so an interrupted app callback
    /// never loses the funding review. It is not authorization to fund.
    public func fundingRequests() throws -> [FundingRequest] {
        try healthy()
        return try state.channels.filter { $0.isFunder && $0.phase == .accepted }.map {
            try FundingRequest(temporaryID: $0.temporaryID, peer: $0.peer, scriptPubKey: $0.fundingScript(), amountSat: $0.capacity)
        }
    }
    /// Save a fresh identity before displaying its public key to a provider.
    public func persistIdentity() throws {
        try healthy()
        if state.revision == 0 { try persist(state) }
    }
    public struct ChannelBalance: Sendable {
        public let id: Data
        public let localMsat: UInt64, remoteMsat: UInt64
        public let recoveryConfigured: Bool
    }
    public func channelBalances() throws -> [ChannelBalance] {
        try healthy()
        // Negotiation terms describe a proposed allocation, not owned funds.
        // Require an enforceable commitment before reporting a funded channel.
        return try state.channels.filter {
            $0.fundingTxid != nil && $0.signedCommitment != nil && $0.phase != .closed
        }.map { channel in
            let view = try channel.view(localOwner: true, number: channel.localNumber)
            return ChannelBalance(id: channel.id, localMsat: view.localMsat, remoteMsat: view.remoteMsat,
                                  recoveryConfigured: channel.recovery != nil)
        }
    }
    /// Recovery destinations can be prepared before funding. Keep this work
    /// separate from reporting the proposed allocation as an owned balance.
    public func channelsNeedingRecoveryConfiguration() throws -> [Data] {
        try healthy()
        return state.channels.filter { $0.recovery == nil && $0.phase != .closed }.map(\.id)
    }
}
