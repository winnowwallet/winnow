import SwiftUI
import WalletCore

/// The ready wallet in either mode, under the channel protection banner.
struct LightningReadyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ChannelProtectionBanner()
            // Beginner mode is one screen; Advanced mode is the tab
            // interface. The switch lives in each one's toolbar.
            if model.advancedMode {
                MainTabView()
            } else {
                BeginnerHomeView()
            }
        }
    }
}

/// The Simple home's test-coin tag. Winnow Lightning also runs on regtest,
/// so it names the network rather than assuming signet.
struct LightningNetworkTag: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("\(model.network.rawValue.capitalized) · test coins")
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
            .accessibilityIdentifier("networkTag")
    }
}
