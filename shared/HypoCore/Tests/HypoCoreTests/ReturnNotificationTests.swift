import Foundation
import Testing
@testable import HypoCore

/// When a device coming back online is worth interrupting someone for.
///
/// It used to be every time. A phone whose screen sleeps flips online several
/// times an hour, and a notification per flip teaches people to ignore the ones
/// that matter.
#if os(macOS)
@MainActor
struct ReturnNotificationTests {
    @Test
    func testAnnouncesADeviceBackAfterMoreThanADay() async throws {
        let clock = Clock()
        let notifications = MockNotificationController()
        let manager = makeManager(notifications: notifications, clock: clock)
        defer { Task { await manager.deactivateLanServices() } }
        manager.registerPairedDevice(makeDevice(isOnline: true))

        manager.updateDeviceOnlineStatus(deviceId: deviceId, isOnline: false)
        clock.advance(by: TransportManager.returnNotificationThreshold + 60)
        manager.updateDeviceOnlineStatus(deviceId: deviceId, isOnline: true)

        #expect(notifications.statusNotifications.count == 1)
        #expect(notifications.statusNotifications.first?.body.contains("Peer One") == true)
    }

    @Test
    func testSaysNothingForADeviceThatJustFlickered() async throws {
        let clock = Clock()
        let notifications = MockNotificationController()
        let manager = makeManager(notifications: notifications, clock: clock)
        defer { Task { await manager.deactivateLanServices() } }
        manager.registerPairedDevice(makeDevice(isOnline: true))

        // A screen going to sleep and waking up again.
        manager.updateDeviceOnlineStatus(deviceId: deviceId, isOnline: false)
        clock.advance(by: 90)
        manager.updateDeviceOnlineStatus(deviceId: deviceId, isOnline: true)

        #expect(notifications.statusNotifications.isEmpty)
    }

    /// A device stored before this rule existed has no offline stamp. Announcing
    /// it would mean a burst of notifications on the first launch after an update.
    @Test
    func testSaysNothingWhenWeNeverSawItGoOffline() async throws {
        let clock = Clock()
        let notifications = MockNotificationController()
        let manager = makeManager(notifications: notifications, clock: clock)
        defer { Task { await manager.deactivateLanServices() } }
        manager.registerPairedDevice(makeDevice(isOnline: false))

        manager.updateDeviceOnlineStatus(deviceId: deviceId, isOnline: true)

        #expect(notifications.statusNotifications.isEmpty)
    }

    /// The stamp is the moment it went down, not the last time we noticed it was
    /// still down -- otherwise a probe every ten minutes keeps resetting the clock
    /// and the day never elapses.
    @Test
    func testRepeatedOfflineChecksDoNotResetTheClock() async throws {
        let clock = Clock()
        let notifications = MockNotificationController()
        let manager = makeManager(notifications: notifications, clock: clock)
        defer { Task { await manager.deactivateLanServices() } }
        manager.registerPairedDevice(makeDevice(isOnline: true))

        manager.updateDeviceOnlineStatus(deviceId: deviceId, isOnline: false)
        for _ in 0..<5 {
            clock.advance(by: 6 * 60 * 60)
            manager.updateDeviceOnlineStatus(deviceId: deviceId, isOnline: false)
        }
        manager.updateDeviceOnlineStatus(deviceId: deviceId, isOnline: true)

        #expect(notifications.statusNotifications.count == 1)
    }

    // MARK: - Helpers

    private let deviceId = "aaaa1111"

    private func makeDevice(isOnline: Bool) -> PairedDevice {
        PairedDevice(
            id: deviceId,
            name: "Peer One",
            platform: "Android",
            lastSeen: Date(timeIntervalSince1970: 0),
            isOnline: isOnline
        )
    }

    /// A clock the test moves by hand, so a day can pass in a microsecond.
    private final class Clock: @unchecked Sendable {
        private var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
        var provider: @Sendable () -> Date { { self.now } }
    }

    @MainActor
    private func makeManager(notifications: MockNotificationController, clock: Clock) -> TransportManager {
        TransportManager(
            provider: MockTransportProvider(),
            browser: BonjourBrowser(driver: MockBonjourDriver()),
            publisher: MockBonjourPublisher(),
            discoveryCache: InMemoryLanDiscoveryCache(),
            lanConfiguration: BonjourPublisher.Configuration(
                serviceName: "local-device",
                port: 0,
                version: "1.0",
                fingerprint: "fingerprint",
                protocols: ["ws+tls"]
            ),
            dateProvider: clock.provider,
            webSocketServer: makeWebSocketServer(),
            defaults: UserDefaults(suiteName: "return-notice-\(UUID().uuidString)")!,
            notificationController: notifications,
            clipboard: RecordingClipboard(),
            autoStartLanServices: false
        )
    }
}
#endif
