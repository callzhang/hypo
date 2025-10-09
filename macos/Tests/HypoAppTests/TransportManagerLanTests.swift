import XCTest
@testable import HypoApp

final class TransportManagerLanTests: XCTestCase {
    func testDiscoveryEventsUpdateStateAndDiagnostics() async throws {
        let driver = MockBonjourDriver()
        let now = Date(timeIntervalSince1970: 1_000)
        let browser = BonjourBrowser(driver: driver, clock: { now })
        let publisher = MockBonjourPublisher()
        let cache = InMemoryLanDiscoveryCache()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            preferenceStorage: MockPreferenceStorage(),
            browser: browser,
            publisher: publisher,
            discoveryCache: cache,
            lanConfiguration: BonjourPublisher.Configuration(
                serviceName: "local-device",
                port: 7010,
                version: "1.0",
                fingerprint: "fingerprint",
                protocols: ["ws+tls"]
            )
        )

        await manager.ensureLanDiscoveryActive()
        XCTAssertEqual(publisher.startCount, 1)

        let record = BonjourServiceRecord(
            serviceName: "peer-one",
            host: "peer.local",
            port: 7010,
            txtRecords: ["fingerprint_sha256": "abc", "protocols": "ws+tls"]
        )
        driver.emit(.resolved(record))
        try await Task.sleep(nanoseconds: 5_000_000)

