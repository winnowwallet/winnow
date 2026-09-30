import Foundation
import P256K
import WalletCore

/// Standard single-part invoices, sharing Winnow's Bech32 and bit conversion.
/// The node key signs the exact network, amount, secret and private route.
public enum Bolt11Invoice {
    public struct Route: Sendable, Equatable, Codable {
        public let peer: Data
        public let shortChannelID: UInt64
        public let baseMsat: UInt32, proportionalMillionths: UInt32
        public let expiryDelta: UInt16
        public init(peer: Data, shortChannelID: UInt64, baseMsat: UInt32,
                    proportionalMillionths: UInt32, expiryDelta: UInt16) {
            self.peer = peer; self.shortChannelID = shortChannelID; self.baseMsat = baseMsat
            self.proportionalMillionths = proportionalMillionths; self.expiryDelta = expiryDelta
        }
        var bytes: Data {
            var writer = LightningWire.Writer(); writer.append(peer); writer.u64(shortChannelID)
            writer.u32(baseMsat); writer.u32(proportionalMillionths); writer.u16(expiryDelta)
            return writer.data
        }
    }
    public static func prefix(network: BitcoinNetwork) -> String {
        switch network { case .mainnet: "lnbc"; case .signet: "lntbs"; case .regtest: "lnbcrt" }
    }
    public static func encode(network: BitcoinNetwork, amountMsat: UInt64, hash: Data, secret: Data,
                              nodeSecret: Data, route: Route?, timestamp: UInt64,
                              expirySeconds: UInt64 = 3600) throws -> String {
        guard amountMsat > 0, amountMsat <= 16_777_215_000, hash.count == 32, secret.count == 32,
              timestamp < 1 << 35, (60...86_400).contains(expirySeconds) else { throw LightningError.invalidAmount }
        let hrp = prefix(network: network) + String(amountMsat * 10) + "p"
        var words = integer(timestamp, count: 7)
        words += try field(1, bytes: hash) + field(16, bytes: secret)
        words += try field(13, bytes: Data("Winnow Lightning payment".utf8))
        words += field(6, words: integer(expirySeconds)) + field(24, words: integer(18))
        // Required payment_secret and optional var_onion_optin; no MPP advertised.
        words += field(5, words: integer((1 << 14) | (1 << 9)))
        if let route {
            _ = try ChannelKeys.point(route.peer)
            guard route.shortChannelID > 0, route.expiryDelta > 0 else { throw LightningError.invalidMessage }
            words += try field(3, bytes: route.bytes)
        }
        let digest = HashDigest(Array(ChannelKeys.hash(Data(hrp.utf8) + Data(try SegwitAddress.convertBits(words, from: 5, to: 8, pad: true)))))
        let signature = try P256K.Recovery.PrivateKey(dataRepresentation: nodeSecret).signature(for: digest).compactRepresentation
        words += try SegwitAddress.convertBits(Array(signature.signature) + [UInt8(signature.recoveryId)], from: 8, to: 5, pad: true)
        return try Bech32.encode(hrp: hrp, data: words, encoding: .bech32, maxLength: 4096)
    }
    static func integer(_ value: UInt64, count: Int? = nil) -> [UInt8] {
        var value = value, words: [UInt8] = []
        repeat { words.insert(UInt8(value & 31), at: 0); value >>= 5 } while value > 0
        if let count { words.insert(contentsOf: repeatElement(0, count: max(0, count - words.count)), at: 0) }
        return words
    }
    static func field(_ type: UInt8, bytes: Data) throws -> [UInt8] {
        field(type, words: try SegwitAddress.convertBits(Array(bytes), from: 8, to: 5, pad: true))
    }
    static func field(_ type: UInt8, words: [UInt8]) -> [UInt8] {
        [type, UInt8(words.count >> 5), UInt8(words.count & 31)] + words
    }
}
