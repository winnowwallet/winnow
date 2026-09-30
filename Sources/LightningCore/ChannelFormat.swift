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
}
