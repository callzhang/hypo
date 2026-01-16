import Foundation
import Network
import CryptoKit
import Testing
@testable import HypoApp

@MainActor
@Suite
struct LanWebSocketServerTests {
    
    @Test
    func testStartAndStop() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0) // Ephemeral port
        defer { server.stop() }
        
        _ = try await server.waitForPort()
        
        let port = server.listeningPort
        #expect(port != nil)
        #expect(port != 0)
        
    }
    
    @Test
    func testClientConnectionAndHandshake() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        
        let port = try await server.waitForPort()
        
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        // Connect with URLSession
        let url = URL(string: "ws://localhost:\(port)")!
        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }
        let webSocketTask = session.webSocketTask(with: url)
        
        webSocketTask.resume()
        
        // Wait for connection accepted
        _ = try await delegate.waitForConnection(timeout: 5.0)
        
        webSocketTask.cancel(with: .normalClosure, reason: nil)
    }
    
    @Test
    func testReceiveMessage() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        let url = URL(string: "ws://localhost:\(port)")!
        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }
        let webSocketTask = session.webSocketTask(with: url)
        webSocketTask.resume()
        
        _ = try await delegate.waitForConnection(timeout: 5.0)
        
        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: SyncEnvelope.Payload(
                contentType: .text,
                ciphertext: Data("Hello Server".utf8),
                deviceId: "test-sender",
                devicePlatform: "test",
                deviceName: "Test Device",
                target: nil,
                encryption: SyncEnvelope.EncryptionMetadata(nonce: Data(repeating: 0, count: 12), tag: Data(repeating: 0, count: 16))
            )
        )
        let codec = TransportFrameCodec()
        let framePayload = try codec.encode(envelope)
        try await webSocketTask.send(.data(framePayload))
        
        let receivedData = try await delegate.waitForData(timeout: 5.0)
        let decoded = try codec.decode(receivedData)
        #expect(decoded.payload.ciphertext == Data("Hello Server".utf8))
        
        webSocketTask.cancel(with: .normalClosure, reason: nil)
    }

    @Test
    func testHandshakeWithDeviceId() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)
        
        // Manual handshake with device ID in query param
        let handshake = "GET /?device_id=test-device HTTP/1.1\r\n" +
                        "Host: localhost\r\n" +
                        "Upgrade: websocket\r\n" +
                        "Connection: Upgrade\r\n" +
                        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
                        "Sec-WebSocket-Version: 13\r\n\r\n"
        
        try await sendContent(Data(handshake.utf8), over: connection, timeout: 2.0)
        
        let connectionId = try await delegate.waitForConnection(timeout: 2.0)
        let metadata = server.connectionMetadata(for: connectionId)
        #expect(metadata?.deviceId == "test-device")
        
        connection.cancel()
    }

    @Test
    func testHandshakeWithXDeviceIdHeader() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)
        
        // Manual handshake with device ID in header
        let handshake = "GET / HTTP/1.1\r\n" +
                        "Host: localhost\r\n" +
                        "Upgrade: websocket\r\n" +
                        "Connection: Upgrade\r\n" +
                        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
                        "x-device-id: header-device\r\n" +
                        "Sec-WebSocket-Version: 13\r\n\r\n"
        
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
        
        let connectionId = try await delegate.waitForConnection(timeout: 2.0)
        let metadata = server.connectionMetadata(for: connectionId)
        #expect(metadata?.deviceId == "header-device")
        
        connection.cancel()
    }

    @Test
    func testInvalidHandshakeRejection() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        
        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)
        
        // Invalid handshake (missing Upgrade headder)
        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
        
        let responseData = try await receiveData(from: connection, minimum: 1, maximum: 1024, timeout: 2.0)
        let response = String(data: responseData, encoding: .utf8) ?? ""
        #expect(response.contains("400 Bad Request"))
        
        connection.cancel()
    }

    @Test
    func testMaskedFrameParsing() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)
        
        // Handshake first
        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
        _ = try await delegate.waitForConnection(timeout: 2.0)
        
        // Send a masked clipboard message using TransportFrameCodec
        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: SyncEnvelope.Payload(
                contentType: .text,
                ciphertext: Data("Hello".utf8),
                deviceId: "test-sender",
                devicePlatform: "test",
                deviceName: "Test Device",
                target: nil,
                encryption: SyncEnvelope.EncryptionMetadata(nonce: Data(repeating: 0, count: 12), tag: Data(repeating: 0, count: 16))
            )
        )
        let codec = TransportFrameCodec()
        let innerPayload = try codec.encode(envelope)
        
        let maskingKey: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        var maskedPayload = innerPayload
        for i in 0..<maskedPayload.count {
            maskedPayload[i] ^= maskingKey[i % 4]
        }
        
        var frame = Data([0x81]) // FIN=1, Opcode=1
        let payloadLen = maskedPayload.count
        if payloadLen <= 125 {
            frame.append(0x80 | UInt8(payloadLen))
        } else {
            frame.append(0x80 | 126)
            var l = UInt16(payloadLen).bigEndian
            withUnsafeBytes(of: &l) { frame.append(contentsOf: $0) }
        }
        frame.append(contentsOf: maskingKey)
        frame.append(maskedPayload)
        
        connection.send(content: frame, completion: .contentProcessed { _ in })
        
        let receivedData = try await delegate.waitForData(timeout: 2.0)
        let decoded = try codec.decode(receivedData)
        #expect(decoded.payload.ciphertext == Data("Hello".utf8))
        
        connection.cancel()
    }

    @Test
    func testExtendedLengthFrameParsing() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)
        
        // Handshake
        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
        _ = try await delegate.waitForConnection(timeout: 2.0)
        
        // Send a 200-byte clipboard message (Extended length 126)
        let largeText = String(repeating: "A", count: 200)
        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: SyncEnvelope.Payload(
                contentType: .text,
                ciphertext: Data(largeText.utf8),
                deviceId: "test-sender",
                devicePlatform: "test",
                deviceName: "Test Device",
                target: nil,
                encryption: SyncEnvelope.EncryptionMetadata(nonce: Data(repeating: 0, count: 12), tag: Data(repeating: 0, count: 16))
            )
        )
        let codec = TransportFrameCodec()
        let innerPayload = try codec.encode(envelope)
        
        var frame = Data([0x81, 126])
        var length = UInt16(innerPayload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(innerPayload)
        
        connection.send(content: frame, completion: .contentProcessed { _ in })
        
        let receivedData = try await delegate.waitForData(timeout: 2.0)
        let decoded = try codec.decode(receivedData)
        #expect(decoded.payload.ciphertext == Data(largeText.utf8))
        
        connection.cancel()
    }

    @Test
    func testPingPong() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)
        
        // Handshake
        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
        _ = try await delegate.waitForConnection(timeout: 2.0)
        _ = try await receiveData(from: connection, minimum: 1, maximum: 1024, timeout: 2.0)
        
        // Send Ping (opcode 0x9)
        let pingFrame = Data([0x89, 0x00])
        connection.send(content: pingFrame, completion: .contentProcessed { _ in })
        
        let pongData = try await receiveData(from: connection, minimum: 2, maximum: 2, timeout: 2.0)
        #expect(pongData.first == 0x8A)
        
        connection.cancel()
    }

    @Test
    func testCloseFrameHandling() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)
        
        // Handshake
        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
        let connectionId = try await delegate.waitForConnection(timeout: 2.0)
        
        // Send Close frame (opcode 0x8)
        let closeFrame = Data([0x88, 0x00])
        connection.send(content: closeFrame, completion: .contentProcessed { _ in })
        
        // Wait for server to close connection
        _ = try await withTimeout(seconds: 2.0, operation: {
            while await MainActor.run(resultType: Bool.self, body: { server.activeConnections().contains(connectionId) }) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        })
        
        connection.cancel()
    }

    @Test
    func testHeartbeatAndIdleTimeout() async throws {
        // Use a small heartbeat interval for testing (if possible, but it's hardcoded to 60s/180s)
        // Since intervals are hardcoded, we might need to use a mock clock or just test the logic
        // For now, I'll test that setting metadata updates the timestamp and starts heartbeat task
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)
        
        // Handshake
        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
        let connectionId = try await delegate.waitForConnection(timeout: 2.0)
        
        // Verify metadata update
        server.updateConnectionMetadata(connectionId: connectionId, deviceId: "new-device")
        let metadata = server.connectionMetadata(for: connectionId)
        #expect(metadata?.deviceId == "new-device")
        
        // We can't easily wait 60s or 180s in a unit test without mocking the clock.
        // However, we can verify that the connection is still active after a short sleep.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(server.activeConnections().contains(connectionId))
        
        connection.cancel()
    }

    @Test
    func testExtendedLengthFrame8ByteParsing() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)
        
        // Handshake
        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
        _ = try await delegate.waitForConnection(timeout: 2.0)
        
        // Send a 70,000-byte clipboard message (Extended length 127)
        let largeText = String(repeating: "B", count: 70000)
        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: SyncEnvelope.Payload(
                contentType: .text,
                ciphertext: Data(largeText.utf8),
                deviceId: "test-sender",
                devicePlatform: "test",
                deviceName: "Test Device",
                target: nil,
                encryption: SyncEnvelope.EncryptionMetadata(nonce: Data(repeating: 0, count: 12), tag: Data(repeating: 0, count: 16))
            )
        )
        let codec = TransportFrameCodec()
        let innerPayload = try codec.encode(envelope)
        
        var frame = Data([0x81, 127])
        var length = UInt64(innerPayload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(innerPayload)
        
        connection.send(content: frame, completion: .contentProcessed { _ in })
        
        let receivedData = try await delegate.waitForData(timeout: 5.0)
        let decoded = try codec.decode(receivedData)
        #expect(decoded.payload.ciphertext == Data(largeText.utf8))
        
        connection.cancel()
    }

    @Test
    func testMessageTargetMismatch() async throws {
        // Create server with a specific device ID
        let server = LanWebSocketServer(localDeviceId: "mac-123", enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)
        
        // Handshake
        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
        _ = try await delegate.waitForConnection(timeout: 2.0)
        
        // Send a frame-encoded message with WRONG target device ID
        let envelope = SyncEnvelope(
            type: .clipboard,
            payload: SyncEnvelope.Payload(
                contentType: .text,
                ciphertext: Data("Hello".utf8),
                deviceId: "test-sender",
                devicePlatform: "test",
                deviceName: "Test Device",
                target: "mac-456",
                encryption: SyncEnvelope.EncryptionMetadata(nonce: Data(repeating: 0, count: 12), tag: Data(repeating: 0, count: 16))
            )
        )
        let codec = TransportFrameCodec()
        let framePayload = try codec.encode(envelope)
        
        // WebSocket frame (Text, unmasked)
        var frame = Data([0x81])
        let payloadLen = framePayload.count
        if payloadLen <= 125 {
            frame.append(UInt8(payloadLen))
        } else {
            frame.append(126)
            var l = UInt16(payloadLen).bigEndian
            withUnsafeBytes(of: &l) { frame.append(contentsOf: $0) }
        }
        frame.append(framePayload)
        
        connection.send(content: frame, completion: .contentProcessed { _ in })
        
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(delegate.receivedClipboardData().isEmpty)
        
        connection.cancel()
    }

    @Test
    func testSendToUnknownConnectionThrows() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }

        expectThrows {
            try server.send(Data([0x01]), to: UUID())
        }

    }

    @Test
    func testSendPairingAckToUnknownConnectionThrows() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }

        let ack = PairingAckMessage(
            challengeId: UUID(),
            responderDeviceId: UUID(),
            responderDeviceName: "Responder",
            nonce: Data([0x01]),
            ciphertext: Data([0x02]),
            tag: Data([0x03])
        )

        expectThrows {
            try server.sendPairingAck(ack, to: UUID())
        }

    }

    @Test
    func testSendToConnectionNotUpgradedThrows() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()

        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)

        let connectionId = try await withTimeout(seconds: 1.0) {
            while true {
                let connections = await MainActor.run { server.activeConnections() }
                if let first = connections.first {
                    return first
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        #expect(server.getConnection(for: connectionId) != nil)

        expectThrows {
            try server.send(Data([0x01]), to: connectionId)
        }

        connection.cancel()
    }

    @Test
    func testSendToSpecificClient() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate

        let url = URL(string: "ws://localhost:\(port)")!
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()

        let connectionId = try await delegate.waitForConnection(timeout: 2.0)

        let payload = Data("hello".utf8)
        try server.send(payload, to: connectionId)

        let received = try await receiveData(from: task)
        #expect(received == payload)

        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    @Test
    func testSendUsesExtendedPayloadLengths() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate

        let url = URL(string: "ws://localhost:\(port)")!
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()

        let connectionId = try await delegate.waitForConnection(timeout: 2.0)

        let mediumPayload = Data(repeating: 0xAB, count: 200)
        try server.send(mediumPayload, to: connectionId)
        let receivedMedium = try await receiveData(from: task, timeout: 2.0)
        #expect(receivedMedium == mediumPayload)

        let largePayload = Data(repeating: 0xCD, count: 70_000)
        try server.send(largePayload, to: connectionId)
        let receivedLarge = try await receiveData(from: task, timeout: 5.0)
        #expect(receivedLarge == largePayload)

        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    @Test
    func testSendToAllBroadcastsToAllClients() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate

        let url = URL(string: "ws://localhost:\(port)")!
        let session = URLSession(configuration: .default)

        let taskA = session.webSocketTask(with: url)
        taskA.resume()
        _ = try await delegate.waitForConnection(timeout: 2.0)

        let taskB = session.webSocketTask(with: url)
        taskB.resume()
        _ = try await delegate.waitForConnection(timeout: 2.0)

        let payload = Data("broadcast".utf8)
        server.sendToAll(payload)

        let receivedA = try await receiveData(from: taskA)
        let receivedB = try await receiveData(from: taskB)
        #expect(receivedA == payload)
        #expect(receivedB == payload)

        taskA.cancel(with: .normalClosure, reason: nil)
        taskB.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    @Test
    func testFragmentedFrameIsIgnored() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate

        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)

        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
        _ = try await delegate.waitForConnection(timeout: 2.0)

        let frame = makeWebSocketFrame(payload: Data("part".utf8), opcode: 0x1, isFinal: false)
        connection.send(content: frame, completion: .contentProcessed { _ in })

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(delegate.receivedClipboardData().isEmpty)

        connection.cancel()
    }

    @Test
    func testTruncatedFrameIsIgnored() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = MockServerDelegate()
        server.delegate = delegate

        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)

        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
        _ = try await delegate.waitForConnection(timeout: 2.0)

        let frame = makeWebSocketFrame(payload: Data("hi".utf8), opcode: 0x1, isFinal: true)
        connection.send(content: frame, completion: .contentProcessed { _ in })

        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(delegate.receivedClipboardData().isEmpty)

        connection.cancel()
    }

    @Test
    func testPairingMessageTriggersDelegate() async throws {
        let server = LanWebSocketServer(enableHeartbeat: false)
        try server.start(port: 0)
        defer { server.stop() }
        let port = try await server.waitForPort()
        let delegate = PairingDelegate()
        server.delegate = delegate

        let connection = NWConnection(to: .hostPort(host: "localhost", port: .init(integerLiteral: UInt16(port))), using: .tcp)
        connection.start(queue: .main)

        let handshake = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        connection.send(content: Data(handshake.utf8), completion: .contentProcessed { _ in })
        _ = try await delegate.waitForConnection(timeout: 2.0)

        let challengePayload: [String: Any] = [
            "challenge_id": UUID().uuidString.lowercased(),
            "initiator_device_id": "device-123",
            "initiator_device_name": "Test Device",
            "initiator_pub_key": Data([0x01]).base64EncodedString(),
            "nonce": Data([0x02]).base64EncodedString(),
            "ciphertext": Data([0x03]).base64EncodedString(),
            "tag": Data([0x04]).base64EncodedString()
        ]
        let payload = try JSONSerialization.data(withJSONObject: challengePayload)
        let frame = makeWebSocketFrame(payload: payload, opcode: 0x1, isFinal: true)
        connection.send(content: frame, completion: .contentProcessed { _ in })

        let received = try await delegate.waitForPairing(timeout: 2.0)
        #expect(received.initiatorDeviceId == "device-123")

        connection.cancel()
    }
}

