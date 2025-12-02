import Foundation
#if canImport(os)
import os
#endif

@MainActor
public final class LanSyncTransport: SyncTransport {
    private let server: LanWebSocketServer
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var isConnected = false
    private var messageHandlers: [UUID: (Data) async throws -> Void] = [:]
    
    #if canImport(os)
    private let logger = Logger(subsystem: "com.hypo.clipboard", category: "lan-transport")
    #endif
    
    public init(server: LanWebSocketServer) {
        self.server = server
        
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder.dateDecodingStrategy = .iso8601
        
        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder.dateEncodingStrategy = .iso8601
    }
    
    public func connect() async throws {
        guard !isConnected else { return }
        
        #if canImport(os)
        logger.info("LAN transport connected (server-side)")
        #endif
        
        isConnected = true
    }
    
    public func send(_ envelope: SyncEnvelope) async throws {
        guard isConnected else {
            throw NSError(
                domain: "LanSyncTransport",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Transport not connected"]
            )
        }
        
        let data = try encoder.encode(envelope)
        
        #if canImport(os)
        logger.info("Sending clipboard envelope (type: \(envelope.type.rawValue), size: \(data.count) bytes)")
        #endif
        
        // Send to all connected clients
        server.sendToAll(data)
    }
    
    public func disconnect() async {
        isConnected = false
        
        #if canImport(os)
        logger.info("LAN transport disconnected")
        #endif
    }
    
    // Helper method for receiving messages (called by delegate)
    public func handleReceivedMessage(_ data: Data) async throws {
        let envelope = try decoder.decode(SyncEnvelope.self, from: data)
        
        #if canImport(os)
        logger.info("Received clipboard envelope (type: \(envelope.type.rawValue), from: \(envelope.payload.deviceId))")
        #endif
        
        // Notify any registered handlers
        for handler in messageHandlers.values {
            try await handler(data)
        }
    }
    
    // Register a handler for incoming messages
    public func registerMessageHandler(id: UUID, handler: @escaping (Data) async throws -> Void) {
        messageHandlers[id] = handler
    }
    
    public func unregisterMessageHandler(id: UUID) {
        messageHandlers.removeValue(forKey: id)
    }
}

