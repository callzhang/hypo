import Foundation
import Testing
@testable import HypoCore

/// Renaming has to reach the network, not just the settings screen.
#if os(macOS)
@MainActor
struct DeviceRenameAdvertisementTests {
    @Test
    func testRepublishesUnderTheNewName() async throws {
        let publisher = MockBonjourPublisher()
        let manager = makeManager(publisher: publisher)
        defer { Task { await manager.deactivateLanServices() } }
        await manager.ensureLanDiscoveryActive()
        // Advertising settles asynchronously, and it publishes under the identity's
        // name rather than the configured placeholder. Snapshot after it lands or
        // the comparison is against a value that was about to change anyway.
        _ = await waitUntil { await MainActor.run { publisher.currentConfiguration != nil } }

        let startsBefore = publisher.startCount
        let kept = manager.renameDevice(to: "Studio Mac")

        #expect(kept == "Studio Mac")
        // Re-published, not updated: the service name is fixed at publish time, so
        // a peer browsing would otherwise keep seeing the old one.
        #expect(publisher.startCount == startsBefore + 1)
        #expect(publisher.currentConfiguration?.serviceName == "Studio Mac")
    }

    @MainActor
    private func makeManager(publisher: MockBonjourPublisher) -> TransportManager {
        TransportManager(
            provider: MockTransportProvider(),
            browser: BonjourBrowser(driver: MockBonjourDriver()),
            publisher: publisher,
            discoveryCache: InMemoryLanDiscoveryCache(),
            lanConfiguration: BonjourPublisher.Configuration(
                serviceName: "local-device",
                port: 0,
                version: "1.0",
                fingerprint: "fingerprint",
                protocols: ["ws+tls"]
            ),
            webSocketServer: makeWebSocketServer(),
            defaults: UserDefaults(suiteName: "rename-advert-\(UUID().uuidString)")!,
            notificationController: MockNotificationController(),
            clipboard: RecordingClipboard(),
            autoStartLanServices: false
        )
    }
}
#endif