        let peers = await manager.lanDiscoveredPeers()
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.serviceName, "peer-one")
        XCTAssertEqual(cache.storage["peer-one"], Date(timeIntervalSince1970: 1_000))

        let diagnostics = await manager.handleDeepLink(URL(string: "hypo://debug/lan")!)
        XCTAssertNotNil(diagnostics)
        XCTAssertTrue(diagnostics?.contains("peer-one") ?? false)

        driver.emit(.removed("peer-one"))
        try await Task.sleep(nanoseconds: 5_000_000)
        let remainingPeers = await manager.lanDiscoveredPeers()
        XCTAssertTrue(remainingPeers.isEmpty)
        XCTAssertNotNil(cache.storage["peer-one"])

        await manager.suspendLanDiscovery()
        XCTAssertEqual(publisher.stopCount, 1)
    }

    func testAutomaticPruneRemovesStalePeers() async throws {
        let driver = MockBonjourDriver()
        var now = Date(timeIntervalSince1970: 10_000)
        let browser = BonjourBrowser(driver: driver, clock: { now })
        let publisher = MockBonjourPublisher()
        let cache = InMemoryLanDiscoveryCache()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            preferenceStorage: MockPreferenceStorage(),
            browser: browser,
            publisher: publisher,
            discoveryCache: cache,
            lanConfiguration: BonjourPublisher.Configuration(
                serviceName: "local-device",
                port: 7010,
                version: "1.0",
                fingerprint: "fingerprint",
                protocols: ["ws+tls"]
            ),
            pruneInterval: 0.05,
            stalePeerInterval: 0.1,
            dateProvider: { now }
        )

        await manager.ensureLanDiscoveryActive()

        let record = BonjourServiceRecord(
            serviceName: "peer-auto",
            host: "peer.local",
            port: 7010,
            txtRecords: ["fingerprint_sha256": "abc", "protocols": "ws+tls"]
        )
        driver.emit(.resolved(record))
        try await Task.sleep(nanoseconds: 10_000_000)

        var peers = await manager.lanDiscoveredPeers()
        XCTAssertEqual(peers.count, 1)

        now = now.addingTimeInterval(0.2)
        try await Task.sleep(nanoseconds: 200_000_000)

        peers = await manager.lanDiscoveredPeers()
        XCTAssertTrue(peers.isEmpty)
        XCTAssertTrue(cache.storage.isEmpty)

        await manager.suspendLanDiscovery()
    }

    func testConnectPrefersLan() async {
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            preferenceStorage: MockPreferenceStorage(),
            analytics: InMemoryTransportAnalytics()
        )

        let state = await manager.connect(
            lanDialer: { .success },
            cloudDialer: { XCTFail("Cloud should not be invoked"); return false },
            peerIdentifier: "peer"
        )

        XCTAssertEqual(state, .connectedLan)
        let recordedState = await MainActor.run { manager.connectionState }
        XCTAssertEqual(recordedState, .connectedLan)
        let lastRoute = await MainActor.run { manager.lastSuccessfulTransport(for: "peer") }
        XCTAssertEqual(lastRoute, .lan)
    }

    func testConnectFallsBackOnTimeout() async {
        let analytics = InMemoryTransportAnalytics()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            preferenceStorage: MockPreferenceStorage(),
            analytics: analytics
        )

        let task = Task {
            await manager.connect(
                lanDialer: {
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                    return .success
                },
                cloudDialer: { true },
                timeout: 1,
                peerIdentifier: "peer"
            )
        }

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let state = await task.value
        XCTAssertEqual(state, .connectedCloud)
        let events = analytics.events()
        XCTAssertEqual(events.count, 1)
        if case let .fallback(reason, _, _) = events.first {
            XCTAssertEqual(reason, .lanTimeout)
        } else {
            XCTFail("Expected fallback analytics event")
        }
    }

    func testConnectRecordsLanFailureReason() async {
        let analytics = InMemoryTransportAnalytics()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            preferenceStorage: MockPreferenceStorage(),
            analytics: analytics
        )

        let state = await manager.connect(
            lanDialer: { .failure(reason: .lanRejected, error: NSError(domain: "test", code: 1)) },
            cloudDialer: { false },
            peerIdentifier: "peer"
        )

        XCTAssertEqual(state, .error("Cloud connection failed"))
        let events = analytics.events()
        XCTAssertEqual(events.count, 1)
        if case let .fallback(reason, metadata, _) = events.first {
            XCTAssertEqual(reason, .lanRejected)
            XCTAssertEqual(metadata["reason"], "lan_rejected")
        } else {
            XCTFail("Expected fallback analytics event")
        }
        let route = await MainActor.run { manager.lastSuccessfulTransport(for: "peer") }
        XCTAssertNil(route)
    }

    func testConnectionSupervisorReconnectsAfterHeartbeatFailure() async {
        let analytics = InMemoryTransportAnalytics()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            preferenceStorage: MockPreferenceStorage(),
            analytics: analytics
        )

        var lanAttempts = 0
        var heartbeatCalls = 0
        await manager.startConnectionSupervisor(
            peerIdentifier: "peer",
            lanDialer: {
                lanAttempts += 1
                return .success
            },
            cloudDialer: { true },
            sendHeartbeat: {
                heartbeatCalls += 1
                return heartbeatCalls < 2
            },
            awaitAck: { true },
            configuration: ConnectionSupervisorConfiguration(
                fallbackTimeout: 1,
                heartbeatInterval: 0.1,
                ackTimeout: 0.1,
                initialBackoff: 0.1,
                maxBackoff: 1,
                jitterRange: 0...0,
                maxAttempts: 5
            )
        )

        try? await Task.sleep(nanoseconds: 600_000_000)

        let attempts = lanAttempts
        XCTAssertGreaterThanOrEqual(attempts, 2)
        let last = await manager.lastSuccessfulTransport(for: "peer")
        XCTAssertEqual(last, .lan)

        await manager.stopConnectionSupervisor()
    }

    func testManualRetrySkipsBackoffDelay() async {
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            preferenceStorage: MockPreferenceStorage(),
            analytics: InMemoryTransportAnalytics()
        )

        var attempts = 0
        await manager.startConnectionSupervisor(
            peerIdentifier: "peer",
            lanDialer: {
                attempts += 1
                if attempts == 1 {
                    return .failure(reason: .lanTimeout, error: nil)
                }
                return .success
            },
            cloudDialer: { false },
            sendHeartbeat: { true },
            awaitAck: { true },
            configuration: ConnectionSupervisorConfiguration(
                fallbackTimeout: 0.1,
                heartbeatInterval: 0.2,
                ackTimeout: 0.1,
                initialBackoff: 5,
                maxBackoff: 10,
                jitterRange: 0...0,
                maxAttempts: 3
            )
        )

        try? await Task.sleep(nanoseconds: 200_000_000)
        await manager.requestReconnect()
        try? await Task.sleep(nanoseconds: 800_000_000)

        await manager.stopConnectionSupervisor()
        await Task.yield()
        let last = await manager.lastSuccessfulTransport(for: "peer")
        XCTAssertEqual(last, .lan)
    }

    func testShutdownTransportFlushesCallback() async {
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            preferenceStorage: MockPreferenceStorage(),
            analytics: InMemoryTransportAnalytics()
        )

        var flushed = false
        await manager.startConnectionSupervisor(
            peerIdentifier: "peer",
            lanDialer: { .success },
            cloudDialer: { true },
            sendHeartbeat: { true },
            awaitAck: { true }
        )

        await manager.shutdownTransport {
            flushed = true
        }

        XCTAssertTrue(flushed)
        let state = await MainActor.run { manager.connectionState }
        XCTAssertEqual(state, .idle)
    }
}

