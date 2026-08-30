import SwiftUI
import UIKit
import HypoCore

/// One screen, the way Android now works: history is the app, settings is
/// pushed from the gear in its top row, and pairing is pushed from settings.
/// There is no tab bar — Android dropped its bottom navigation, and with only
/// two destinations one of which you visit rarely, it was carrying nothing.
public struct RootView: View {
    private let context: HypoiOSContext
    @StateObject private var historyViewModel: HistoryListViewModel
    @StateObject private var pairingViewModel: RemotePairingViewModel
    @State private var showingSettings = false

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
        NavigationStack {
            HistoryListView(
                viewModel: historyViewModel,
                transportManager: context.transportManager,
                onOpenSettings: { showingSettings = true }
            )
            .navigationDestination(isPresented: $showingSettings) {
                SettingsView(context: context, pairingViewModel: pairingViewModel)
            }
        }
    }
}
