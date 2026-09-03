import Foundation
import UIKit
import Testing
import HypoCore
@testable import HypoiOS

@Suite("UIKitLifecycleObserver")
struct UIKitLifecycleObserverTests {
    @Test("posting the foreground notification fires onActivate")
    @MainActor
    func activateFires() async {
        let observer = UIKitLifecycleObserver()
        let activated = Locked(false)

        observer.start(
            onActivate: { activated.withLock { $0 = true } },
            onDeactivate: {},
            onTerminate: {}
        )
        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        let fired = await waitUntil(timeout: .seconds(2)) { activated.withLock { $0 } }
        #expect(fired)
        observer.stop()
    }

    @Test("stop removes the observers")
    @MainActor
    func stopDetaches() async {
        let observer = UIKitLifecycleObserver()
        let count = Locked(0)

        observer.start(
            onActivate: { count.withLock { $0 += 1 } },
            onDeactivate: {},
            onTerminate: {}
        )
        observer.stop()
        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        try? await Task.sleep(for: .milliseconds(200))

        #expect(count.withLock { $0 } == 0)
    }
}
