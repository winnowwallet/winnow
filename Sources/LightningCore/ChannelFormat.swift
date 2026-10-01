import Foundation
import WalletCore

/// A negotiated commitment format is fixed for the lifetime of a funded channel.
/// Missing persisted format fields decode as the pre-anchor static-remotekey format.
public enum ChannelFormat: String, Sendable, Codable {
    case staticRemoteKey
    case anchors

    public var hasAnchors: Bool { self == .anchors }
    public var commitmentWeight: UInt64 { hasAnchors ? 1124 : 724 }
    public var anchorReserveSat: UInt64 { hasAnchors ? 660 : 0 }
    public var htlcSequence: UInt32 { hasAnchors ? 1 : 0 }
    public var htlcSighash: SighashBIP143.HashType { hasAnchors ? .singleAnyoneCanPay : .all }
    var features: LightningFeatures {
        LightningFeatures(bytes: hasAnchors ? Data([0x40, 0x10, 0]) : Data([0x10, 0]))
    }
    init(features: LightningFeatures) throws {
        switch features.bits {
        case [12]: self = .staticRemoteKey
        case [12, 22]: self = .anchors
        default: throw LightningError.invalidMessage
        }
    }
    /// A channel_type is a commitment format plus options that do not change
    /// the commitment transactions.
    static func negotiated(_ features: LightningFeatures) throws -> (format: ChannelFormat, options: ChannelOptions) {
        let options = ChannelOptions(bits: features.bits)
        let format = try ChannelFormat(features: LightningFeatures(bits: features.bits.subtracting(ChannelOptions.all.bits)))
        return (format, options)
    }
}

/// channel_type options: option_scid_alias (46) keeps the real short channel
/// id private; option_zeroconf (50) lets the channel work before its funding
/// confirms. Winnow grants zero-conf only for a channel it bought.
public struct ChannelOptions: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let scidAlias = ChannelOptions(rawValue: 1)
    public static let zeroConf = ChannelOptions(rawValue: 2)
    static let all: ChannelOptions = [.scidAlias, .zeroConf]
    init(bits: Set<Int>) {
        self = ChannelOptions(rawValue: (bits.contains(46) ? 1 : 0) | (bits.contains(50) ? 2 : 0))
    }
    var bits: Set<Int> { Set([contains(.scidAlias) ? 46 : nil, contains(.zeroConf) ? 50 : nil].compactMap { $0 }) }
}
