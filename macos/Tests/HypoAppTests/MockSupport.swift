import Foundation
import Testing
import Network
import os
@testable import HypoApp

/// A simple unfair lock wrapper that supports manual lock()/unlock() for test mocks
final class UnfairLock: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    
    func lock() {
        os_unfair_lock_lock(&_lock)
    }
    
    func unlock() {
        os_unfair_lock_unlock(&_lock)
    }
}

final class MockBonjourPublisherState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    fileprivate var startCount = 0
    fileprivate var stopCount = 0
    fileprivate var metadataUpdates: [[String: String]] = []
    fileprivate var configuration: BonjourPublisher.Configuration?
    
    func getStartCount() -> Int { lock.withLock { startCount } }
    func getStopCount() -> Int { lock.withLock { stopCount } }
    func getMetadataUpdates() -> [[String: String]] { lock.withLock { metadataUpdates } }
    func getConfiguration() -> BonjourPublisher.Configuration? { lock.withLock { configuration } }
    
    func start(with config: BonjourPublisher.Configuration) {
        lock.withLock {
            startCount += 1
            configuration = config
        }
    }
    
    func stop() {
        lock.withLock {
            stopCount += 1
            configuration = nil
        }
    }
    
    func updateTXTRecord(_ metadata: [String : String]) {
        lock.withLock {
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
}

final class MockBonjourPublisher: BonjourPublishing {
    let state = MockBonjourPublisherState()

    var startCount: Int { state.getStartCount() }
    var stopCount: Int { state.getStopCount() }
    var metadataUpdates: [[String: String]] { state.getMetadataUpdates() }
    
    var currentConfiguration: BonjourPublisher.Configuration? { state.getConfiguration() }
    
    var currentEndpoint: LanEndpoint? {
        guard let configuration = state.getConfiguration() else { return nil }
        return LanEndpoint(
            host: "localhost",
            port: configuration.port,
            deviceId: configuration.deviceId,
            deviceName: configuration.serviceName,
            fingerprint: configuration.fingerprint
        )
    }

    func start(with configuration: BonjourPublisher.Configuration) {
        state.start(with: configuration)
    }

    func stop() {
        state.stop()
    }
    
    func stop(completion: @escaping () -> Void) {
        stop()
        completion()
    }

    func updateTXTRecord(_ metadata: [String : String]) {
        state.updateTXTRecord(metadata)
    }
}

final class InMemoryLanDiscoveryCache: LanDiscoveryCache, @unchecked Sendable {
    var storage: [String: Date] = [:]
    var peerStorage: [String: DiscoveredPeer] = [:]

    func load() -> [String : Date] {
        storage
    }

    func save(_ lastSeen: [String : Date]) {
        storage = lastSeen
    }

    func loadPeers() -> [String : DiscoveredPeer] {
        peerStorage
    }

    func savePeers(_ peers: [String : DiscoveredPeer]) {
        peerStorage = peers
    }
}

final class MockTransportProviderState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    fileprivate var onIncomingMessage: (@Sendable (Data, TransportOrigin) async -> Void)?
    
    func setHandler(_ handler: @escaping @Sendable (Data, TransportOrigin) async -> Void) {
        lock.withLock { onIncomingMessage = handler }
    }
    
    func getHandler() -> (@Sendable (Data, TransportOrigin) async -> Void)? {
        lock.withLock { onIncomingMessage }
    }
    
    func hasHandler() -> Bool {
        lock.withLock { onIncomingMessage != nil }
    }
}

final class MockTransportProvider: TransportProvider {
    let state = MockTransportProviderState()
    
    func preferredTransport() -> SyncTransport {
        MockSyncTransport()
    }
    
    func getCloudTransport() -> SyncTransport {
        MockSyncTransport()
    }
    
    func setGetDiscoveredPeers(_ getter: @escaping () -> [DiscoveredPeer]) {}
    
    func setCloudIncomingMessageHandler(_ handler: @escaping @Sendable (Data, TransportOrigin) async -> Void) {
        state.setHandler(handler)
    }
    
    func simulateIncomingMessage(data: Data, origin: TransportOrigin) async {
        let handler = state.getHandler()
        await handler?(data, origin)
    }
    
    var hasCloudIncomingMessageHandler: Bool { state.hasHandler() }
}

struct MockSyncTransport: SyncTransport {
    func connect() async throws {}
    func send(_ envelope: SyncEnvelope) async throws {}
    func disconnect() async {}
    func isConnected() -> Bool { false }
}

@MainActor
final class MockNotificationController: ClipboardNotificationScheduling {
    struct StatusNotification: Equatable {
        let deviceId: String
        let title: String
        let body: String
    }

    private(set) var deliveredEntries: [ClipboardEntry] = []
    private(set) var statusNotifications: [StatusNotification] = []

    func configure(handler: ClipboardNotificationHandling) {}
    func requestAuthorizationIfNeeded() {}
    func deliverNotification(for entry: ClipboardEntry) {
        deliveredEntries.append(entry)
    }

    func deliverStatusNotification(deviceId: String, title: String, body: String) {
        statusNotifications.append(.init(deviceId: deviceId, title: title, body: body))
    }
}

@MainActor
func makeWebSocketServer() -> LanWebSocketServer {
    LanWebSocketServer(enableHeartbeat: false)
}
