import Foundation
import UIKit
import HypoCore

/// Builds and owns the iOS app's object graph.
///
/// This is the one place that knows how HypoCore's platform seams are filled on
/// iOS. Everything else takes what it needs from here.
@MainActor
public final class HypoiOSContext {
    public let identity: DeviceIdentity
    public let clipboard: UIKitClipboard
    public let lifecycleObserver: UIKitLifecycleObserver
    public let notificationScheduler: UserNotificationScheduler
    public let webSocketServer: LanWebSocketServer
    public let historyStore: HistoryStore
    public let transportManager: TransportManager
    public let historyViewModel: HistoryListViewModel
    public let deviceKeyProvider: KeychainDeviceKeyProvider

    public init(
        notificationScheduler: UserNotificationScheduler = UserNotificationScheduler(),
        historyStore: HistoryStore = HistoryStore()
    ) {
        // ProcessInfo.processInfo.hostName returns "localhost" on real iOS
        // hardware, so the core's fallback is useless here. Supply the device's
        // own name instead.
        self.identity = DeviceIdentity(hostname: UIDevice.current.name)

        self.clipboard = UIKitClipboard()
        self.lifecycleObserver = UIKitLifecycleObserver()
        self.notificationScheduler = notificationScheduler

        // Constructed because TransportManager requires it, and never started.
        // Constructing does not bind a listener; only start(port:) does, and
        // .clientOnly below is what guarantees nobody calls it.
        self.webSocketServer = LanWebSocketServer(localDeviceId: identity.deviceIdString)

        let provider = DefaultTransportProvider(server: webSocketServer)
        self.historyStore = historyStore

        // historyStore has to be passed here, not attached afterwards. The one
        // branch it guards inside TransportManager also sets the server's
        // local-device-id filter and gives LanSyncTransport a way to resolve
        // discovered peers — which is how this device dials out. Omitting it
        // disables receiving and outbound LAN connections at once, silently.
        self.deviceKeyProvider = KeychainDeviceKeyProvider()

        let manager = TransportManager(
            provider: provider,
            webSocketServer: webSocketServer,
            historyStore: historyStore,
            notificationController: notificationScheduler,
            clipboard: clipboard,
            lifecycleObserver: lifecycleObserver,
            lanRole: .clientOnly
        )
        self.transportManager = manager

        let viewModel = HistoryListViewModel(
            store: historyStore,
            transportManager: manager,
            identity: identity,
            clipboard: clipboard
        )
        self.historyViewModel = viewModel
        manager.setHistoryViewModel(viewModel)
        notificationScheduler.requestAuthorizationIfNeeded()
    }

    /// Forgets a device: its key first, then the device itself.
    ///
    /// The order matters. A device left listed with no key cannot decrypt
    /// anything sent to it, which reads as a broken peer rather than one that
    /// was removed — Android deletes the key first for the same reason.
    ///
    /// Uses the container's own key provider rather than building one on the
    /// spot, so this deletes from the same keychain the app reads.
    @discardableResult
    public func unpair(_ device: PairedDevice) -> Bool {
        var deletedKey = true
        do {
            try deviceKeyProvider.delete(deviceId: device.id)
        } catch {
            // Removing the device is still worth doing: a stale key alone
            // decrypts nothing, but a stale device keeps being dialled.
            deletedKey = false
        }
        transportManager.removePairedDevice(device)
        return deletedKey
    }
}
