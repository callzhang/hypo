import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@_spi(Testing) @testable import HypoApp

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

    @Test
    func testConnectStripsQueryParametersForLan() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com/ws?query=param")!, pinnedFingerprint: nil, environment: "lan"),
            sessionFactory: { _, _ in session }
        ) }

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()

        let requestURL = stubTask.createdRequest?.url?.absoluteString
        #expect(requestURL == "ws://example.com/ws")
    }

    @Test
    func testConnectPreservesQueryParametersForCloud() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com/ws?query=param")!, pinnedFingerprint: nil, environment: "cloud"),
            sessionFactory: { _, _ in session }
        ) }

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()

        let requestURL = stubTask.createdRequest?.url?.absoluteString
        #expect(requestURL == "wss://example.com/ws?query=param")
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
    func testProcessMessageQueueRequeuesOnCancellationThenSends() async throws {
        let task = FlakyWebSocketTask()
        task.sendErrors = [CancellationError(), nil]
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )
        transport._testing_setStateConnected(task)

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data(), tag: Data())
        ))
        let queued = WebSocketTransport.QueuedMessage(
            envelope: envelope,
            data: try TransportFrameCodec().encode(envelope),
            queuedAt: Date(),
            retryCount: 0
        )
        await MainActor.run {
            transport.messageQueue = [queued]
        }

        await transport._testing_triggerQueueProcessingIfNeeded()

        let fulfilled = await waitUntil(timeout: .seconds(1)) {
            transport.messageQueue.isEmpty && task.sentData.count == 1
        }
        #expect(fulfilled)
    }
    
    @Test
    func testSleepModeBehavesCorrectly() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            sessionFactory: { _, _ in session }
        )
        
        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }
        
        try await transport.connect()
        #expect(transport.isConnected())
        
        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data(),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data(), tag: Data())
        ))
        let queued = WebSocketTransport.QueuedMessage(
            envelope: envelope,
            data: try TransportFrameCodec().encode(envelope),
            queuedAt: Date(),
            retryCount: 0
        )
        await MainActor.run {
            transport.messageQueue = [queued]
        }
        
        // Enter sleep mode
        await transport.enterSleepMode()
        
        // State update should be immediate, but queue cancellation might be async
        #expect(transport.isConnected() == false)
        
        let queueCount = await MainActor.run { transport.messageQueue.count }
        #expect(queueCount == 1)
        
        // Exit sleep mode
        await transport.exitSleepMode()
        
        // Should attempt reconnect
        try await Task.sleep(nanoseconds: 100_000_000)
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
        
        async let _ = transport.queryConnectedPeers()
        
        let fulfilled = await waitUntil(timeout: .seconds(1)) {
            stubTask.sentData.count > 0
        }
        #expect(fulfilled)
        
        let sent = try #require(stubTask.sentData.first)
        let sentString = String(data: sent, encoding: .utf8) ?? ""
        #expect(sentString.contains("query_connected_peers"))
    }

    @Test
    func testQueryConnectedPeersReturnsEmptyWhenNotConnected() async {
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil, environment: "cloud")
        )

        let peers = await transport.queryConnectedPeers()
        #expect(peers.isEmpty)
    }

    @Test
    func testQueryConnectedPeersSendFailureReturnsEmpty() async {
        let stubTask = StubWebSocketTask()
        stubTask.sendError = NSError(domain: NSPOSIXErrorDomain, code: 57, userInfo: nil)
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil, environment: "cloud"),
            sessionFactory: { _, _ in session }
        ) }

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try? await transport.connect()
        let peers = await transport.queryConnectedPeers()
        #expect(peers.isEmpty)
    }

    @Test
    func testQueryConnectedPeersReturnsDevices() async throws {
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

        async let response = transport.queryConnectedPeers(["peer-a", "peer-b"])

        let sent = await waitUntil(timeout: .seconds(1)) {
            stubTask.sentData.count == 1
        }
        #expect(sent)

        let sentData = try #require(stubTask.sentData.first)
        let queryId = jsonObject(from: sentData)?["id"] as? String
        #expect(queryId != nil)

        let responsePayload: [String: Any] = [
            "id": UUID().uuidString,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "version": "1.0",
            "type": "control",
            "payload": [
                "action": "query_connected_peers",
                "original_message_id": queryId ?? "",
                "connected_devices": ["peer-a", "peer-b"]
            ]
        ]

        let framed = lengthPrefixedJSON(responsePayload)
        stubTask.receiveHandler?(.success(.data(framed)))

        let peers = await response
        #expect(peers == ["peer-a", "peer-b"])
    }

    @Test
    func testQueryConnectedPeersReturnsEmptyForLan() async {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan"),
            sessionFactory: { _, _ in session }
        )

        let peers = await transport.queryConnectedPeers()
        #expect(peers.isEmpty)
    }

    @Test
    func testPermanentErrorDropsInFlightMessage() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let codec = TransportFrameCodec()
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil, environment: "cloud"),
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
        let payload = try codec.encode(envelope)
        let queued = WebSocketTransport.QueuedMessage(
            envelope: envelope,
            data: payload,
            queuedAt: Date(),
            retryCount: 0
        )
        await MainActor.run {
            transport.inFlightMessages[envelope.id] = queued
        }

        let errorPayload: [String: Any] = [
            "type": "error",
            "payload": [
                "code": "device_not_connected",
                "message": "offline",
                "original_message_id": envelope.id.uuidString
            ]
        ]
        let framed = lengthPrefixedJSON(errorPayload)
        stubTask.receiveHandler?(.success(.data(framed)))

        let inFlightCount = await MainActor.run { transport.inFlightMessages.count }
        let queueCount = await MainActor.run { transport.messageQueue.count }
        #expect(inFlightCount == 0)
        #expect(queueCount == 0)
    }

    @Test
    func testAckRemovesInFlightMessage() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let codec = TransportFrameCodec()
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
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
        let payload = try codec.encode(envelope)
        let queued = WebSocketTransport.QueuedMessage(
            envelope: envelope,
            data: payload,
            queuedAt: Date(),
            retryCount: 0
        )
        await MainActor.run {
            transport.inFlightMessages[envelope.id] = queued
        }

        stubTask.receiveHandler?(.success(.data(payload)))

        let inFlightCount = await MainActor.run { transport.inFlightMessages.count }
        #expect(inFlightCount == 0)
    }

    @Test
    func testHandleIncomingDropsPermanentError() async throws {
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data([0x02]), tag: Data([0x03]))
        ))
        let queued = WebSocketTransport.QueuedMessage(
            envelope: envelope,
            data: try TransportFrameCodec().encode(envelope),
            queuedAt: Date(),
            retryCount: 0
        )
        await MainActor.run {
            transport.inFlightMessages[envelope.id] = queued
        }

        let errorPayload: [String: Any] = [
            "type": "error",
            "payload": [
                "code": "device_not_connected",
                "message": "offline",
                "original_message_id": envelope.id.uuidString
            ]
        ]
        let framed = lengthPrefixedJSON(errorPayload)
        transport._testing_handleIncoming(framed)

        let inFlightCount = await MainActor.run { transport.inFlightMessages.count }
        #expect(inFlightCount == 0)
    }

    @Test
    func testHandleIncomingRequeuesTransientError() async throws {
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )
        let holdTask = Task {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
        }
        transport._testing_setQueueProcessingTask(holdTask)

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data([0x02]), tag: Data([0x03]))
        ))
        let queued = WebSocketTransport.QueuedMessage(
            envelope: envelope,
            data: try TransportFrameCodec().encode(envelope),
            queuedAt: Date(),
            retryCount: 0
        )
        await MainActor.run {
            transport.inFlightMessages[envelope.id] = queued
        }

        let errorPayload: [String: Any] = [
            "type": "error",
            "payload": [
                "code": "server_error",
                "message": "retry",
                "original_message_id": envelope.id.uuidString
            ]
        ]
        let framed = lengthPrefixedJSON(errorPayload)
        transport._testing_handleIncoming(framed)

        let queueCount = await MainActor.run { transport.messageQueue.count }
        #expect(queueCount == 1)
        let retryCount = await MainActor.run { transport.messageQueue.first?.retryCount ?? 0 }
        #expect(retryCount == 1)
    }

    @Test
    func testHandleIncomingControlRoutingFailure() async {
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )
        let control: [String: Any] = [
            "type": "control",
            "payload": [
                "action": "routing_failure",
                "reason": "offline",
                "target_device_id": "peer"
            ]
        ]
        transport._testing_handleIncoming(lengthPrefixedJSON(control))
    }

    @Test
    func testHandleIncomingControlQueryConnectedPeersResolves() async {
        let stubTask = StubWebSocketTask()
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil, environment: "cloud")
        )
        transport._testing_setStateConnected(stubTask)

        async let response = transport.queryConnectedPeers(["peer-a"])

        let sent = await waitUntil(timeout: .seconds(1)) {
            stubTask.sentData.count == 1
        }
        #expect(sent)
        let sentData = stubTask.sentData.first ?? Data()
        let json = jsonObject(from: sentData) ?? [:]
        let queryId = json["id"] as? String ?? ""

        let payload: [String: Any] = [
            "type": "control",
            "payload": [
                "action": "query_connected_peers",
                "original_message_id": queryId,
                "connected_devices": ["peer-a"]
            ]
        ]
        transport._testing_handleIncoming(lengthPrefixedJSON(payload))

        let peers = await response
        #expect(peers == ["peer-a"])
    }

    @Test
    func testReceiveNextFailureMarksDisconnected() async {
        let stubTask = StubWebSocketTask()
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )
        transport._testing_setStateConnected(stubTask)
        transport._testing_receiveNext(on: stubTask)

        let error = NSError(domain: NSPOSIXErrorDomain, code: 57, userInfo: nil)
        stubTask.receiveHandler?(.failure(error))

        #expect(transport.isConnected() == false)
    }

    @Test
    func testCloseDueToIdleCancelsTask() async {
        let stubTask = StubWebSocketTask()
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )
        transport._testing_setStateConnected(stubTask)

        let cancelled = Locked(false)
        stubTask.onCancel = { _, _ in
            cancelled.withLock { $0 = true }
        }

        await transport._testing_closeDueToIdle(task: stubTask)
        #expect(cancelled.withLock { $0 })
        #expect(transport.isConnected() == false)
    }

    @Test
    func testDisconnectClearsQueuedMessages() async {
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data(),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data(), tag: Data())
        ))
        let queued = WebSocketTransport.QueuedMessage(
            envelope: envelope,
            data: (try? TransportFrameCodec().encode(envelope)) ?? Data(),
            queuedAt: Date(),
            retryCount: 0
        )

        await MainActor.run {
            transport.messageQueue = [queued]
        }

        await transport.disconnect()
        let queueCount = await MainActor.run { transport.messageQueue.count }
        #expect(queueCount == 0)
    }

    @Test
    func testHandleIncomingControlQueryConnectedPeersWithoutContinuation() async {
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil, environment: "cloud")
        )
        let payload: [String: Any] = [
            "type": "control",
            "payload": [
                "action": "query_connected_peers",
                "original_message_id": UUID().uuidString
            ]
        ]
        transport._testing_handleIncoming(lengthPrefixedJSON(payload))
    }

    @Test
    func testHandleIncomingWithInvalidDataDoesNotCrash() async {
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )
        let garbage = Data([0, 0, 0, 1, 0xFF])
        transport._testing_handleIncoming(garbage)
    }

    @Test
    func testReceiveNextHandlesStringMessage() async {
        let stubTask = StubWebSocketTask()
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )
        transport._testing_setStateConnected(stubTask)
        transport._testing_receiveNext(on: stubTask)

        stubTask.receiveHandler?(.success(.string("hello")))
        #expect(transport.isConnected())
    }

    @Test
    func testDidCloseWithClearsInFlightMessages() async {
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data(),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data(), tag: Data())
        ))
        let queued = WebSocketTransport.QueuedMessage(
            envelope: envelope,
            data: (try? TransportFrameCodec().encode(envelope)) ?? Data(),
            queuedAt: Date(),
            retryCount: 0
        )
        await MainActor.run {
            transport.inFlightMessages[envelope.id] = queued
        }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "wss://example.com")!)
        transport.urlSession(session, webSocketTask: task, didCloseWith: .goingAway, reason: Data("bye".utf8))

        let inFlightCount = await MainActor.run { transport.inFlightMessages.count }
        #expect(inFlightCount == 0)
    }

    @Test
    func testDidCompleteWithErrorIgnoresStaleTask() async {
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )
        let session = URLSession(configuration: .ephemeral)
        let currentTask = session.webSocketTask(with: URL(string: "wss://example.com")!)
        let staleTask = session.webSocketTask(with: URL(string: "wss://example.com")!)
        transport._testing_setStateConnected(currentTask)

        transport.urlSession(session, task: staleTask, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: -1))

        #expect(transport.isConnected())
    }

    @Test
    func testDidCompleteWithErrorResetsState() async {
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )
        let session = URLSession(configuration: .ephemeral)
        let currentTask = session.webSocketTask(with: URL(string: "wss://example.com")!)
        transport._testing_setStateConnected(currentTask)

        transport.urlSession(session, task: currentTask, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: -1))

        #expect(transport.isConnected() == false)
    }

    @Test
    func testConnectReturnsWhenAlreadyConnected() async throws {
        let stubTask = StubWebSocketTask()
        let transport = WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        )
        transport._testing_setStateConnected(stubTask)

        try await transport.connect()
        #expect(transport.isConnected())
        await transport.disconnect()
    }

    @Test
    func testConnectWhileConnectingWaitsForHandshake() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            sessionFactory: { _, _ in session }
        ) }

        transport._testing_setStateConnecting()
        let connectTask = Task { try await transport.connect() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        transport.handleOpen(task: stubTask)
        try await connectTask.value
        #expect(transport.isConnected())
        await transport.disconnect()
    }

    @Test
    func testLargeMessageTriggersPingBeforeSend() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { WebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            sessionFactory: { _, _ in session }
        ) }

        let pinged = Locked(false)
        stubTask.onPing = {
            pinged.withLock { $0 = true }
        }
        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()

        let payload = Data(repeating: 0xAB, count: 150_000)
        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .file,
            ciphertext: payload,
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data(), tag: Data())
        ))
        try await transport.send(envelope)

        let fulfilled = await waitUntil(timeout: .seconds(10)) {
            pinged.withLock { $0 }
        }
        #expect(fulfilled)
    }
}

private func lengthPrefixedJSON(_ object: [String: Any]) -> Data {
    let jsonData = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    var length = UInt32(jsonData.count).bigEndian
    var data = Data()
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(jsonData)
    return data
}

private func jsonObject(from data: Data) -> [String: Any]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}
