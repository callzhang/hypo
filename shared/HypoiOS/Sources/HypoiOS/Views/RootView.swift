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
    @StateObject private var claimViewModel: ClaimPairingCodeViewModel
    @StateObject private var lanViewModel: LanPairingViewModel
    @State private var showingSettings = false

    public init(context: HypoiOSContext) {
        self.context = context
        // The context already owns this one, wired to the transport manager and
        // registered as the receiver. Building a second here would show a list
        // that never receives anything.
        _historyViewModel = StateObject(wrappedValue: context.historyViewModel)
        let manager = context.transportManager
        _pairingViewModel = StateObject(wrappedValue: RemotePairingViewModel(
            identity: context.identity,
            onDevicePaired: { device in manager.registerPairedDevice(device) }
        ))
        _claimViewModel = StateObject(wrappedValue: ClaimPairingCodeViewModel(
            identity: context.identity,
            onDevicePaired: { device in manager.registerPairedDevice(device) }
        ))
        let identity = context.identity
        let coordinator = LanPairingCoordinator(
            deviceId: identity.deviceIdString,
            deviceName: identity.deviceName
        )
        let keyProvider = KeychainDeviceKeyProvider()
        _lanViewModel = StateObject(wrappedValue: LanPairingViewModel(
            discoveredPeers: { manager.lanDiscoveredPeers() },
            pairedDeviceIds: { Set(manager.pairedDevices.map { $0.id.lowercased() }) },
            pairWithPeer: { peer in
                let result = try await coordinator.pair(with: peer)
                // Key first: a device registered without one is worse than one
                // not registered yet — everything it sends would be undecryptable.
                try keyProvider.store(key: result.sharedKey, for: result.peer.id)
                await MainActor.run { manager.registerPairedDevice(result.peer) }
                return result.peer
            }
        ))
    }

    public var body: some View {
        NavigationStack {
            HistoryListView(
                viewModel: historyViewModel,
                transportManager: context.transportManager,
                localDeviceId: context.identity.deviceIdString,
                onOpenSettings: { showingSettings = true }
            )
            // The same trigger Android uses in onResume: neither platform can
            // watch the clipboard from the background, so both check on the way
            // back to the foreground.
            //
            // On the notification rather than scenePhase: scenePhase does not
            // publish the initial .active, and a background-then-foreground
            // round trip did not reliably produce a change SwiftUI observed —
            // the send simply never ran.
            // Android checks the clipboard in onResume; iOS cannot read it
            // without asking permission, so it checks whether there is
            // anything — which is free — and offers a button if so.
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )) { _ in
                historyViewModel.refreshClipboardOffer()
            }
            .navigationDestination(isPresented: $showingSettings) {
                SettingsView(
                    context: context,
                    pairingViewModel: pairingViewModel,
                    claimViewModel: claimViewModel,
                    lanViewModel: lanViewModel
                )
            }
        }
    }
}
