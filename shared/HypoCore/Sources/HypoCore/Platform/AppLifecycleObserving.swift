import Foundation

/// Observes host-application lifecycle transitions.
///
/// macOS listens to NSApplication notifications; iOS listens to
/// UIApplication ones. The core only needs the three transitions below.
public protocol AppLifecycleObserving: AnyObject {
    func start(
        onActivate: @escaping @Sendable () -> Void,
        onDeactivate: @escaping @Sendable () -> Void,
        onTerminate: @escaping @Sendable () -> Void
    )
    func stop()
}

/// Test double: events are driven explicitly rather than by the system.
public final class ManualAppLifecycleObserver: AppLifecycleObserving {
    private var onActivate: (@Sendable () -> Void)?
    private var onDeactivate: (@Sendable () -> Void)?
    private var onTerminate: (@Sendable () -> Void)?

    public init() {}

    public func start(
        onActivate: @escaping @Sendable () -> Void,
        onDeactivate: @escaping @Sendable () -> Void,
        onTerminate: @escaping @Sendable () -> Void
    ) {
        self.onActivate = onActivate
        self.onDeactivate = onDeactivate
        self.onTerminate = onTerminate
    }

    public func stop() {
        onActivate = nil
        onDeactivate = nil
        onTerminate = nil
    }

    public func simulateActivate() { onActivate?() }
    public func simulateDeactivate() { onDeactivate?() }
    public func simulateTerminate() { onTerminate?() }
}
