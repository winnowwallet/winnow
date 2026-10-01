import Foundation
import LightningCore
import P256K
import WalletCore

/// Explicit configuration for the wallet's selected Lightning network/path.
/// Imported values are validated before review and sealed when accepted.
struct LightningProfile: Codable, Equatable, Sendable {
    struct Route: Codable, Equatable, Sendable {
        let introduction: String
        let shortChannelID: UInt64
        let baseMsat: UInt32
        let proportionalMillionths: UInt32
        let expiryDelta: UInt16
    }
    struct Receive: Codable, Equatable, Sendable {
        let serverPath: String
        let inboundShortChannelID: UInt64
        let baseMsat: UInt32
        let proportionalMillionths: UInt32
        let expiryDelta: UInt16
        let maximumMsat: UInt64
    }
    let network: String
    let name: String
    let peer: String
    let host: String
    let port: UInt16
    let route: Route?
    let receive: Receive?
    var liquidityProvider: String? = nil
    /// A test-network provider serving LSPS2; built-in providers say so themselves.
    var jit: Bool? = nil

    var supportsJIT: Bool { jit == true || LightningProviders.provider(self)?.jit == true }

    var peerKey: Data { Data(hex: peer)! } // validated on every import and load
    var endpoint: String { "\(host):\(port)" }

    static func parse(_ text: String, network: BitcoinNetwork? = nil) throws -> Self {
        guard text.utf8.count <= 32_768 else { throw LightningError.invalidMessage }
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        try value.validate(network: network)
        return value
    }
    func validate(network expected: BitcoinNetwork? = nil) throws {
        guard BitcoinNetwork(rawValue: network) != nil, expected == nil || expected?.rawValue == network,
              !name.isEmpty, name.utf8.count <= 80,
              !host.isEmpty, host.utf8.count <= 253, port > 0,
              host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:").contains($0) }),
              let key = Data(hex: peer), key.count == 33 else { throw LightningError.invalidMessage }
        _ = try P256K.Signing.PublicKey(dataRepresentation: key, format: .compressed)
        if let liquidityProvider {
            guard let provider = LightningProviders.available(network: .mainnet).first(where: { $0.id == liquidityProvider }),
                  network == "mainnet", peer == provider.peer, host == provider.host, port == provider.port else { throw LightningError.invalidMessage }
        }
        _ = try paymentRoute()
        if let receive { _ = try receiveConfiguration(id: Data(repeating: 0, count: 32), receive: receive) }
    }
    func paymentRoute() throws -> AsyncPaymentRoute? {
        guard let route else { return nil }
        guard let peer = Data(hex: peer), let introduction = Data(hex: route.introduction), route.shortChannelID > 0 else {
            throw LightningError.invalidMessage
        }
        return try AsyncPaymentRoute(holdingPeer: peer, introduction: introduction, shortChannelID: route.shortChannelID,
            baseMsat: route.baseMsat, proportionalMillionths: route.proportionalMillionths, expiryDelta: route.expiryDelta)
    }
    func receiveConfiguration(id: Data, receive: Receive) throws -> LightningEngine.ReceiveOfferConfiguration {
        guard let raw = Data(hex: receive.serverPath), receive.inboundShortChannelID > 0,
              receive.maximumMsat > 0, receive.maximumMsat <= 16_777_215_000,
              (18...2016).contains(receive.expiryDelta) else { throw LightningError.invalidMessage }
        let paths = try BlindedPath.decodeList(raw)
        guard paths.count == 1, case .node(let introduction) = paths[0].introduction,
              introduction == peerKey else { throw LightningError.invalidMessage }
        return .init(id: id, provider: peerKey, serverPath: paths[0], inboundShortChannelID: receive.inboundShortChannelID,
                     baseMsat: receive.baseMsat, proportionalMillionths: receive.proportionalMillionths,
                     expiryDelta: receive.expiryDelta, maximumMsat: receive.maximumMsat)
    }
}
