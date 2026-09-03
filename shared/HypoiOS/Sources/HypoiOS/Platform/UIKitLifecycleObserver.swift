import Foundation
import UIKit
import HypoCore

/// iOS implementation of AppLifecycleObserving.
///
/// The iOS equivalents of macOS's NSApplication notifications are
/// didBecomeActive, willResignActive and willTerminate. Note that iOS does
/// not guarantee willTerminate — the system can kill a suspended app without
/// delivering it — so nothing that must happen should depend on it.
public final class UIKitLifecycleObserver: AppLifecycleObserving {
    private var tokens: [NSObjectProtocol] = []

    public init() {}

    public func start(
        onActivate: @escaping @Sendable () -> Void,
        onDeactivate: @escaping @Sendable () -> Void,
        onTerminate: @escaping @Sendable () -> Void
    ) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in onActivate() })
        tokens.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in onDeactivate() })
        tokens.append(center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in onTerminate() })
    }

    public func stop() {
        let center = NotificationCenter.default
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
    }

    deinit { stop() }
}
