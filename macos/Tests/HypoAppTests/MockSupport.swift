import Foundation
import Testing
import Network
import os
@testable import HypoApp

final class MockBonjourDriverState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var handler: (@Sendable (BonjourBrowsingDriverEvent) -> Void)?
    fileprivate var startCount = 0
    
    func incrementStartCount() { lock.withLock { startCount += 1 } }
    func decrementStartCount() { lock.withLock { startCount = max(0, startCount - 1) } }
    func getStartCount() -> Int { lock.withLock { startCount } }
    
    func setHandler(_ handler: @escaping @Sendable (BonjourBrowsingDriverEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }
    
    func emit(_ event: BonjourBrowsingDriverEvent) {
        let h = lock.withLock { handler }
        h?(event)
    }
}

final class MockBonjourDriver: BonjourBrowsingDriver, @unchecked Sendable {
    let state = MockBonjourDriverState()
    
    var startCount: Int { state.getStartCount() }

    func startBrowsing(serviceType: String, domain: String) {
        state.incrementStartCount()
    }

    func stopBrowsing() {
        state.decrementStartCount()
    }

    func setEventHandler(_ handler: @escaping @Sendable (BonjourBrowsingDriverEvent) -> Void) {
        state.setHandler(handler)
    }

    func emit(_ event: BonjourBrowsingDriverEvent) {
        state.emit(event)
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
    private let lock = NSLock()
    private var _maximumMessageSize: Int = Int.max
    private var _createdRequest: URLRequest?
    private var _onResume: (() -> Void)?
    private var _onCancel: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    private var _onPing: (() -> Void)?
    private var _sentData: [Data] = []
    private var _receiveHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var _sendError: Error?

    var maximumMessageSize: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _maximumMessageSize
        }
        set {
            lock.lock()
            _maximumMessageSize = newValue
            lock.unlock()
        }
    }
    
    var createdRequest: URLRequest? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _createdRequest
        }
        set {
            lock.lock()
            _createdRequest = newValue
            lock.unlock()
        }
    }
    
    var onResume: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onResume
        }
        set {
            lock.lock()
            _onResume = newValue
            lock.unlock()
        }
    }
    
    var onCancel: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onCancel
        }
        set {
            lock.lock()
            _onCancel = newValue
            lock.unlock()
        }
    }
    
    var onPing: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onPing
        }
        set {
            lock.lock()
            _onPing = newValue
            lock.unlock()
        }
    }
    
    var sentData: [Data] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _sentData
        }
        set {
            lock.lock()
            _sentData = newValue
            lock.unlock()
        }
    }
    
    var receiveHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _receiveHandler
        }
        set {
            lock.lock()
            _receiveHandler = newValue
            lock.unlock()
        }
    }
    
    var sendError: Error? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _sendError
        }
        set {
            lock.lock()
            _sendError = newValue
            lock.unlock()
        }
    }

    func resume() {
        lock.lock()
        let callback = _onResume
        lock.unlock()
        callback?()
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        lock.lock()
        if let error = _sendError {
            lock.unlock()
            completionHandler(error)
            return
        }
        switch message {
        case .data(let data):
            _sentData.append(data)
        case .string(let string):
            if let data = string.data(using: .utf8) {
                _sentData.append(data)
            }
        @unknown default:
            break
        }
        lock.unlock()
        completionHandler(nil)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        let callback = _onCancel
        lock.unlock()
        callback?(closeCode, reason)
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        lock.lock()
        _receiveHandler = completionHandler
        lock.unlock()
    }

    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
        lock.lock()
        let callback = _onPing
        lock.unlock()
        callback?()
        pongReceiveHandler(nil)
    }
}

final class FlakyWebSocketTask: WebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private var _maximumMessageSize: Int = Int.max
    private var _createdRequest: URLRequest?
    private var _onResume: (() -> Void)?
    private var _onCancel: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    private var _onPing: (() -> Void)?
    private var _sentData: [Data] = []
    private var _receiveHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?
    private var _sendErrors: [Error?] = []
    
    var maximumMessageSize: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _maximumMessageSize
        }
        set {
            lock.lock()
            _maximumMessageSize = newValue
            lock.unlock()
        }
    }
    
    var createdRequest: URLRequest? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _createdRequest
        }
        set {
            lock.lock()
            _createdRequest = newValue
            lock.unlock()
        }
    }
    
    var onResume: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onResume
        }
        set {
            lock.lock()
            _onResume = newValue
            lock.unlock()
        }
    }
    
    var onCancel: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onCancel
        }
        set {
            lock.lock()
            _onCancel = newValue
            lock.unlock()
        }
    }
    
    var onPing: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onPing
        }
        set {
            lock.lock()
            _onPing = newValue
            lock.unlock()
        }
    }
    
    var sentData: [Data] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _sentData
        }
        set {
            lock.lock()
            _sentData = newValue
            lock.unlock()
        }
    }
    
    var receiveHandler: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _receiveHandler
        }
        set {
            lock.lock()
            _receiveHandler = newValue
            lock.unlock()
        }
    }
    
    var sendErrors: [Error?] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _sendErrors
        }
        set {
            lock.lock()
            _sendErrors = newValue
            lock.unlock()
        }
    }

    func resume() {
        lock.lock()
        let callback = _onResume
        lock.unlock()
        callback?()
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        lock.lock()
        if !_sendErrors.isEmpty {
            let nextError = _sendErrors.removeFirst()
            if let nextError {
                lock.unlock()
                completionHandler(nextError)
                return
            }
        }
        
        switch message {
        case .data(let data):
            _sentData.append(data)
        case .string(let string):
            if let data = string.data(using: .utf8) {
                _sentData.append(data)
            }
        @unknown default:
            break
        }
        lock.unlock()
        completionHandler(nil)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        let callback = _onCancel
        lock.unlock()
        callback?(closeCode, reason)
    }

    func receive(completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        lock.lock()
        _receiveHandler = completionHandler
        lock.unlock()
    }

    func sendPing(pongReceiveHandler: @escaping (Error?) -> Void) {
        lock.lock()
        let callback = _onPing
        lock.unlock()
        callback?()
        pongReceiveHandler(nil)
    }
}

final class RecordingMetricsRecorder: TransportMetricsRecorder, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
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


@MainActor
func makeWebSocketServer() -> LanWebSocketServer {
    LanWebSocketServer(enableHeartbeat: false)
}

final class MutableClock: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
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
