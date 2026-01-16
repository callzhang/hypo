import Foundation
import Testing
@testable import HypoApp

struct TransportManagerTests {
    @Test @MainActor
    func testDiagnosticsReportIncludesVersionAndPeers() async {
        let publisher = MockBonjourPublisher()
        let webSocketServer = await makeWebSocketServer()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            publisher: publisher,
            lanConfiguration: .init(serviceName: "test", port: 0, version: "1.0", fingerprint: "test", protocols: ["ws"]),
            webSocketServer: webSocketServer,
            autoStartLanServices: false
        )
        
        let report = await manager.diagnosticsReport()
        
        #expect(report.contains("Hypo LAN Diagnostics"))
        #expect(report.contains("Discovered Peers"))

        await manager.deactivateLanServices()
    }
    
    @Test @MainActor
    func testUpdateLocalAdvertisementUpdatesPublisher() async {
        let publisher = MockBonjourPublisher()
        let webSocketServer = await makeWebSocketServer()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            publisher: publisher,
            lanConfiguration: .init(serviceName: "initial", port: 0, version: "1.0", fingerprint: "test", protocols: ["ws"]),
            webSocketServer: webSocketServer,
            autoStartLanServices: false
        )
        
        await manager.updateLocalAdvertisement(
            port: 1234,
            fingerprint: "fp"
        )
        
        let config = await manager.currentLanConfiguration()
        #expect(config.port == 1234)
        #expect(config.fingerprint == "fp")

        await manager.deactivateLanServices()
    }
    
    @Test @MainActor
    func testIncomingClipboardHandlerRegistration() async {
        // Setup HistoryStore
        let suiteName = "TransportManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let store = HistoryStore(maxEntries: 10, defaults: defaults)
        
        let transportProvider = MockTransportProvider()
        #expect(!transportProvider.hasCloudIncomingMessageHandler)

        let webSocketServer = await makeWebSocketServer()
        let manager = await TransportManager(
            provider: transportProvider,
            lanConfiguration: .init(serviceName: "test", port: 0, version: "1.0", fingerprint: "test", protocols: ["ws"]),
            webSocketServer: webSocketServer,
            historyStore: store,
            autoStartLanServices: false
        )
        
        #expect(transportProvider.hasCloudIncomingMessageHandler)

        await manager.deactivateLanServices()
    }

    @Test @MainActor
    func testCloudIncomingHandlerHandlesValidAndInvalidFrames() async throws {
        let defaults = makeIsolatedDefaults()
        let store = HistoryStore(maxEntries: 10, defaults: defaults)
        let transportProvider = MockTransportProvider()
        let manager = await TransportManager(
            provider: transportProvider,
            webSocketServer: await makeWebSocketServer(),
            historyStore: store,
            defaults: defaults,
            autoStartLanServices: false
        )

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data(), tag: Data())
        ))
        let data = try TransportFrameCodec().encode(envelope)
        await transportProvider.simulateIncomingMessage(data: data, origin: .cloud)

        let garbage = Data([0x00, 0x01, 0x02])
        await transportProvider.simulateIncomingMessage(data: garbage, origin: .cloud)

        await manager.deactivateLanServices()
    }

    @Test @MainActor
    func testUpdateDeviceOnlineStatusSendsNotification() async {
        let defaults = makeIsolatedDefaults()
        let notificationController = MockNotificationController()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            webSocketServer: await makeWebSocketServer(),
            defaults: defaults,
            notificationController: notificationController,
            autoStartLanServices: false
        )

        let device = PairedDevice(
            id: "device-1",
            name: "Test Device",
            platform: "macOS",
            lastSeen: Date(),
            isOnline: false
        )
        manager.addPairedDevice(device)

        manager.updateDeviceOnlineStatus(deviceId: device.id, isOnline: true)
        #expect(notificationController.statusNotifications.count == 1)
        #expect(notificationController.statusNotifications.first?.deviceId == "device-1")

        manager.updateDeviceOnlineStatus(deviceId: device.id, isOnline: true)
        #expect(notificationController.statusNotifications.count == 1)
    }

    @Test @MainActor
    func testUpdateCloudConnectedDeviceIdsMarksOnline() async {
        let defaults = makeIsolatedDefaults()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            webSocketServer: await makeWebSocketServer(),
            defaults: defaults,
            autoStartLanServices: false
        )

        let first = PairedDevice(
            id: "device-a",
            name: "Alpha",
            platform: "macOS",
            lastSeen: Date(),
            isOnline: false
        )
        let second = PairedDevice(
            id: "device-b",
            name: "Beta",
            platform: "Android",
            lastSeen: Date(),
            isOnline: false
        )
        manager.addPairedDevice(first)
        manager.addPairedDevice(second)

        manager.updateCloudConnectedDeviceIds(["device-b"])

        let devices = manager.pairedDevices
        #expect(devices.first(where: { $0.id == "device-a" })?.isOnline == false)
        #expect(devices.first(where: { $0.id == "device-b" })?.isOnline == true)
    }

    @Test @MainActor
    func testRegisterPairedDeviceUpdatesByName() async {
        let defaults = makeIsolatedDefaults()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            webSocketServer: await makeWebSocketServer(),
            defaults: defaults,
            autoStartLanServices: false
        )

        let original = PairedDevice(
            id: "id-1",
            name: "Shared Name",
            platform: "macOS",
            lastSeen: Date(),
            isOnline: false
        )
        manager.registerPairedDevice(original)

        let replacement = PairedDevice(
            id: "id-2",
            name: "Shared Name",
            platform: "macOS",
            lastSeen: Date(),
            isOnline: true
        )
        manager.registerPairedDevice(replacement)

        #expect(manager.pairedDevices.count == 1)
        #expect(manager.pairedDevices.first?.id == "id-2")
    }

    @Test @MainActor
    func testRegisterPairedDeviceSkipsNoChange() async {
        let defaults = makeIsolatedDefaults()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            webSocketServer: await makeWebSocketServer(),
            defaults: defaults,
            autoStartLanServices: false
        )

        let device = PairedDevice(
            id: "id-1",
            name: "Same Device",
            platform: "macOS",
            lastSeen: Date(),
            isOnline: false
        )
        manager.registerPairedDevice(device)
        manager.registerPairedDevice(device)

        #expect(manager.pairedDevices.count == 1)
    }

    @Test @MainActor
    func testDeviceNameCacheProvidesFallback() async {
        let defaults = makeIsolatedDefaults()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            webSocketServer: await makeWebSocketServer(),
            defaults: defaults,
            autoStartLanServices: false
        )

        let device = PairedDevice(
            id: "ABCDEF12-3456-7890-ABCD-EF1234567890",
            name: "Named Device",
            platform: "macOS",
            lastSeen: Date(),
            isOnline: false
        )
        manager.addPairedDevice(device)

        #expect(manager.deviceName(for: device.id) == "Named Device")
        let fallback = manager.getDeviceName("UNKNOWN-DEVICE-ID")
        #expect(fallback.hasSuffix("..."))
    }

    @Test @MainActor
    func testDiagnosticsReportIncludesLocalServiceWhenAdvertising() async throws {
        let publisher = MockBonjourPublisher()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            publisher: publisher,
            lanConfiguration: BonjourPublisher.Configuration(
                serviceName: "local-device",
                port: 0,
                version: "1.0",
                fingerprint: "fingerprint",
                protocols: ["ws"]
            ),
            webSocketServer: await makeWebSocketServer(),
            autoStartLanServices: false
        )

        await manager.ensureLanDiscoveryActive()
        let endpoint = manager.currentLanEndpoint()
        #expect(endpoint != nil)

        let report = await manager.diagnosticsReport()
        #expect(report.contains("Local Service:"))
        #expect(report.contains("Fingerprint:"))

        await manager.deactivateLanServices()
    }

    @Test @MainActor
    func testHandleDeepLinkRejectsNonDebug() async {
        let defaults = makeIsolatedDefaults()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            webSocketServer: await makeWebSocketServer(),
            defaults: defaults,
            autoStartLanServices: false
        )

        let result = manager.handleDeepLink(URL(string: "hypo://debug/other")!)
        #expect(result == nil)
    }

    @Test @MainActor
    func testPruneLanPeersRemovesOldEntries() async {
        let defaults = makeIsolatedDefaults()
        let cache = InMemoryLanDiscoveryCache()
        let now = Date()
        cache.storage = [
            "peer-old": now.addingTimeInterval(-200),
            "peer-new": now.addingTimeInterval(-10)
        ]

        let manager = await TransportManager(
            provider: MockTransportProvider(),
            discoveryCache: cache,
            dateProvider: { now },
            webSocketServer: await makeWebSocketServer(),
            defaults: defaults,
            autoStartLanServices: false
        )

        manager.pruneLanPeers(olderThan: 60)
        #expect(manager.lastSeenTimestamp(for: "peer-old") == nil)
        #expect(manager.lastSeenTimestamp(for: "peer-new") != nil)
    }

    @Test @MainActor
    func testPairingParametersAndAccessors() async {
        let defaults = makeIsolatedDefaults()
        let config = BonjourPublisher.Configuration(
            serviceName: "test-device",
            port: 1234,
            version: "1.0",
            fingerprint: "fp",
            protocols: ["ws"]
        )
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            lanConfiguration: config,
            webSocketServer: await makeWebSocketServer(),
            defaults: defaults,
            autoStartLanServices: false
        )

        let params = manager.pairingParameters()
        #expect(params.port == 1234)
        #expect(params.service.contains("test-device"))
        _ = manager.connectionStatePublisher
        _ = manager.webSocketServerInstance
        _ = manager.loadTransport()
    }

    @Test @MainActor
    func testSetLanConnectionTracksOnlineState() async {
        let defaults = makeIsolatedDefaults()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            webSocketServer: await makeWebSocketServer(),
            defaults: defaults,
            autoStartLanServices: false
        )

        let device = PairedDevice(
            id: "DEVICE-ABC",
            name: "Case Device",
            platform: "macOS",
            lastSeen: Date(),
            isOnline: false
        )
        manager.addPairedDevice(device)

        manager.updateConnectionState(.connectedCloud)
        manager.setLanConnection(deviceId: "device-abc", isConnected: true)
        #expect(manager.hasLanConnections())

        manager.setLanConnection(deviceId: "device-abc", isConnected: false)
        #expect(manager.hasLanConnections() == false)
    }

    @Test @MainActor
    func testUpdateAndRemovePairedDevice() async {
        let defaults = makeIsolatedDefaults()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            webSocketServer: await makeWebSocketServer(),
            defaults: defaults,
            autoStartLanServices: false
        )

        let device = PairedDevice(
            id: "device-123",
            name: "Old Device",
            platform: "macOS",
            lastSeen: Date(timeIntervalSince1970: 10),
            isOnline: false
        )
        manager.addPairedDevice(device)

        let updated = Date(timeIntervalSince1970: 20)
        manager.updatePairedDeviceLastSeen(device.id, lastSeen: updated)
        #expect(manager.pairedDevices.first?.lastSeen == updated)

        manager.removePairedDevice(device)
        #expect(manager.pairedDevices.isEmpty)
    }

    @Test @MainActor
    func testServerDelegatePathsUpdateConnectionState() async throws {
        let defaults = makeIsolatedDefaults()
        let server = await makeWebSocketServer()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            webSocketServer: server,
            defaults: defaults,
            autoStartLanServices: false
        )

        manager.updateConnectionState(.connectedCloud)

        let connectionId = UUID()
        server.updateConnectionMetadata(connectionId: connectionId, deviceId: "device-xyz")
        manager.server(server, didAcceptConnection: connectionId)

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device-xyz",
            target: "peer",
            encryption: .init(nonce: Data([0x02]), tag: Data([0x03]))
        ))
        let data = try TransportFrameCodec().encode(envelope)
        manager.server(server, didReceiveClipboardData: data, from: connectionId)

        // Force fallback path to metadata-based device ID
        manager.server(server, didReceiveClipboardData: Data([0x00]), from: connectionId)

        manager.server(server, didCloseConnection: connectionId)
    }

    @Test @MainActor
    func testSetHistoryViewModelAndUpdateConnectionState() async {
        let defaults = makeIsolatedDefaults()
        let store = HistoryStore(maxEntries: 10, defaults: defaults)
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            webSocketServer: await makeWebSocketServer(),
            historyStore: store,
            defaults: defaults,
            autoStartLanServices: false
        )

        let viewModel = ClipboardHistoryViewModel(store: store, transportManager: manager, defaults: defaults)
        manager.setHistoryViewModel(viewModel)
        manager.setHistoryViewModel(viewModel)

        manager.updateConnectionState(.connectedLan)
        manager.updateConnectionState(.connectedLan)
    }
}

private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "TransportManagerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
