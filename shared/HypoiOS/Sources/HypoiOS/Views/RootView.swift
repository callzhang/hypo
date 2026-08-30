import SwiftUI
import UIKit
import HypoCore

public struct RootView: View {
    private let context: HypoiOSContext
    @StateObject private var historyViewModel: HistoryListViewModel
    @StateObject private var pairingViewModel: RemotePairingViewModel

    public init(context: HypoiOSContext, historyStore: HistoryStore) {
        self.context = context
        _historyViewModel = StateObject(wrappedValue: HistoryListViewModel(store: historyStore))
        _pairingViewModel = StateObject(wrappedValue: RemotePairingViewModel(
            identity: context.identity
        ))
    }

    public var body: some View {
        TabView {
            HistoryListView(viewModel: historyViewModel)
                .tabItem { Label("History", systemImage: "list.bullet") }

            PairingView(viewModel: pairingViewModel, relayHint: nil)
                .tabItem { Label("Pair", systemImage: "link") }

            SettingsView(
                deviceName: context.identity.deviceName,
                deviceId: context.identity.deviceIdString
            )
            .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
