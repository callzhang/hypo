import Foundation
import Testing
@testable import HypoCore

/// The Nearby pairing list reads `discoveredLanPeers` and hides peers already
/// paired, so both have to track discovery as it happens rather than at the
/// moment someone opens the sheet.
#if os(macOS)
struct LanPeerListingTests {
    @Test @MainActor
    func testPublishedPeersFollowDiscoveryEvents() async throws {
        let driver = MockBonjourDriver()
        let manager = makeManager(driver: driver)
        defer { Task { await manager.deactivateLanServices() } }
        await manager.ensureLanDiscoveryActive()

        #expect(manager.discoveredLanPeers.isEmpty)

        driver.emit(.resolved(makeRecord(serviceName: "peer-one", deviceId: "aaaa1111")))
        try await Task.sleep(nanoseconds: 5_000_000)
        #expect(manager.discoveredLanPeers.map(\.serviceName) == ["peer-one"])

        driver.emit(.removed("peer-one"))
        try await Task.sleep(nanoseconds: 5_000_000)
        #expect(manager.discoveredLanPeers.isEmpty)
    }

    /// Peers restored from the discovery cache have to be published at once. They
    /// are already known, so no discovery event is coming to reveal them, and the
    /// pairing list would sit empty next to a device that is plainly on the network.
    @Test @MainActor
    func testCachedPeersArePublishedBeforeAnyDiscoveryEvent() async throws {
        let cache = InMemoryLanDiscoveryCache()
        cache.peerStorage["peer-one"] = DiscoveredPeer(
            serviceName: "peer-one",
            endpoint: LanEndpoint(
                host: "peer.local",
                port: 7010,
                deviceId: "aaaa1111",
                deviceName: "Peer One",
                fingerprint: nil,
                metadata: ["device_id": "aaaa1111", "pub_key": "cHVibGljLWtleQ=="]
            ),
            lastSeen: Date(timeIntervalSince1970: 1_000)
        )

        let manager = makeManager(driver: MockBonjourDriver(), cache: cache)
        defer { Task { await manager.deactivateLanServices() } }

        #expect(manager.discoveredLanPeers.map(\.serviceName) == ["peer-one"])
    }

    @Test @MainActor
    func testPairedPeersAreRecognisedRegardlessOfIdCasing() async throws {
        let driver = MockBonjourDriver()
        let manager = makeManager(driver: driver)
        defer { Task { await manager.deactivateLanServices() } }
        await manager.ensureLanDiscoveryActive()

        driver.emit(.resolved(makeRecord(serviceName: "peer-one", deviceId: "AAAA1111")))
        try await Task.sleep(nanoseconds: 5_000_000)
        let peer = try #require(manager.discoveredLanPeers.first)

        #expect(manager.isPaired(peer) == false)

        // Device ids reach us lowercased from some peers and not others, so the
        // check has to be case-insensitive or an already-paired device is offered
        // for pairing a second time.
        manager.registerPairedDevice(
            PairedDevice(id: "aaaa1111", name: "Peer One", platform: "Android", lastSeen: Date(), isOnline: true)
        )
        #expect(manager.isPaired(peer) == true)
    }

    // MARK: - Helpers

    @MainActor
    private func makeManager(driver: MockBonjourDriver, cache: LanDiscoveryCache = InMemoryLanDiscoveryCache()) -> TransportManager {
        TransportManager(
            provider: MockTransportProvider(),
            browser: BonjourBrowser(driver: driver, clock: { Date(timeIntervalSince1970: 1_000) }),
            publisher: MockBonjourPublisher(),
            discoveryCache: cache,
            lanConfiguration: BonjourPublisher.Configuration(
                serviceName: "local-device",
                port: 0,
                version: "1.0",
                fingerprint: "fingerprint",
                protocols: ["ws+tls"]
            ),
            webSocketServer: makeWebSocketServer(),
            defaults: UserDefaults(suiteName: "LanPeerListingTests-\(UUID().uuidString)")!,
            notificationController: MockNotificationController(),
            clipboard: RecordingClipboard(),
            autoStartLanServices: false
        )
    }

    private func makeRecord(serviceName: String, deviceId: String) -> BonjourServiceRecord {
        BonjourServiceRecord(
            serviceName: serviceName,
            host: "peer.local",
            port: 7010,
            txtRecords: [
                "fingerprint_sha256": "abc",
                "protocols": "ws+tls",
                "device_id": deviceId,
                "pub_key": "cHVibGljLWtleQ=="
            ]
        )
    }
}
#endif