private final class MockBonjourPublisher: BonjourPublishing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var metadataUpdates: [[String: String]] = []
    private var configuration: BonjourPublisher.Configuration?

    var currentConfiguration: BonjourPublisher.Configuration? { configuration }
    var currentEndpoint: LanEndpoint? {
        guard let configuration else { return nil }
        return LanEndpoint(
            host: "localhost",
            port: configuration.port,
            fingerprint: configuration.fingerprint,
            metadata: configuration.txtRecord
        )
    }

    func start(with configuration: BonjourPublisher.Configuration) {
        startCount += 1
        self.configuration = configuration
    }

    func stop() {
        stopCount += 1
        configuration = nil
    }

    func updateTXTRecord(_ metadata: [String : String]) {
        metadataUpdates.append(metadata)
        guard let configuration else { return }
        let fingerprint = metadata["fingerprint_sha256"] ?? configuration.fingerprint
        let version = metadata["version"] ?? configuration.version
        let protocols = (metadata["protocols"] ?? configuration.protocols.joined(separator: ",")).split(separator: ",").map(String.init)
        self.configuration = BonjourPublisher.Configuration(
            domain: configuration.domain,
            serviceType: configuration.serviceType,
            serviceName: configuration.serviceName,
            port: configuration.port,
            version: version,
            fingerprint: fingerprint,
            protocols: protocols
        )
    }
}

private final class InMemoryLanDiscoveryCache: LanDiscoveryCache {
    var storage: [String: Date] = [:]

    func load() -> [String : Date] {
        storage
    }

    func save(_ lastSeen: [String : Date]) {
        storage = lastSeen
    }
}

private final class MockTransportProvider: TransportProvider {
    func preferredTransport(for preference: TransportPreference) -> SyncTransport {
        MockSyncTransport()
    }
}

private struct MockSyncTransport: SyncTransport {
    func connect() async throws {}
    func send(_ envelope: SyncEnvelope) async throws {}
    func disconnect() async {}
}

private final class MockPreferenceStorage: PreferenceStorage {
    var stored: TransportPreference?

    func loadPreference() -> TransportPreference? { stored }

    func savePreference(_ preference: TransportPreference) {
        stored = preference
    }
}

private final class MockBonjourDriver: BonjourBrowsingDriver {
    private var handler: ((BonjourBrowsingDriverEvent) -> Void)?

    func startBrowsing(serviceType: String, domain: String) {}

    func stopBrowsing() {}

    func setEventHandler(_ handler: @escaping (BonjourBrowsingDriverEvent) -> Void) {
        self.handler = handler
    }

    func emit(_ event: BonjourBrowsingDriverEvent) {
        handler?(event)
    }
}
