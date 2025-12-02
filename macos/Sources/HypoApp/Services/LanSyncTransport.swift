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
    private let frameCodec = TransportFrameCodec()
    private var isConnected = false
    private var messageHandlers: [UUID: (Data) async throws -> Void] = [:]
    private var getDiscoveredPeers: (() -> [DiscoveredPeer])?
    private var clientTransports: [String: WebSocketTransport] = [:] // deviceId -> transport
    
    #if canImport(os)
    private let logger = HypoLogger(category: "lan-transport")
    #endif
    
    public init(server: LanWebSocketServer, getDiscoveredPeers: (() -> [DiscoveredPeer])? = nil) {
        self.server = server
        self.getDiscoveredPeers = getDiscoveredPeers
        
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder.dateDecodingStrategy = .iso8601
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
        
        #if canImport(os)
        logger.info("Sending clipboard envelope (type: \(envelope.type.rawValue))")
        #endif
        
        let framed = try frameCodec.encode(envelope)
        
        // 1) Send to all currently connected peers (inbound connections to our server)
        let activeConnections = server.activeConnections()
        #if canImport(os)
        logger.info("📡 [LanSyncTransport] Broadcasting to all \(activeConnections.count) connected peer(s)")
        #endif
        server.sendToAll(framed)
        
        // 2) Best-effort: Also try to send to all discovered peers (even if not currently connected)
        // This uses their last seen address for maximum delivery reliability
        if let getDiscoveredPeers = getDiscoveredPeers {
            let discoveredPeers = getDiscoveredPeers()
            let activeDeviceIds = Set(activeConnections.compactMap { connectionId in
                server.connectionMetadata(for: connectionId)?.deviceId
            })
            
            // Filter out peers that are already connected (we already sent to them above)
            let disconnectedPeers = discoveredPeers.filter { peer in
                guard let deviceId = peer.endpoint.metadata["device_id"] else { return false }
                return !activeDeviceIds.contains(deviceId)
            }
            
            #if canImport(os)
            logger.info("📡 [LanSyncTransport] Attempting best-effort delivery to \(disconnectedPeers.count) disconnected peer(s) using last seen address")
            #endif
            
            // Try to send to each disconnected peer using their last seen address
            for peer in disconnectedPeers {
                let urlString = "ws://\(peer.endpoint.host):\(peer.endpoint.port)"
                guard let url = URL(string: urlString) else {
                    #if canImport(os)
                    logger.warning("⚠️ [LanSyncTransport] Invalid URL for peer \(peer.serviceName): \(urlString)")
                    #endif
                    continue
                }
                
                let deviceId = peer.endpoint.metadata["device_id"] ?? peer.serviceName
                
                // Reuse existing client transport if available, or create new one
                let clientTransport: WebSocketTransport
                if let existing = clientTransports[deviceId] {
                    clientTransport = existing
                } else {
                    let deviceIdentity = DeviceIdentity()
                    let pinnedFingerprint: String? = {
                        if let fp = peer.endpoint.fingerprint, fp.lowercased() != "uninitialized" { return fp }
                        return nil
                    }()
                    let config = WebSocketConfiguration(
                        url: url,
                        pinnedFingerprint: pinnedFingerprint,
                        headers: [
                            "X-Device-Id": deviceIdentity.deviceId.uuidString,
                            "X-Device-Platform": "macos"
                        ],
                        idleTimeout: 30,
                        environment: "lan",
                        roundTripTimeout: 60
                    )
                    
                    clientTransport = WebSocketTransport(
                        configuration: config,
                        frameCodec: TransportFrameCodec(),
                        metricsRecorder: NullTransportMetricsRecorder(),
                        analytics: NoopTransportAnalytics()
                    )
                    clientTransports[deviceId] = clientTransport
                }
                
                // Try to connect and send (best-effort, don't fail if it doesn't work)
                Task {
                    do {
                        try await clientTransport.connect()
                        #if canImport(os)
                        logger.info("✅ [LanSyncTransport] Connected to disconnected peer \(peer.serviceName) at \(urlString)")
                        #endif
                        try await clientTransport.send(envelope)
                        #if canImport(os)
                        logger.info("✅ [LanSyncTransport] Sent to disconnected peer \(peer.serviceName)")
                        #endif
                    } catch {
                        #if canImport(os)
                        logger.debug("⏭️ [LanSyncTransport] Failed to send to disconnected peer \(peer.serviceName): \(error.localizedDescription) (best-effort, continuing)")
                        #endif
                    }
                }
            }
        }
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
