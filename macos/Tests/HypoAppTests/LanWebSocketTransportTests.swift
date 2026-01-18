import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@_spi(Testing) @testable import HypoApp

struct LanWebSocketTransportTests {
    @Test
    func testConnectResolvesAfterHandshake() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { LanWebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com/ws?query=param")!, pinnedFingerprint: nil),
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
        await transport.disconnect()
    }

    @Test
    func testQueryParametersAreStrippedForLanConnections() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        // Use "ws" scheme to trigger LAN behavior (stripping query params)
        // "wss" scheme is treated as cloud connection which preserves params
        let transport = await MainActor.run { LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com/ws?query=param&other=value")!, pinnedFingerprint: nil, environment: "lan"),
            sessionFactory: { _, _ in session }
        ) }

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        
        // Wait for connection
        let connected = await waitUntil(timeout: .milliseconds(500)) {
            transport.isConnected()
        }
        #expect(connected)
        
        // Check the URL request used to create the task
        let requestURL = stubTask.createdRequest?.url?.absoluteString
        #expect(requestURL == "ws://example.com/ws")
        await transport.disconnect()
    }

    @Test
    func testQueryParametersPreservedForCloudConnections() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { LanWebSocketTransport(
            configuration: .init(
                url: URL(string: "wss://example.com/ws?query=param&other=value")!,
                pinnedFingerprint: nil,
                environment: "cloud"
            ),
            sessionFactory: { _, _ in session }
        ) }

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()

        let requestURL = stubTask.createdRequest?.url?.absoluteString
        #expect(requestURL == "wss://example.com/ws?query=param&other=value")
        await transport.disconnect()
    }

    @Test
    func testSendUsesFrameCodec() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let codec = TransportFrameCodec()
        let transport = await MainActor.run { LanWebSocketTransport(
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
        await transport.disconnect()
    }

    // testIdleTimeoutCancelsTask removed as LanWebSocketTransport does not support idle timeout in LAN mode


    @Test
    func testMetricsRecorderCapturesHandshakeAndRoundTrip() async throws {
        let metrics = RecordingMetricsRecorder()
        let codec = TransportFrameCodec()
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { LanWebSocketTransport(
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
        await transport.disconnect()
    }

    @Test
    func testReceiveParsesAndDispatchesMessages() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let codec = TransportFrameCodec()
        let transport = await MainActor.run { LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan"),
            sessionFactory: { _, _ in session }
        ) }
        
        let receivedEnvelope = Locked<SyncEnvelope?>(nil)
        transport.setOnIncomingMessage { data, origin in
            if let envelope = try? codec.decode(data) {
                receivedEnvelope.withLock { $0 = envelope }
            }
        }

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        
        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0xAA]),
            deviceId: "sender",
            target: "receiver",
            encryption: .init(nonce: Data(), tag: Data())
        ))
        
        // Simulate receiving data
        let encoded = try codec.encode(envelope)
        stubTask.receiveHandler?(.success(.data(encoded)))
        
        let fulfilled = await waitUntil(timeout: .seconds(1)) {
            receivedEnvelope.withLock { $0 } != nil
        }
        #expect(fulfilled)
        
        let received = try #require(receivedEnvelope.withLock { $0 })
        #expect(received.payload.deviceId == "sender")
        await transport.disconnect()
    }

    @Test
    func testPingSendsPingFrame() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        // Set short keepalive interval
        let transport = await MainActor.run { LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan", keepaliveInterval: 0.1),
            sessionFactory: { _, _ in session }
        ) }

        stubTask.onResume = { [weak transport] in
            transport?.handleOpen(task: stubTask)
        }
        
        let pingSent = Locked(false)
        stubTask.onPing = {
            pingSent.withLock { $0 = true }
        }

        try await transport.connect()
        
        // Wait for keepalive interval
        try await Task.sleep(for: .milliseconds(200))
        
        let sent = pingSent.withLock { $0 }
        #expect(sent)
        await transport.disconnect()
    }

    @Test
    func testCloudKeepaliveSendsPing() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { LanWebSocketTransport(
            configuration: .init(
                url: URL(string: "wss://example.com")!,
                pinnedFingerprint: nil,
                environment: "cloud",
                keepaliveInterval: 0.05
            ),
            sessionFactory: { _, _ in session }
        ) }

        let pingSent = Locked(false)
        stubTask.onPing = {
            pingSent.withLock { $0 = true }
        }

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()
        try await Task.sleep(nanoseconds: 150_000_000)

        let sent = pingSent.withLock { $0 }
        #expect(sent)
        await transport.disconnect()
    }

    @Test
    func testControlMessageIsIgnored() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { LanWebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil, environment: "cloud"),
            sessionFactory: { _, _ in session }
        ) }

        let received = Locked(0)
        transport.setOnIncomingMessage { _, _ in
            received.withLock { $0 += 1 }
        }

        stubTask.onResume = {
            transport.handleOpen(task: stubTask)
        }

        try await transport.connect()

        let controlMessage: [String: Any] = [
            "msg_type": "control",
            "payload": [
                "action": "routing_failure",
                "reason": "offline"
            ]
        ]
        let framed = lengthPrefixedJSON(controlMessage)
        stubTask.receiveHandler?(.success(.data(framed)))

        try await Task.sleep(nanoseconds: 50_000_000)
        let count = received.withLock { $0 }
        #expect(count == 0)
        await transport.disconnect()
    }

    @Test
    func testReconnectAfterDisconnect() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { LanWebSocketTransport(
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
        await transport.disconnect()
    }

    @Test
    func testReceiveFailureMarksDisconnected() async {
        let stubTask = StubWebSocketTask()
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan")
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
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan")
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
    func testConnectReturnsWhenAlreadyConnected() async throws {
        let stubTask = StubWebSocketTask()
        let transport = await MainActor.run { LanWebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        ) }

        transport._testing_setStateConnected(stubTask)
        try await transport.connect()
        #expect(transport.isConnected())
        await transport.disconnect()
    }

    @Test
    func testConnectWhileConnectingWaitsForHandshake() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { LanWebSocketTransport(
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
    func testProcessMessageQueueDropsTimedOutMessage() async throws {
        let transport = await MainActor.run { LanWebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil)
        ) }

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data([0x02]), tag: Data([0x03]))
        ))
        let data = try TransportFrameCodec().encode(envelope)
        transport._testing_enqueueQueuedMessage(
            envelope: envelope,
            data: data,
            queuedAt: Date(timeIntervalSinceNow: -700),
            retryCount: 0
        )

        await transport._testing_processMessageQueue()
        #expect(transport._testing_messageQueueCount() == 0)
    }

    @Test
    func testProcessMessageQueueRequeuesOnCancellationThenSends() async throws {
        let task = FlakyWebSocketTask()
        task.sendErrors = [CancellationError(), nil]
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan")
        )
        transport._testing_setStateConnected(task)

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data([0x02]), tag: Data([0x03]))
        ))
        let data = try TransportFrameCodec().encode(envelope)
        transport._testing_enqueueQueuedMessage(
            envelope: envelope,
            data: data,
            queuedAt: Date(),
            retryCount: 0
        )

        await transport._testing_processMessageQueue()
        #expect(transport._testing_messageQueueCount() == 0)
        #expect(task.sentData.count == 1)
    }

    @Test
    func testProcessMessageQueueRequeuesOnSocketNotConnectedThenSends() async throws {
        let task = FlakyWebSocketTask()
        task.sendErrors = [NSError(domain: NSPOSIXErrorDomain, code: 57, userInfo: [NSLocalizedDescriptionKey: "Socket is not connected"]), nil]
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan")
        )
        transport._testing_setStateConnected(task)

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x02]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data([0x04]), tag: Data([0x05]))
        ))
        let data = try TransportFrameCodec().encode(envelope)
        transport._testing_enqueueQueuedMessage(
            envelope: envelope,
            data: data,
            queuedAt: Date(),
            retryCount: 0
        )

        await transport._testing_processMessageQueue()
        #expect(transport._testing_messageQueueCount() == 0)
        #expect(task.sentData.count == 1)
    }

    @Test
    func testDisconnectClearsQueuedMessages() async throws {
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan")
        )

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x03]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data([0x06]), tag: Data([0x07]))
        ))
        let data = try TransportFrameCodec().encode(envelope)
        transport._testing_enqueueQueuedMessage(
            envelope: envelope,
            data: data,
            queuedAt: Date(),
            retryCount: 0
        )

        await transport.disconnect()
        #expect(transport._testing_messageQueueCount() == 0)
    }

    @Test
    func testDisconnectWhileConnectingCancelsHandshake() async {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { LanWebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            sessionFactory: { _, _ in session }
        ) }

        let connectTask = Task { try await transport.connect() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await transport.disconnect()
        await expectThrows { try await connectTask.value }
    }

    @Test
    func testReceiveFailureTriggersReconnectWithBackoff() async throws {
        let stubTask = StubWebSocketTask()
        let session = StubSession(task: stubTask)
        let transport = await MainActor.run { LanWebSocketTransport(
            configuration: .init(url: URL(string: "wss://example.com")!, pinnedFingerprint: nil),
            sessionFactory: { _, _ in session }
        ) }

        let resumeCount = Locked(0)
        stubTask.onResume = {
            resumeCount.withLock { $0 += 1 }
            transport.handleOpen(task: stubTask)
        }

        transport._testing_setStateConnected(stubTask)
        transport._testing_receiveNext(on: stubTask)

        let error = NSError(domain: NSPOSIXErrorDomain, code: 57, userInfo: nil)
        stubTask.receiveHandler?(.failure(error))

        let reconnected = await waitUntil(timeout: .seconds(10)) {
            resumeCount.withLock { $0 } >= 1
        }
        #expect(reconnected)
    }

    @Test
    func testHandleIncomingWithoutHandlerDoesNotCrash() async throws {
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan")
        )

        let envelope = SyncEnvelope(type: .clipboard, payload: .init(
            contentType: .text,
            ciphertext: Data([0x01]),
            deviceId: "device",
            target: "peer",
            encryption: .init(nonce: Data([0x02]), tag: Data([0x03]))
        ))
        let encoded = try TransportFrameCodec().encode(envelope)
        transport._testing_handleIncoming(encoded)
    }

    @Test
    func testHandleIncomingWithInvalidDataDoesNotCrash() async {
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan")
        )
        let garbage = Data([0, 0, 0, 1, 0xFF])
        transport._testing_handleIncoming(garbage)
    }

    @Test
    func testReceiveNextHandlesStringMessage() async {
        let stubTask = StubWebSocketTask()
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan")
        )
        transport._testing_setStateConnected(stubTask)
        transport._testing_receiveNext(on: stubTask)

        stubTask.receiveHandler?(.success(.string("hello")))
        #expect(transport.isConnected())
    }

    @Test
    func testDidCloseWithResetsState() async {
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan")
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://example.com")!)
        transport._testing_setStateConnected(task)

        transport.urlSession(session, webSocketTask: task, didCloseWith: .goingAway, reason: Data("bye".utf8))
        #expect(transport.isConnected() == false)
    }

    @Test
    func testDidCompleteWithErrorResetsState() async {
        let transport = LanWebSocketTransport(
            configuration: .init(url: URL(string: "ws://example.com")!, pinnedFingerprint: nil, environment: "lan")
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://example.com")!)
        transport._testing_setStateConnected(task)

        transport.urlSession(session, task: task, didCompleteWithError: NSError(domain: NSURLErrorDomain, code: -1))
        #expect(transport.isConnected() == false)
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
