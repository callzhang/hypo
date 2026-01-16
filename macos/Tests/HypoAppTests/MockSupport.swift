import Foundation
import Testing
import Network
@testable import HypoApp

final class MockBonjourDriver: BonjourBrowsingDriver, @unchecked Sendable {
    private var handler: (@Sendable (BonjourBrowsingDriverEvent) -> Void)?
    private(set) var startCount = 0

    func startBrowsing(serviceType: String, domain: String) {
        startCount += 1
    }

    func stopBrowsing() {
        startCount = max(0, startCount - 1)
    }

    func setEventHandler(_ handler: @escaping @Sendable (BonjourBrowsingDriverEvent) -> Void) {
        self.handler = handler
    }

    func emit(_ event: BonjourBrowsingDriverEvent) {
        handler?(event)
    }
}

final class MockBonjourPublisher: BonjourPublishing {
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
            deviceId: configuration.deviceId,
            deviceName: configuration.serviceName,
            fingerprint: configuration.fingerprint
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
    
    func stop(completion: @escaping () -> Void) {
        stop()
        completion()
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

final class MockTransportProvider: TransportProvider {
    private var _onIncomingMessage: ((Data, TransportOrigin) async -> Void)?
    
    func preferredTransport() -> SyncTransport {
        MockSyncTransport()
    }
    
    func getCloudTransport() -> SyncTransport {
        MockSyncTransport()
    }
    
    func setGetDiscoveredPeers(_ getter: @escaping () -> [DiscoveredPeer]) {}
    
    func setCloudIncomingMessageHandler(_ handler: @escaping (Data, TransportOrigin) async -> Void) {
        _onIncomingMessage = handler
    }
    
    func simulateIncomingMessage(data: Data, origin: TransportOrigin) async {
        await _onIncomingMessage?(data, origin)
    }
    
    var hasCloudIncomingMessageHandler: Bool { _onIncomingMessage != nil }
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

    private(set) var statusNotifications: [StatusNotification] = []

    func configure(handler: ClipboardNotificationHandling) {}
    func requestAuthorizationIfNeeded() {}
    func deliverNotification(for entry: ClipboardEntry) {}

    func deliverStatusNotification(deviceId: String, title: String, body: String) {
        statusNotifications.append(.init(deviceId: deviceId, title: title, body: body))
    }
}

final class StubSession: URLSessionProviding, @unchecked Sendable {
    private let task: StubWebSocketTask

    init(task: StubWebSocketTask) {
        self.task = task
    }

    func webSocketTask(with request: URLRequest) -> WebSocketTasking {
        task.createdRequest = request
        return task
    }

    func invalidateAndCancel() {}
}

final class StubWebSocketTask: WebSocketTasking, @unchecked Sendable {
    var maximumMessageSize: Int = Int.max
    var createdRequest: URLRequest?
    var onResume: (() -> Void)?
    var onCancel: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    var onPing: (() -> Void)?
    var sentData: [Data] = []
    var receiveHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    var sendError: Error?

    func resume() {
        onResume?()
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        if let error = sendError {
            completionHandler(error)
            return
        }
        switch message {
        case .data(let data):
            sentData.append(data)
        case .string(let string):
            if let data = string.data(using: .utf8) {
                sentData.append(data)
            }
        @unknown default:
            break
        }
        completionHandler(nil)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onCancel?(closeCode, reason)
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiveHandler = completionHandler
    }

    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
        onPing?()
        pongReceiveHandler(nil)
    }
}

final class FlakyWebSocketTask: WebSocketTasking, @unchecked Sendable {
    var maximumMessageSize: Int = Int.max
    var createdRequest: URLRequest?
    var onResume: (() -> Void)?
    var onCancel: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    var onPing: (() -> Void)?
    var sentData: [Data] = []
    var receiveHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    var sendErrors: [Error?] = []

    func resume() {
        onResume?()
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        if !sendErrors.isEmpty {
            let nextError = sendErrors.removeFirst()
            if let nextError {
                completionHandler(nextError)
                return
            }
        }
        switch message {
        case .data(let data):
            sentData.append(data)
        case .string(let string):
            if let data = string.data(using: .utf8) {
                sentData.append(data)
            }
        @unknown default:
            break
        }
        completionHandler(nil)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onCancel?(closeCode, reason)
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        receiveHandler = completionHandler
    }

    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
        onPing?()
        pongReceiveHandler(nil)
    }
}

final class RecordingMetricsRecorder: TransportMetricsRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var _handshakes: [TimeInterval] = []
    private var _roundTrips: [String: [TimeInterval]] = [:]

    var recordedHandshakes: [TimeInterval] { lock.withLock { _handshakes } }
    var recordedRoundTrips: [String: [TimeInterval]] { lock.withLock { _roundTrips } }

    func recordHandshake(duration: TimeInterval, timestamp: Date) {
        lock.withLock { _handshakes.append(duration) }
    }

    func recordRoundTrip(envelopeId: String, duration: TimeInterval) {
        lock.withLock {
            var durations = _roundTrips[envelopeId, default: []]
            durations.append(duration)
            _roundTrips[envelopeId] = durations
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        self.lock()
        defer { self.unlock() }
        return body()
    }
}

@MainActor
func makeWebSocketServer() -> LanWebSocketServer {
    LanWebSocketServer(enableHeartbeat: false)
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    
    init(now: Date) { _now = now }
    
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
    
    func advance(to newValue: Date) {
        lock.withLock { _now = newValue }
    }
}
