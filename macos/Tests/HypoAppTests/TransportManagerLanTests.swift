import Foundation
import Testing
@testable import HypoApp

struct TransportManagerLanTests {
    @Test @MainActor
    func testDiscoveryEventsUpdateStateAndDiagnostics() async throws {
        let driver = MockBonjourDriver()
        let now = Date(timeIntervalSince1970: 1_000)
        let browser = BonjourBrowser(driver: driver, clock: { now })
        let publisher = MockBonjourPublisher()
        let cache = InMemoryLanDiscoveryCache()
        let webSocketServer = makeWebSocketServer()
        let manager = TransportManager(
            provider: MockTransportProvider(),
            browser: browser,
            publisher: publisher,
            discoveryCache: cache,
            lanConfiguration: BonjourPublisher.Configuration(
                serviceName: "local-device",
                port: 0,
                version: "1.0",
                fingerprint: "fingerprint",
                protocols: ["ws+tls"]
            ),
            webSocketServer: webSocketServer,
            autoStartLanServices: false
        )
        defer { Task { await manager.deactivateLanServices() } }

        await manager.ensureLanDiscoveryActive()
        let startCount = await MainActor.run { publisher.startCount }
        #expect(startCount == 1)
        let publishedConfig = await MainActor.run { publisher.currentConfiguration }
        #expect(publishedConfig?.port ?? 0 > 0)

        let record = BonjourServiceRecord(
            serviceName: "peer-one",
            host: "peer.local",
            port: 7010,
            txtRecords: ["fingerprint_sha256": "abc", "protocols": "ws+tls"]
        )
        driver.emit(.resolved(record))
        try await Task.sleep(nanoseconds: 5_000_000)

        let peers = manager.lanDiscoveredPeers()
        #expect(peers.count == 1)
        #expect(peers.first?.serviceName == "peer-one")
        #expect(cache.storage["peer-one"] == Date(timeIntervalSince1970: 1_000))

        let diagnostics = manager.handleDeepLink(URL(string: "hypo://debug/lan")!)
        #expect(diagnostics != nil)
        #expect(diagnostics?.contains("peer-one") ?? false)

        driver.emit(.removed("peer-one"))
        try await Task.sleep(nanoseconds: 5_000_000)
        let remainingPeers = manager.lanDiscoveredPeers()
        #expect(remainingPeers.isEmpty)
        #expect(cache.storage["peer-one"] != nil)

        await manager.suspendLanDiscovery()
        let stopCount = await MainActor.run { publisher.stopCount }
        #expect(stopCount == 1)
    }

    @Test @MainActor
    func testAutomaticPruneRemovesStalePeers() async throws {
        let driver = MockBonjourDriver()
        let clock = MutableClock(now: Date(timeIntervalSince1970: 10_000))
        let browser = BonjourBrowser(driver: driver, clock: { clock.now })
        let publisher = MockBonjourPublisher()
        let cache = InMemoryLanDiscoveryCache()
        let webSocketServer = makeWebSocketServer()
        let manager = TransportManager(
            provider: MockTransportProvider(),
            browser: browser,
            publisher: publisher,
            discoveryCache: cache,
            lanConfiguration: BonjourPublisher.Configuration(
                serviceName: "local-device",
                port: 0,
                version: "1.0",
                fingerprint: "fingerprint",
                protocols: ["ws+tls"]
            ),
            pruneInterval: 0.05,
            stalePeerInterval: 0.1,
            dateProvider: { clock.now },
            webSocketServer: webSocketServer,
            autoStartLanServices: false
        )
        defer { Task { await manager.deactivateLanServices() } }

        await manager.ensureLanDiscoveryActive()

        let record = BonjourServiceRecord(
            serviceName: "peer-auto",
            host: "peer.local",
            port: 7010,
            txtRecords: ["fingerprint_sha256": "abc", "protocols": "ws+tls"]
        )
        driver.emit(.resolved(record))
        try await Task.sleep(nanoseconds: 10_000_000)

        var peers = manager.lanDiscoveredPeers()
        #expect(peers.count == 1)

        clock.now = clock.now.addingTimeInterval(0.2)
        try await Task.sleep(nanoseconds: 200_000_000)

        peers = manager.lanDiscoveredPeers()
        #expect(peers.isEmpty)
        #expect(cache.storage.isEmpty)

        await manager.suspendLanDiscovery()
    }