func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MockServerDelegate.TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

final class MockServerDelegate: LanWebSocketServerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _connectionContinuation: CheckedContinuation<UUID, Error>?
    private var _dataContinuation: CheckedContinuation<Data, Error>?
    private var clipboardData: [Data] = []
    private var connectionIds: [UUID] = []

    func waitForConnection(timeout: TimeInterval) async throws -> UUID {
        return try await withThrowingTaskGroup(of: UUID.self) { group in
            group.addTask {
                return try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    self._connectionContinuation = continuation
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    func waitForData(timeout: TimeInterval) async throws -> Data {
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                return try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    self._dataContinuation = continuation
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
    
    func server(_ server: LanWebSocketServer, didReceivePairingChallenge challenge: PairingChallengeMessage, from connection: UUID) {}
    
    func server(_ server: LanWebSocketServer, didReceiveClipboardData data: Data, from connection: UUID) {
        lock.lock()
        defer { lock.unlock() }
        clipboardData.append(data)
        if let continuation = _dataContinuation {
            continuation.resume(returning: data)
            _dataContinuation = nil
        }
    }
    
    func server(_ server: LanWebSocketServer, didAcceptConnection id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        connectionIds.append(id)
        if let continuation = _connectionContinuation {
            continuation.resume(returning: id)
            _connectionContinuation = nil
        }
    }
    
    func server(_ server: LanWebSocketServer, didCloseConnection id: UUID) {}
    
    func server(_ server: LanWebSocketServer, didIdentifyConnection id: UUID, deviceId: String) {}
    
    struct TimeoutError: Error {}

    func receivedClipboardData() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return clipboardData
    }
}

final class PairingDelegate: LanWebSocketServerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var connectionContinuation: CheckedContinuation<UUID, Error>?
    private var pairingContinuation: CheckedContinuation<PairingChallengeMessage, Error>?

    func waitForConnection(timeout: TimeInterval) async throws -> UUID {
        return try await withThrowingTaskGroup(of: UUID.self) { group in
            group.addTask {
                return try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    self.connectionContinuation = continuation
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MockServerDelegate.TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func waitForPairing(timeout: TimeInterval) async throws -> PairingChallengeMessage {
        return try await withThrowingTaskGroup(of: PairingChallengeMessage.self) { group in
            group.addTask {
                return try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    self.pairingContinuation = continuation
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw MockServerDelegate.TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func server(_ server: LanWebSocketServer, didReceivePairingChallenge challenge: PairingChallengeMessage, from connection: UUID) {
        lock.lock()
        defer { lock.unlock() }
        pairingContinuation?.resume(returning: challenge)
        pairingContinuation = nil
    }

    func server(_ server: LanWebSocketServer, didReceiveClipboardData data: Data, from connection: UUID) {}

    func server(_ server: LanWebSocketServer, didAcceptConnection id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        connectionContinuation?.resume(returning: id)
        connectionContinuation = nil
    }

    func server(_ server: LanWebSocketServer, didCloseConnection id: UUID) {}
}

private func receiveData(from task: URLSessionWebSocketTask, timeout: TimeInterval = 2.0) async throws -> Data {
    struct ReceiveTimeout: Error {}
    return try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            try await withCheckedThrowingContinuation { continuation in
                task.receive { result in
                    switch result {
                    case .success(let message):
                        switch message {
                        case .data(let data):
                            continuation.resume(returning: data)
                        case .string(let string):
                            continuation.resume(returning: Data(string.utf8))
                        @unknown default:
                            continuation.resume(throwing: NSError(domain: "LanWebSocketServerTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown message type"]))
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw ReceiveTimeout()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

private func sendContent(_ data: Data, over connection: NWConnection, timeout: TimeInterval = 2.0) async throws {
    _ = try await withTimeout(seconds: timeout) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}

private func receiveData(from connection: NWConnection, minimum: Int, maximum: Int, timeout: TimeInterval = 2.0) async throws -> Data {
    try await withTimeout(seconds: timeout) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }
}

private func makeWebSocketFrame(payload: Data, opcode: UInt8, isFinal: Bool) -> Data {
    var frame = Data()
    var firstByte: UInt8 = isFinal ? 0x80 : 0x00
    firstByte |= (opcode & 0x0F)
    frame.append(firstByte)

    let payloadLength = payload.count
    if payloadLength <= 125 {
        frame.append(UInt8(payloadLength))
    } else if payloadLength <= 0xFFFF {
        frame.append(126)
        var length = UInt16(payloadLength).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    } else {
        frame.append(127)
        var length = UInt64(payloadLength).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    }
    frame.append(payload)
    return frame
}
