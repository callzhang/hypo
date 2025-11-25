import Foundation
#if canImport(os)
import os
#endif

// Import DiscoveredPeer for client-side LAN connections
// DiscoveredPeer is defined in BonjourBrowser.swift

@MainActor
public final class LanSyncTransport: SyncTransport {
    private let server: LanWebSocketServer
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var isConnected = false
    private var messageHandlers: [UUID: (Data) async throws -> Void] = [:]
    private var getDiscoveredPeers: (() -> [DiscoveredPeer])?
    private var clientTransports: [String: LanWebSocketTransport] = [:] // deviceId -> transport
    
    #if canImport(os)
    private let logger = HypoLogger(category: "lan-transport")
    #endif
    
    public init(server: LanWebSocketServer, getDiscoveredPeers: (() -> [DiscoveredPeer])? = nil) {
        self.server = server
        self.getDiscoveredPeers = getDiscoveredPeers
        
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder.dateDecodingStrategy = .iso8601
        
        self.encoder = JSONEncoder()
        self.encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder.dateEncodingStrategy = .iso8601
    }
    
    public func setGetDiscoveredPeers(_ closure: @escaping () -> [DiscoveredPeer]) {
        self.getDiscoveredPeers = closure
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
        
        // If envelope has a target device ID, try to send to that specific device
        if let targetDeviceId = envelope.payload.target, !targetDeviceId.isEmpty {
            // First, try to send via server (if target is connected to our server)
            let activeConnections = server.activeConnections()
            var targetConnectionFound = false
            
            for connectionId in activeConnections {
                if let metadata = server.connectionMetadata(for: connectionId),
                   let deviceId = metadata.deviceId,
                   deviceId == targetDeviceId {
                    // Found connection for target device - send to it
                    #if canImport(os)
                    logger.info("Sending to target device \(targetDeviceId) via server connection \(connectionId.uuidString.prefix(8))")
                    #endif
                    try server.send(data, to: connectionId)
                    targetConnectionFound = true
                    return
                }
            }
            
            // Target device not connected to our server - try to connect as client to their server
            if let getPeers = getDiscoveredPeers {
                let discoveredPeers = getPeers()
                if let peer = discoveredPeers.first(where: { peer in
                    peer.endpoint.metadata["device_id"] == targetDeviceId
                }) {
                    // Found peer - connect as client and send
                    #if canImport(os)
                    logger.info("Target device \(targetDeviceId) not connected to our server, connecting as client to \(peer.endpoint.host):\(peer.endpoint.port)")
                    #endif
                    
                    // Create or reuse client transport for this device
                    let clientTransport: LanWebSocketTransport
                    if let existing = clientTransports[targetDeviceId] {
                        clientTransport = existing
                    } else {
                        let urlString = "ws://\(peer.endpoint.host):\(peer.endpoint.port)"
                        guard let url = URL(string: urlString) else {
                            throw NSError(domain: "LanSyncTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL: \(urlString)"])
                        }
                        
                        let deviceIdentity = DeviceIdentity()
                        let config = LanWebSocketConfiguration(
                            url: url,
                            pinnedFingerprint: peer.endpoint.fingerprint,
                            headers: [
                                "X-Device-Id": deviceIdentity.deviceId.uuidString,
                                "X-Device-Platform": "macos"
                            ],
                            idleTimeout: 30,
                            environment: "lan",
                            roundTripTimeout: 60
                        )
                        
                        clientTransport = LanWebSocketTransport(
                            configuration: config,
                            frameCodec: TransportFrameCodec(),
                            metricsRecorder: NullTransportMetricsRecorder(),
                            analytics: NoopTransportAnalytics()
                        )
                        clientTransports[targetDeviceId] = clientTransport
                    }
                    
                    // Ensure connection is established before sending
                    do {
                        try await clientTransport.connect()
                        #if canImport(os)
                        logger.info("Connected as client to \(targetDeviceId) at ws://\(peer.endpoint.host):\(peer.endpoint.port)")
                        #endif
                        
                        // Send via client transport
                        try await clientTransport.send(envelope)
                        #if canImport(os)
                        logger.info("Sent to target device \(targetDeviceId) via client connection")
                        #endif
                        return
                    } catch {
                        #if canImport(os)
                        logger.info("Failed to connect/send via client to \(targetDeviceId): \(error.localizedDescription), falling back to sendToAll")
                        #endif
                        // Fall through to sendToAll
                    }
                } else {
                    #if canImport(os)
                    logger.info("Target device \(targetDeviceId) not discovered on LAN, cannot send via LAN")
                    #endif
                    // Fall through to sendToAll (will be a no-op if no connections)
                }
            }
        }
        
        // No target specified or target not found - send to all connected clients (best-effort)
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

