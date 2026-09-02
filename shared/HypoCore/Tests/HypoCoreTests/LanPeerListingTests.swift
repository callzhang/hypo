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
        _ = await waitForPeerCount(1, in: manager)
        #expect(manager.discoveredLanPeers.map(\.serviceName) == ["peer-one"])

        driver.emit(.removed("peer-one"))
        _ = await waitForPeerCount(0, in: manager, exactly: true)
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
        _ = await waitForPeerCount(1, in: manager)
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

    /// Services this Mac advertises itself are not "devices on this network": the
    /// count under the device list said "1 other device, already paired" about the
    /// local test harness, which is neither.
    @Test @MainActor
    func testPeersOnThisMachineAreNotCountedAsOthers() async throws {
        let driver = MockBonjourDriver()
        let manager = makeManager(driver: driver)
        defer { Task { await manager.deactivateLanServices() } }
        await manager.ensureLanDiscoveryActive()

        driver.emit(.resolved(BonjourServiceRecord(
            serviceName: "local-harness",
            host: "127.0.0.1",
            port: 7011,
            txtRecords: ["device_id": "cccc3333", "pub_key": "cHVibGljLWtleQ=="]
        )))
        driver.emit(.resolved(makeRecord(serviceName: "peer-one", deviceId: "aaaa1111")))
        _ = await waitForPeerCount(2, in: manager)

        #expect(manager.discoveredLanPeers.count == 2)
        #expect(manager.discoveredPeersOnOtherMachines().map(\.serviceName) == ["peer-one"])
        #expect(manager.pairableLanPeers().map(\.serviceName) == ["peer-one"])
    }

    /// A stored Bonjour address outlives the network it was learned on, so "is a LAN
    /// connection open" has to be asked separately from "do we know an address".
    @Test @MainActor
    func testLanConnectionIsTrackedSeparatelyFromKnownAddresses() async throws {
        let manager = makeManager(driver: MockBonjourDriver())
        defer { Task { await manager.deactivateLanServices() } }

        manager.registerPairedDevice(PairedDevice(
            id: "aaaa1111",
            name: "Peer One",
            platform: "Android",
            lastSeen: Date(),
            isOnline: true,
            bonjourHost: "10.0.0.137",
            bonjourPort: 7010
        ))
        #expect(manager.isConnectedOverLan("aaaa1111") == false)

        manager.setLanConnection(deviceId: "aaaa1111", isConnected: true)
        #expect(manager.isConnectedOverLan("AAAA1111"))

        manager.setLanConnection(deviceId: "aaaa1111", isConnected: false)
        #expect(manager.isConnectedOverLan("aaaa1111") == false)
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

/// Waits for discovery to settle instead of sleeping a fixed interval.
///
/// These tests emitted records and then slept 5ms before asserting. That is a
/// guess about how long delivery takes, and it held until the suite grew and
/// the machine got busier — then a peer had simply not arrived yet and the
/// count came back one short. Waiting for the expected number costs nothing
/// when it is already there.
@MainActor
func waitForPeerCount(
    _ expected: Int,
    in manager: TransportManager,
    exactly: Bool = false,
    timeout: TimeInterval = 5
) async -> Bool {
    func satisfied() -> Bool {
        exactly ? manager.discoveredLanPeers.count == expected
                : manager.discoveredLanPeers.count >= expected
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if satisfied() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return satisfied()
}
