import SwiftUI
import WalletCore

/// Edits are staged until Apply so incomplete addresses never disrupt live peers.
struct PeerGatewaysSection: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = false
    @State private var networks: Set<OverlayNetwork> = [.clearnet]
    @State private var torAddress = ""
    @State private var i2pAddress = ""
    @State private var error: String?
    @State private var applying = false

    var body: some View {
        Section {
            Toggle("Use external gateways", isOn: $enabled)
                .accessibilityIdentifier("externalGatewaysToggle")
            if enabled {
                ForEach(OverlayNetwork.allCases, id: \.self) { network in
                    Toggle(label(network), isOn: Binding(
                        get: { networks.contains(network) },
                        set: { if $0 { networks.insert(network) } else { networks.remove(network) } }
                    ))
                    .accessibilityIdentifier("peerType_\(network.rawValue)")
                }
                if networks.contains(.tor) {
                    VStack(alignment: .leading) {
                        Text("Tor gateway").font(.caption).foregroundStyle(.secondary)
                        TextField("SOCKS5 host:port", text: $torAddress)
                            .accessibilityIdentifier("torGatewayAddress")
                    }
                }
                if networks.contains(.i2p) {
                    VStack(alignment: .leading) {
                        Text("I2P gateway").font(.caption).foregroundStyle(.secondary)
                        TextField("SOCKS5 host:port", text: $i2pAddress)
                            .accessibilityIdentifier("i2pGatewayAddress")
                    }
                }
                Text("Choose at least one peer type. Selected types are eligible; connected peers depend on availability. Add I2P peers manually if the peer list has none.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(applying ? "Applying…" : "Apply peer routing") {
                Task {
                    applying = true
                    defer { applying = false }
                    do {
                        let config = enabled ? PeerGatewayConfiguration(
                            networks: networks,
                            torProxy: networks.contains(.tor) ? try AppModel.parsePeer(torAddress) : nil,
                            i2pProxy: networks.contains(.i2p) ? try AppModel.parsePeer(i2pAddress) : nil
                        ) : nil
                        try await model.setPeerGateways(config)
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            .disabled(applying)
            .accessibilityIdentifier("applyPeerRouting")
            if let error { Text(error).foregroundStyle(.red) }
            if model.tor.gateways != nil { Text("External gateway routing is active.").font(.caption) }
        } header: { Text("Peer networks") } footer: {
            Text("Connect this device to Tailscale before using tailnet gateways. Clearnet peers connect directly; Tor and I2P peers use their respective SOCKS5 gateway without direct fallback. External mode does not start built-in Tor. Peer-list downloads and explorer lookups use direct connections when clearnet is selected, Tor when only Tor and/or I2P are selected, and are unavailable with I2P alone.")
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .disabled(applying)
        .onAppear {
            enabled = model.tor.gateways != nil
            if let config = model.tor.gateways {
                networks = config.networks
                torAddress = config.torProxy?.description ?? ""
                i2pAddress = config.i2pProxy?.description ?? ""
            }
        }
    }

    private func label(_ network: OverlayNetwork) -> String {
        switch network {
        case .clearnet: "Clearnet peers"
        case .tor: "Tor peers"
        case .i2p: "I2P peers"
        }
    }
}