    @Test
    func testConnectPrefersLan() async {
        let manager = await MainActor.run {
            TransportManager(
                provider: MockTransportProvider(),
                analytics: InMemoryTransportAnalytics(),
                webSocketServer: makeWebSocketServer(),
                autoStartLanServices: false
            )
        }
        defer { Task { await manager.deactivateLanServices() } }

        let state = await manager.connect(
            lanDialer: { LanDialResult.success },
            cloudDialer: { #expect(Bool(false)); return false },
            peerIdentifier: "peer"
        )

        #expect(state == .connectedLan)
        let recordedState = await MainActor.run { manager.connectionState }
        #expect(recordedState == .connectedLan)
        let lastRoute = await MainActor.run { manager.lastSuccessfulTransport(for: "peer") }
        #expect(lastRoute == .lan)
    }

    @Test
    func testConnectFallsBackOnTimeout() async {
        let analytics = InMemoryTransportAnalytics()
        let manager = await MainActor.run {
            TransportManager(
                provider: MockTransportProvider(),
                analytics: analytics,
                webSocketServer: makeWebSocketServer(),
                autoStartLanServices: false
            )
        }
        defer { Task { await manager.deactivateLanServices() } }

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
        #expect(state == .connectedCloud)
        let events = analytics.events()
        #expect(events.count == 1)
        if case let .fallback(reason, _, _) = events.first {
            #expect(reason == .lanTimeout)
        } else {
            #expect(Bool(false))
        }
    }

    @Test
    func testConnectRecordsLanFailureReason() async {
        let analytics = InMemoryTransportAnalytics()
        let manager = await MainActor.run {
            TransportManager(
                provider: MockTransportProvider(),
                analytics: analytics,
                webSocketServer: makeWebSocketServer(),
                autoStartLanServices: false
            )
        }
        defer { Task { await manager.deactivateLanServices() } }

        let state = await manager.connect(
            lanDialer: { .failure(reason: .lanRejected, error: NSError(domain: "test", code: 1)) },
            cloudDialer: { false },
            peerIdentifier: "peer"
        )

        #expect(state == .error("Cloud connection failed"))
        let events = analytics.events()
        #expect(events.count == 1)
        if case let .fallback(reason, metadata, _) = events.first {
            #expect(reason == .lanRejected)
            #expect(metadata["reason"] == "lan_rejected")
        } else {
            #expect(Bool(false))
        }
        let route = await MainActor.run { manager.lastSuccessfulTransport(for: "peer") }
        #expect(route == nil)
    }

    @Test
    func testConnectionSupervisorReconnectsAfterHeartbeatFailure() async {
        let analytics = InMemoryTransportAnalytics()
        let manager = await MainActor.run {
            TransportManager(
                provider: MockTransportProvider(),
                analytics: analytics,
                webSocketServer: makeWebSocketServer(),
                autoStartLanServices: false
            )
        }
        defer { Task { await manager.deactivateLanServices() } }

        let lanAttempts = Locked(0)
        let heartbeatCalls = Locked(0)
        await manager.startConnectionSupervisor(
            peerIdentifier: "peer",
            lanDialer: {
                lanAttempts.withLock { $0 += 1 }
                return .success
            },
            cloudDialer: { true },
            sendHeartbeat: {
                heartbeatCalls.withLock { $0 += 1; return $0 < 2 }
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

        let fulfilled = await waitUntil(timeout: .seconds(2)) {
            lanAttempts.withLock { $0 >= 2 }
        }
        #expect(fulfilled)
        let last = await manager.lastSuccessfulTransport(for: "peer")
        #expect(last == .lan)

        await manager.stopConnectionSupervisor()
    }

    @Test
    func testManualRetrySkipsBackoffDelay() async {
        let manager = await MainActor.run {
            TransportManager(
                provider: MockTransportProvider(),
                analytics: InMemoryTransportAnalytics(),
                webSocketServer: makeWebSocketServer(),
                autoStartLanServices: false
            )
        }
        defer { Task { await manager.deactivateLanServices() } }

        let attempts = Locked(0)
        await manager.startConnectionSupervisor(
            peerIdentifier: "peer",
            lanDialer: {
                let currentAttempt = attempts.withLock { $0 += 1; return $0 }
                if currentAttempt == 1 {
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
        #expect(last == .lan)
    }

    @Test
    func testShutdownTransportFlushesCallback() async {
        let manager = await MainActor.run {
            TransportManager(
                provider: MockTransportProvider(),
                analytics: InMemoryTransportAnalytics(),
                webSocketServer: makeWebSocketServer(),
                autoStartLanServices: false
            )
        }
        defer { Task { await manager.deactivateLanServices() } }

        let flushed = Locked(false)
        await manager.startConnectionSupervisor(
            peerIdentifier: "peer",
            lanDialer: { .success },
            cloudDialer: { true },
            sendHeartbeat: { true },
            awaitAck: { true }
        )

        let onShutdown: @Sendable () async -> Void = {
            flushed.withLock { $0 = true }
        }
        await manager.shutdownTransport(gracefully: onShutdown)

        #expect(flushed.withLock { $0 })
        let state = await MainActor.run { manager.connectionState }
        #expect(state == .disconnected)
    }

    @Test @MainActor
    func testUpdateLocalAdvertisementRestartsOnPortChange() async throws {
        let publisher = MockBonjourPublisher()
        let manager = TransportManager(
            provider: MockTransportProvider(),
            publisher: publisher,
            lanConfiguration: BonjourPublisher.Configuration(
                serviceName: "local-device",
                port: 0,
                version: "1.0",
                fingerprint: "fingerprint",
                protocols: ["ws+tls"]
            ),
            webSocketServer: makeWebSocketServer(),
            autoStartLanServices: false
        )
        defer { Task { await manager.deactivateLanServices() } }

        await manager.ensureLanDiscoveryActive()
        let initialStarts = publisher.startCount

        manager.updateLocalAdvertisement(port: 4567, fingerprint: "fp-2")

        #expect(publisher.stopCount == 1)
        #expect(publisher.startCount == initialStarts + 1)
        #expect(publisher.currentConfiguration?.port == 4567)
    }

    @Test @MainActor
    func testUpdateLocalAdvertisementUpdatesTXTRecordWhenPortUnchanged() async {
        let publisher = MockBonjourPublisher()
        let manager = TransportManager(
            provider: MockTransportProvider(),
            publisher: publisher,
            lanConfiguration: BonjourPublisher.Configuration(
                serviceName: "local-device",
                port: 5555,
                version: "1.0",
                fingerprint: "fingerprint",
                protocols: ["ws+tls"]
            ),
            webSocketServer: makeWebSocketServer(),
            autoStartLanServices: false
        )
        defer { Task { await manager.deactivateLanServices() } }

        await manager.ensureLanDiscoveryActive()
        manager.updateLocalAdvertisement(fingerprint: "fp-3")

        #expect(publisher.metadataUpdates.count == 1)
        #expect(publisher.currentConfiguration?.fingerprint == "fp-3")
    }
}
