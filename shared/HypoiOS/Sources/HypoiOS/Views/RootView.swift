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

    /// Two tabs, matching Android: History and Settings. Pairing is reached
    /// from the devices section of Settings, not from a tab of its own —
    /// it is something you do occasionally, not somewhere you live.
    public var body: some View {
        TabView {
            HistoryListView(viewModel: historyViewModel)
                .tabItem { Label("History", systemImage: "list.bullet") }

            SettingsView(context: context, pairingViewModel: pairingViewModel)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
