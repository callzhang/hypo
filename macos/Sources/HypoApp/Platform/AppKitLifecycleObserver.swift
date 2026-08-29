import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// macOS implementation of AppLifecycleObserving, replacing the private
/// ApplicationLifecycleObserver that used to live inside TransportManager.
public final class AppKitLifecycleObserver: AppLifecycleObserving {
    private var tokens: [NSObjectProtocol] = []

    public init() {}

    public func start(
        onActivate: @escaping @Sendable () -> Void,
        onDeactivate: @escaping @Sendable () -> Void,
        onTerminate: @escaping @Sendable () -> Void
    ) {
        #if canImport(AppKit)
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            onActivate()
        })
        tokens.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            onDeactivate()
        })
        tokens.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            onTerminate()
        })
        #endif
    }

    public func stop() {
        let center = NotificationCenter.default
        tokens.forEach { center.removeObserver($0) }
        tokens.removeAll()
    }

    deinit {
        stop()
    }
}
