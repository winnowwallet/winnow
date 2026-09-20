import SwiftUI
import WalletCore

/// Stage edits until Apply so incomplete addresses never disrupt live peers.
struct PeerGatewaysSection: View {
    @Environment(AppModel.self) private var model
    @State private var mode = PeerGatewaySettings.Mode.automatic
    @State private var networks: Set<PeerNetwork> = [.clearnet]
    @State private var torAddress = ""
    @State private var i2pAddress = ""
    @State private var error: String?
    @State private var applying = false
    @State private var loaded = false

    var body: some View {
        Section {
            Picker("Gateway routing", selection: $mode) {
                Text("Automatic").tag(PeerGatewaySettings.Mode.automatic)
                Text("Direct only").tag(PeerGatewaySettings.Mode.direct)
                Text("Manual").tag(PeerGatewaySettings.Mode.manual)
            }
            .accessibilityIdentifier("gatewayRoutingMode")
            if mode == .manual {
                ForEach(PeerNetwork.allCases, id: \.self) { network in
                    Toggle(network.rawValue == "i2p" ? "I2P peers" : "\(network.rawValue.capitalized) peers", isOn: Binding(
                        get: { networks.contains(network) },
                        set: { if $0 { networks.insert(network) } else { networks.remove(network) } }
                    ))
                    .accessibilityIdentifier("peerType_\(network.rawValue)")
                }
                if networks.contains(.tor) {
                    TextField("Tor SOCKS gateway — host:port", text: $torAddress)
                        .accessibilityIdentifier("torGatewayAddress")
                }
                if networks.contains(.i2p) {
                    TextField("I2P SOCKS gateway — host:port", text: $i2pAddress)
                        .accessibilityIdentifier("i2pGatewayAddress")
                }
            }
            Button(applying ? "Applying…" : "Apply routing") {
                Task {
                    applying = true
                    defer { applying = false }
                    do {
                        var manual = model.gatewaySettings.manual
                        if mode == .manual {
                            manual = .init(networks: networks,
                                torProxy: networks.contains(.tor) ? try PeerGatewayConfiguration.parseProxy(torAddress) : nil,
                                i2pProxy: networks.contains(.i2p) ? try PeerGatewayConfiguration.parseProxy(i2pAddress) : nil)
                        }
                        try await model.setPeerGatewaySettings(.init(mode: mode, manual: manual))
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
            }
            .accessibilityIdentifier("applyPeerRouting")
            if let error { Text(error).foregroundStyle(.red) }
            if model.discoveringGateways {
                ProgressView("Checking Tailscale gateways…")
            } else {
                if let tor = model.activePeerGateways.torProxy { LabeledContent("Active Tor gateway", value: address(tor)) }
                if let i2p = model.activePeerGateways.i2pProxy { LabeledContent("Active I2P gateway", value: address(i2p)) }
                if model.activePeerGateways.networks == [.clearnet] { Text("Using clearnet peers.").foregroundStyle(.secondary) }
                if !model.activePeerGateways.isValid { Text("Gateway settings are invalid. Networking is offline.").foregroundStyle(.red) }
            }
            Button("Check gateways and reconnect") { Task { await model.reconnect() } }
                .disabled(model.discoveringGateways)
                .accessibilityIdentifier("checkPeerGateways")
        } header: {
            Text("Peer networks")
        } footer: {
            Text("Automatic uses clearnet plus available Tailscale gateways, in both simple and advanced mode. Connect Tailscale first; discovery checks winnow-tor-gateway:9050 and winnow-i2p-gateway:4447 on launch, foregrounding, and reconnect. Manual settings stay in effect in simple mode. Tor and I2P peers always use their gateway. Peer-list downloads and explorer requests use clearnet when selected, Tor otherwise, and are unavailable with I2P alone. A SOCKS check does not guarantee overlay connectivity.")
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .disabled(applying)
        .onAppear {
            // Form rows appear lazily, including new proxy fields after a
            // toggle. Reloading here would discard the staged selection.
            guard !loaded else { return }
            loaded = true
            mode = model.gatewaySettings.mode
            networks = model.gatewaySettings.manual.networks
            torAddress = model.gatewaySettings.manual.torProxy.map(address) ?? ""
            i2pAddress = model.gatewaySettings.manual.i2pProxy.map(address) ?? ""
        }
    }

    private func address(_ endpoint: PeerEndpoint) -> String {
        endpoint.host.contains(":") ? "[\(endpoint.host)]:\(endpoint.port)" : endpoint.description
    }
}
