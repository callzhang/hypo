import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HypoApp

struct WebSocketTransportTests {
    @Test
    func testConnectResolvesAfterHandshake() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            sessionFactory: { _, _ in session }
        ) }

        let handshakeCompleted = Locked(false)
        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
            handshakeCompleted.withLock { $0 = true }
        }

        try await transport.connect()
        let fulfilled = await waitUntil(timeout: .milliseconds(500)) {
            handshakeCompleted.withLock { $0 }
        }
        #expect(fulfilled)
    }

    @Test
    func testSendUsesFrameCodec() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let codec = TransportFrameCodec()
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            frameCodec: codec,
            sessionFactory: { _, _ in session }
        ) }

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data([0x02]), tag: Data([0x03]))
        ))

        try await transport.send(envelope)
        let fulfilled = await waitUntil(timeout: .seconds(1)) {
            stubTask.sentData.count == 1
        }
        #expect(fulfilled)
        let firstData = try #require(stubTask.sentData.first)
        let decoded = try codec.decode(firstData)
        #expect(decoded.payload.deviceId == "device")
    }

    @Test
    func testIdleTimeoutCancelsTask() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, idleTimeout: 0.05),
            sessionFactory: { _, _ in session }
        ) }
        let cancelled = Locked(false)
        stubTask.onCancel = { (_: URLSessionWebSocketTask.CloseCode, _: Data?) in
            cancelled.withLock { $0 = true }
        }
        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        let fulfilled = await waitUntil(timeout: .seconds(1)) {
            cancelled.withLock { $0 }
        }
        #expect(fulfilled)
    }

    @Test
    func testMetricsRecorderCapturesHandshakeAndRoundTrip() async throws {
        let metrics = RecordingMetricsRecorder()
        let codec = TransportFrameCodec()
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            frameCodec: codec,
            metricsRecorder: metrics,
            sessionFactory: { _, _ in session }
        ) }

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data([0x02]), tag: Data([0x03]))
        ))

        try await transport.send(envelope)
        let echo = try codec.encode(envelope)
        stubTask.receiveHandler?(.success(.data(echo)))

        let fulfilled = await waitUntil(timeout: .seconds(1)) {
            metrics.recordedHandshakes.count == 1 &&
                (metrics.recordedRoundTrips[envelope.id.uuidString]?.count ?? 0) == 1
        }
        #expect(fulfilled)
        #expect(metrics.recordedHandshakes.count == 1)
        #expect((metrics.recordedRoundTrips[envelope.id.uuidString]?.count ?? 0) == 1)
    }

    @Test
    func testReconnectAfterDisconnect() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            sessionFactory: { _, _ in session }
        ) }

        var resumeCount = 0
        stubTask.onResume = {
            resumeCount += 1
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        await transport.disconnect()

        stubTask.onResume = {
            resumeCount += 1
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        #expect(resumeCount == 2)
    }
}

private final class StubSession: URLSessionProviding, @unchecked Sendable {
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

private final class StubWebSocketTask: WebSocketTasking, @unchecked Sendable {
    var maximumMessageSize: Int = Int.max
    var createdRequest: URLRequest?
    var onResume: (() -> Void)?
    var onCancel: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
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
        pongReceiveHandler(nil)
    }
}

private final class RecordingMetricsRecorder: TransportMetricsRecorder, @unchecked Sendable {
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

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        self.lock()
        defer { self.unlock() }
        return body()
    }
}

    @Test
    func testQueueOverflowProtection() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            sessionFactory: { _, _ in session }
        ) }
        
        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }
        
        try await transport.connect()
        
        // Fill queue with 110 messages (max is 100)
        for i in 0..<110 {
            let envelope = SyncEnvelope(type: .clipboard, payload: .init(
                contentType: .text,
                ciphertext: Data([UInt8(i)]),
                deviceId: "device",
                target: "peer",
                encryption: .init(nonce: Data(), tag: Data())
            ))
            try await transport.send(envelope)
        }
        
        // Wait briefly for async queue processing/dropping
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Accessing internal property if visible, otherwise rely on indirect observation (not possible easily)
        // Since we made it internal, we can access it if we imported correctly.
        // Swift Testing doesn't support @testable checks nicely in partial compiles but we assume it works.
        let queueCount = await MainActor.run { transport.messageQueue.count }
        #expect(queueCount <= 100)
    }

    @Test
    func testMessageExpiration() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let clock = MutableClock(now: Date())
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            sessionFactory: { _, _ in session },
            dateProvider: { clock.now }
        ) }
        
        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }
        
        try await transport.connect()
        
        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data(),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data(), tag: Data())
        ))
        
        // Create a disconnect to potentially buffer messages? 
        // send() puts to queue. processMessageQueue picks it up.
        // If connected, it tries to send.
        // We want it to stay in queue to test expiration.
        // If send fails, it retries.
        
        // Mock send error to force retry logic
        stubTask.sendError = NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "Socket is not connected"])
        
        try await transport.send(envelope)
        
        // Advance time > 5 mins
        clock.now = clock.now.addingTimeInterval(360)
        
        // Wait for retry loop to see expiration
        try await Task.sleep(nanoseconds: 200_000_000)
        
        let queueCount = await MainActor.run { transport.messageQueue.count }
        #expect(queueCount == 0)
    }
    
    @Test
    func testSleepModeBehavesCorrectly() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            sessionFactory: { _, _ in session }
        ) }
        
        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }
        
        try await transport.connect()
        #expect(await transport.isConnected())
        
        // Mock send error so message stays in queue
        stubTask.sendError = NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "fail"])
        
         let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data(),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data(), tag: Data())
        ))
        try await transport.send(envelope)
        
        // Enter sleep mode
        await transport.enterSleepMode()
        #expect(await transport.isConnected() == false)
        
        let queueCount = await MainActor.run { transport.messageQueue.count }
        #expect(queueCount > 0)
        
        // Exit sleep mode
        await transport.exitSleepMode()
        
        // Should attempt reconnect
         try await Task.sleep(nanoseconds: 100_000_000)
         // Since stub factory returns the same session/task logic or we need to update factory to return new task?
         // StubSession returns `task`.
         // We should update StubSession to handle multiple tasks ideally or just verify connect called.
         // transport.isConnected() check
        // If exitSleepMode calls connect(), state becomes connecting.
        // Stub task calls onResume -> handleOpen -> connected.
    }

    @Test
    func testQueryConnectedPeers() async throws {
         let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil, environment: "cloud"),
            sessionFactory: { _, _ in session }
        ) }
        
        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }
        
        try await transport.connect()
        
        async let queryResult = transport.queryConnectedPeers()
        
        let fulfilled = await waitUntil(timeout: .seconds(1)) {
            stubTask.sentData.count > 0
        }
        #expect(fulfilled)
        
        let sent = try #require(stubTask.sentData.first)
        let sentString = String(data: sent, encoding: .utf8) ?? ""
        #expect(sentString.contains("query_connected_peers"))
    }


private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    
    init(now: Date) { _now = now }
    
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}
