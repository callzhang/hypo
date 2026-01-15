import Foundation
import Network
import Testing
@testable import HypoApp

@MainActor
struct LanWebSocketServerTests {
    
    @Test
    func testStartAndStop() async throws {
        let server = LanWebSocketServer()
        try server.start(port: 0) // Ephemeral port
        
        // Wait briefly for listener to be ready and assign port
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let port = server.listeningPort
        #expect(port != nil)
        #expect(port != 0)
        
        server.stop()
    }
    
    @Test
    func testClientConnectionAndHandshake() async throws {
        let server = LanWebSocketServer()
        try server.start(port: 0)
        
        // Wait for port assignment
        try await Task.sleep(nanoseconds: 100_000_000)
        
        guard let port = server.listeningPort else {
            Issue.record("Failed to get listening port")
            return
        }
        
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        // Connect with URLSession
        let url = URL(string: "ws://localhost:\(port.rawValue)")!
        let session = URLSession(configuration: .default)
        let webSocketTask = session.webSocketTask(with: url)
        
        webSocketTask.resume()
        
        // Wait for connection accepted
        _ = try await delegate.waitForConnection(timeout: 5.0)
        
        webSocketTask.cancel(with: .normalClosure, reason: nil)
        server.stop()
    }
    
    @Test
    func testReceiveMessage() async throws {
        let server = LanWebSocketServer()
        try server.start(port: 0)
        
        try await Task.sleep(nanoseconds: 100_000_000)
        
        guard let port = server.listeningPort else {
            Issue.record("Failed to get listening port")
            return
        }
        
        let delegate = MockServerDelegate()
        server.delegate = delegate
        
        let url = URL(string: "ws://localhost:\(port.rawValue)")!
        let session = URLSession(configuration: .default)
        let webSocketTask = session.webSocketTask(with: url)
        webSocketTask.resume()
        
        _ = try await delegate.waitForConnection(timeout: 5.0)
        
        // Send a message
        let text = "Hello Server"
        let message = URLSessionWebSocketTask.Message.string(text)
        try await webSocketTask.send(message)
        
        let receivedData = try await delegate.waitForData(timeout: 5.0)
        let receivedString = String(data: receivedData, encoding: .utf8)
        #expect(receivedString == text)
        
        server.stop()
    }
}

final class MockServerDelegate: LanWebSocketServerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _connectionContinuation: CheckedContinuation<UUID, Error>?
    private var _dataContinuation: CheckedContinuation<Data, Error>?

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
        if let continuation = _dataContinuation {
            continuation.resume(returning: data)
            _dataContinuation = nil
        }
    }
    
    func server(_ server: LanWebSocketServer, didAcceptConnection id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let continuation = _connectionContinuation {
            continuation.resume(returning: id)
            _connectionContinuation = nil
        }
    }
    
    func server(_ server: LanWebSocketServer, didCloseConnection id: UUID) {}
    
    func server(_ server: LanWebSocketServer, didIdentifyConnection id: UUID, deviceId: String) {}
    
    struct TimeoutError: Error {}
}
