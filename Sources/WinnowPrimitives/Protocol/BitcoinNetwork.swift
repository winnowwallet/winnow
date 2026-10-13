import Foundation

/// Bitcoin network identifier: mainnet, the public default signet (BIP325),
/// and regtest for a node on the same machine.
public enum BitcoinNetwork: String, Sendable, CaseIterable {
    case mainnet
    case signet
    /// A private chain on one machine, mined by RPC: what an end-to-end
    /// suite runs against. Never dialled from seeds; peers come from
    /// `PeerPool(manualPeers:)`. It begins at zero wherever it runs, so it
    /// ships no checkpoint.
    case regtest
}

extension Data {
    /// Interprets a display-order (big-endian) hex hash as internal byte order.
    package init(displayHex: String) {
        var bytes = Data()
        bytes.reserveCapacity(displayHex.count / 2)
        var index = displayHex.startIndex
        while index < displayHex.endIndex {
            let next = displayHex.index(index, offsetBy: 2)
            bytes.append(UInt8(displayHex[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bytes.reversed())
    }

    /// Internal-order hash rendered as display-order hex.
    public var displayHex: String {
        reversed().map { String(format: "%02x", $0) }.joined()
    }
}
