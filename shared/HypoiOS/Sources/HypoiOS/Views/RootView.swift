import SwiftUI
import UIKit
import HypoCore

public struct RootView: View {
    private let context: HypoiOSContext
    @StateObject private var historyViewModel: HistoryListViewModel
    @StateObject private var pairingViewModel: RemotePairingViewModel

    public init(context: HypoiOSContext) {
        self.context = context
        // The context already owns this one, wired to the transport manager and
        // registered as the receiver. Building a second here would show a list
        // that never receives anything.
        _historyViewModel = StateObject(wrappedValue: context.historyViewModel)
        _pairingViewModel = StateObject(wrappedValue: RemotePairingViewModel(
            identity: context.identity
        ))
    }

    public var body: some View {
        TabView {
            HistoryListView(viewModel: historyViewModel)
                .tabItem { Label("History", systemImage: "list.bullet") }

            // pairingParameters() is where macOS gets this too. Passing nil —
            // which the plan called for — makes RemotePairingViewModel fail
            // immediately with "Relay configuration missing", so pairing could
            // never have succeeded.
            PairingView(
                viewModel: pairingViewModel,
                relayHint: context.transportManager.pairingParameters().relayHint
            )
                .tabItem { Label("Pair", systemImage: "link") }

            SettingsView(
                deviceName: context.identity.deviceName,
                deviceId: context.identity.deviceIdString
            )
            .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
