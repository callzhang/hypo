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
    public let storageLocations: StorageLocations
    public let clipboard: UIKitClipboard
    public let lifecycleObserver: UIKitLifecycleObserver
    public let notificationScheduler: UserNotificationScheduler
    public let webSocketServer: LanWebSocketServer
    public let transportManager: TransportManager

    public init(notificationScheduler: UserNotificationScheduler = UserNotificationScheduler()) {
        // ProcessInfo.processInfo.hostName returns "localhost" on real iOS
        // hardware, so the core's fallback is useless here. Supply the device's
        // own name instead.
        self.identity = DeviceIdentity(hostname: UIDevice.current.name)

        self.storageLocations = AppContainerStorageLocations()
        self.clipboard = UIKitClipboard()
        self.lifecycleObserver = UIKitLifecycleObserver()
        self.notificationScheduler = notificationScheduler

        // Constructed because TransportManager requires it, and never started.
        // Constructing does not bind a listener; only start(port:) does, and
        // .clientOnly below is what guarantees nobody calls it.
        self.webSocketServer = LanWebSocketServer(localDeviceId: identity.deviceIdString)

        let provider = DefaultTransportProvider(server: webSocketServer)

        self.transportManager = TransportManager(
            provider: provider,
            webSocketServer: webSocketServer,
            notificationController: notificationScheduler,
            clipboard: clipboard,
            lifecycleObserver: lifecycleObserver,
            lanRole: .clientOnly
        )
    }
}
