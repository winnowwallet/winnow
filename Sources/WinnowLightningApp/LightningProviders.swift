import Foundation
import WalletCore

/// Public mainnet peers. Test networks retain their own explicit profiles.
/// A provider choice opens no channels and authorizes no payment.
enum LightningProviders {
    struct Provider: Identifiable, Sendable {
        let id, name, peer, host: String
        let port: UInt16
        let website: URL
        var api: URL? = nil
        var token = ""
        var manualSetup = false
        /// LSPS2: a just-in-time channel opens with the first payment.
        var jit = false
        var profile: LightningProfile {
            LightningProfile(network: "mainnet", name: name, peer: peer, host: host, port: port,
                route: nil, receive: nil, liquidityProvider: id)
        }
    }
    static let mainnet: [Provider] = [
        .init(id: "megalith-lsps2", name: "Megalith Instant", peer: "034066e29e402d9cf55af1ae1026cc5adf92eed1e0e421785442f53717ad1453b0",
            host: "64.23.159.177", port: 9735,
            website: URL(string: "https://docs.megalithic.me/lightning-services/lsps2-get-a-just-in-time-channel-for-mobile-clients/")!,
            token: "Winnow", jit: true),
        .init(id: "olympus", name: "Olympus by ZEUS", peer: "031b301307574bbe9b9ac7b79cbe1700e31e544513eae0b5d7497483083f99e581",
            host: "45.79.192.236", port: 9735, website: URL(string: "https://docs.zeusln.app/lsp/")!),
        .init(id: "megalith", name: "Megalith", peer: "038a9e56512ec98da2b5789761f7af8f280baf98a09282360cd6ff1381b5e889bf",
            host: "64.23.162.51", port: 9735, website: URL(string: "https://docs.megalithic.me/lightning-services/lsp1-get-inbound-liquidity-for-mobile-clients/")!,
            api: URL(string: "https://megalithic.me/api/lsps1/v1/"), token: "Winnow"),
        .init(id: "lnserver", name: "LNServer Wave", peer: "02b4552a7a85274e4da01a7c71ca57407181752e8568b31d51f13c111a2941dce3",
            host: "178.156.167.202", port: 48049, website: URL(string: "https://lnserver.com/")!, manualSetup: true)
    ]
    static func available(network: BitcoinNetwork) -> [Provider] { network == .mainnet ? mainnet : [] }
    static func recommended(network: BitcoinNetwork) -> LightningProfile? { available(network: network).first?.profile }
    static func provider(_ profile: LightningProfile?) -> Provider? { mainnet.first { $0.id == profile?.liquidityProvider } }
}
