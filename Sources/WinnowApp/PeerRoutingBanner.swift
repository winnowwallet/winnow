import SwiftUI
import WalletCore

/// How this phone reaches Bitcoin peers, as one line a beginner can read.
enum PeerRoutingState: Equatable {
    case checking
    /// Every peer goes through the named overlays; none sees the phone's IP.
    case overlay(tor: Bool, i2p: Bool)
    /// Some peers are direct and some go through a gateway.
    case mixed
    /// Every peer is direct. `fallback` means Automatic found no gateway.
    case direct(fallback: Bool)
    case offline

    static func current(mode: PeerGatewaySettings.Mode, active: PeerGatewayConfiguration,
                        discovering: Bool) -> PeerRoutingState {
        if discovering { return .checking }
        guard active.isValid else { return .offline }
        let tor = active.networks.contains(.tor), i2p = active.networks.contains(.i2p)
        if !active.networks.contains(.clearnet) { return .overlay(tor: tor, i2p: i2p) }
        if tor || i2p { return .mixed }
        return .direct(fallback: mode == .automatic)
    }

    var message: String {
        switch self {
        case .checking: "Checking your Tor and I2P gateways…"
        case let .overlay(tor, i2p):
            "Private: peers reached through \(tor && i2p ? "Tor and I2P" : tor ? "Tor" : "I2P")"
        case .mixed: "Some peers are direct and can see your IP address"
        case .direct(fallback: true):
            "Direct: peers can see your IP address. No Tor or I2P gateway found; connect Tailscale, then return to Winnow."
        case .direct(fallback: false): "Direct: peers can see your IP address"
        case .offline: "Offline: peer routing settings are invalid"
        }
    }

    var symbol: String {
        switch self {
        case .checking: "network"
        case .overlay: "lock.shield.fill"
        case .mixed, .direct: "exclamationmark.triangle.fill"
        case .offline: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .checking: .secondary
        case .overlay: .green
        case .mixed, .direct: .orange
        case .offline: .red
        }
    }
}

/// Simple mode's routing line: green when every peer is behind Tor or I2P,
/// orange when any peer can see the phone's IP address.
struct PeerRoutingBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = PeerRoutingState.current(mode: model.gatewaySettings.mode,
                                             active: model.activePeerGateways,
                                             discovering: model.discoveringGateways)
        Label(state.message, systemImage: state.symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(state.tint.opacity(0.12)))
            .accessibilityIdentifier("peerRoutingBanner")
    }
}
