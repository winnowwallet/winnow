import Foundation

/// BOLT 1 warnings and errors share an encoding, but only errors are fatal.
/// Provider text is untrusted: never display control characters or unbounded data.
struct LightningPeerNotice: LocalizedError, CustomStringConvertible, Sendable {
    let channelID: Data
    let isError: Bool
    let detail: String

    init(_ message: LightningWire.Message) throws {
        guard [1, 17].contains(message.type) else { throw LightningError.invalidMessage }
        var reader = LightningWire.Reader(message.payload)
        channelID = try reader.take(32)
        let bytes = try reader.take(Int(reader.u16()))
        isError = message.type == 17
        detail = bytes.allSatisfy { (32...126).contains($0) }
            ? String(decoding: bytes.prefix(240), as: UTF8.self) : ""
        // BOLT 1 permits ignoring trailing extensions to known messages.
    }

    var description: String {
        let prefix = isError ? "Provider error" : "Provider warning"
        return detail.isEmpty ? prefix : "\(prefix): \(detail)"
    }
    var errorDescription: String? { description }
}

extension LightningEngine {
    func recognizesNotice(_ notice: LightningPeerNotice, peer: Data) -> Bool {
        notice.channelID == Data(repeating: 0, count: 32) || state.channels.contains {
            $0.peer == peer && ($0.id == notice.channelID || $0.temporaryID == notice.channelID)
        }
    }
    /// A declined initial request has released no funding signature. Retain
    /// its history, but stop replaying open_channel on every reconnection.
    /// An abandoned inbound negotiation is closed too, and its purchase freed.
    /// Returns whether the error concerned only inbound unsigned negotiations,
    /// which a provider may abandon and retry without ending the connection.
    @discardableResult
    func rejectOpening(_ notice: LightningPeerNotice, peer: Data) throws -> Bool {
        try healthy()
        guard notice.isError else { return false }
        let global = notice.channelID == Data(repeating: 0, count: 32)
        let unsigned = state.channels.filter { channel in
            channel.peer == peer && (global || channel.id == notice.channelID || channel.temporaryID == notice.channelID)
                && Self.unsignedNegotiation(channel)
        }
        guard !unsigned.isEmpty else { return false }
        var next = state
        for channel in unsigned { Self.close(unsigned: channel, in: &next) }
        Self.releasePurchases(boundTo: unsigned, in: &next)
        try persist(next)
        return !global && unsigned.allSatisfy { !$0.isFunder }
    }
    private static func unsignedNegotiation(_ channel: ChannelState) -> Bool {
        let opening = channel.isFunder && channel.phase == .opening
        let accepted = !channel.isFunder && channel.phase == .accepted
        return (opening || accepted) && channel.fundingTxid == nil && channel.fundingTransaction == nil && channel.signedCommitment == nil
    }
}
