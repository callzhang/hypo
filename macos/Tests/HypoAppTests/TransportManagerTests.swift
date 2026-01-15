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
            webSocketServer: webSocketServer
        )
        
        let report = await manager.diagnosticsReport()
        
        #expect(report.contains("Hypo LAN Diagnostics"))
        #expect(report.contains("Discovered Peers"))
    }
    
    @Test @MainActor
    func testUpdateLocalAdvertisementUpdatesPublisher() async {
        let publisher = MockBonjourPublisher()
        let webSocketServer = await makeWebSocketServer()
        let manager = await TransportManager(
            provider: MockTransportProvider(),
            publisher: publisher,
            lanConfiguration: .init(serviceName: "initial", port: 0, version: "1.0", fingerprint: "test", protocols: ["ws"]),
            webSocketServer: webSocketServer
        )
        
        await manager.updateLocalAdvertisement(
            port: 1234,
            fingerprint: "fp"
        )
        
        // Wait for update (it's async on MainActor)
        let config = await MainActor.run { publisher.currentConfiguration }
        #expect(config?.port == 1234)
        #expect(config?.fingerprint == "fp")
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
        let _ = await TransportManager(
            provider: transportProvider,
            lanConfiguration: .init(serviceName: "test", port: 0, version: "1.0", fingerprint: "test", protocols: ["ws"]),
            webSocketServer: webSocketServer,
            historyStore: store
        )
        
        #expect(transportProvider.hasCloudIncomingMessageHandler)
    }
}
