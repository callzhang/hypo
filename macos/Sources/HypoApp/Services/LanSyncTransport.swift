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
    // Persistent connections: one WebSocketTransport per peer (deviceId)
    // Connections are maintained for all discovered peers, mirroring Android's architecture
    private var clientTransports: [String: WebSocketTransport] = [:] // deviceId -> transport
    // Track URLs for each peer to detect IP changes
    private var peerURLs: [String: URL] = [:] // deviceId -> URL
    // Track connection tasks for each peer to enable cleanup
    private var connectionTasks: [String: Task<Void, Never>] = [:] // deviceId -> connection maintenance task
    
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
    
    /// Maintain persistent connections to all discovered peers (mirrors Android architecture)
    /// Called when peers are discovered/removed to keep connections in sync
    public func syncPeerConnections() async {
        guard let getDiscoveredPeers = getDiscoveredPeers else { return }
        let discoveredPeers = getDiscoveredPeers()
        let discoveredDeviceIds = Set(discoveredPeers.compactMap { peer in
            peer.endpoint.metadata["device_id"] ?? peer.serviceName
        })
        
        // Remove connections for peers that are no longer discovered
        let currentDeviceIds = Set(clientTransports.keys)
        let removedDeviceIds = currentDeviceIds.subtracting(discoveredDeviceIds)
        for deviceId in removedDeviceIds {
            #if canImport(os)
            logger.info("🔌 [LanSyncTransport] Removing connection for peer \(deviceId) (no longer discovered)")
            #endif
            connectionTasks[deviceId]?.cancel()
            connectionTasks.removeValue(forKey: deviceId)
            clientTransports.removeValue(forKey: deviceId)
            peerURLs.removeValue(forKey: deviceId)
        }
        
        // Create/maintain connections for newly discovered peers
        for peer in discoveredPeers {
            let deviceId = peer.endpoint.metadata["device_id"] ?? peer.serviceName
            let urlString = "ws://\(peer.endpoint.host):\(peer.endpoint.port)"
            guard let url = URL(string: urlString) else {
                #if canImport(os)
                logger.warning("⚠️ [LanSyncTransport] Invalid URL for peer \(peer.serviceName): \(urlString)")
                #endif
                continue
            }
            
            // Create transport if it doesn't exist
            if clientTransports[deviceId] == nil {
                #if canImport(os)
                logger.info("🔌 [LanSyncTransport] Creating persistent connection for peer \(peer.serviceName) (\(deviceId))")
                #endif
                
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
                    idleTimeout: 3600, // 1 hour
                    environment: "lan",
                    roundTripTimeout: 60
                )
                
                let clientTransport = WebSocketTransport(
                    configuration: config,
                    frameCodec: TransportFrameCodec(),
                    metricsRecorder: NullTransportMetricsRecorder(),
                    analytics: NoopTransportAnalytics()
                )
                clientTransports[deviceId] = clientTransport
                peerURLs[deviceId] = url
                
                // Start persistent connection maintenance task
                connectionTasks[deviceId] = Task { [weak self] in
                    await self?.maintainPeerConnection(deviceId: deviceId, transport: clientTransport, peerName: peer.serviceName)
                }
            } else {
                // Update URL if peer IP changed (reconnect if needed)
                let existingURL = peerURLs[deviceId]
                if existingURL != url {
                    #if canImport(os)
                    logger.info("🔄 [LanSyncTransport] Peer \(peer.serviceName) IP changed: \(existingURL?.absoluteString ?? "nil") → \(url.absoluteString), reconnecting...")
                    #endif
                    // Cancel old connection task and create new transport
                    connectionTasks[deviceId]?.cancel()
                    connectionTasks.removeValue(forKey: deviceId)
                    clientTransports.removeValue(forKey: deviceId)
                    peerURLs.removeValue(forKey: deviceId)
                    
                    // Recreate with new URL (will be picked up in next iteration)
                    await syncPeerConnections()
                } else {
                    // Update URL in case it's nil (shouldn't happen, but be safe)
                    peerURLs[deviceId] = url
                }
            }
        }
    }
    
    /// Maintain persistent connection to a peer with automatic reconnection.
    /// Reuses unified event-driven reconnection logic from WebSocketTransport.
    /// Simply calls connect() once - all reconnection is handled by receiveNext() callbacks
    /// with the same exponential backoff as cloud connections.
    private func maintainPeerConnection(deviceId: String, transport: WebSocketTransport, peerName: String) async {
        // Start connection - this will establish connection and maintain it
        // WebSocketTransport handles all reconnection via receiveNext() callbacks
        // with unified exponential backoff (same as cloud connections)
        do {
            if !transport.isConnected() {
                try await transport.connect()
            }
        } catch {
            logger.warning("⚠️ [LanSyncTransport] Initial connection to peer \(peerName) failed: \(error.localizedDescription)")
        }
        
        // Keep this task alive while peer is still in our map
        // The connection is maintained by WebSocketTransport's event-driven reconnection
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // Just keep alive - reconnection handled by WebSocketTransport
        }
    }
    
    public func connect() async throws {
        guard !isConnected else { return }
        
        #if canImport(os)
        logger.info("LAN transport connected (server-side)")
        #endif
        
        isConnected = true
        
        // Sync peer connections when transport connects (establish persistent connections)
        await syncPeerConnections()
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
        logger.debug("📤 [LanSyncTransport] Sending envelope: type=\(envelope.type.rawValue)")
        #endif
        
        let framed = try frameCodec.encode(envelope)
        
        // Get target device ID from envelope (for encrypted messages, this is set by DualSyncTransport)
        let targetDeviceId = envelope.payload.target
        
        // 1) Send to target device via inbound connections (peers connected to our server)
        let activeConnections = server.activeConnections()
        
        if let targetDeviceId = targetDeviceId {
            // Encrypted message - unicast to specific target device only
            #if canImport(os)
            logger.debug("📡 [LanSyncTransport] Unicasting to target device: \(targetDeviceId.prefix(8))...")
            #endif
            
            // Find connection(s) for target device
            var sentToTarget = false
            for connectionId in activeConnections {
                if let metadata = server.connectionMetadata(for: connectionId),
                   metadata.deviceId == targetDeviceId {
                    try? server.send(framed, to: connectionId)
                    sentToTarget = true
                    #if canImport(os)
                    logger.debug("✅ [LanSyncTransport] Sent to target device via connection \(connectionId.uuidString.prefix(8))")
                    #endif
                }
            }
            
            // 2) If target not found in active connections, try persistent connection
            if !sentToTarget {
                #if canImport(os)
                logger.debug("📡 [LanSyncTransport] Target device not in active connections, trying persistent connection...")
                #endif
                
                if let clientTransport = clientTransports[targetDeviceId] {
                    Task {
                        do {
                            if !clientTransport.isConnected() {
                                try await clientTransport.connect()
                            }
                            try await clientTransport.send(envelope)
                            #if canImport(os)
                            logger.debug("✅ [LanSyncTransport] Sent to target device \(targetDeviceId.prefix(8)) via persistent connection")
                            #endif
                        } catch {
                            #if canImport(os)
                            logger.warning("⚠️ [LanSyncTransport] Failed to send to target device \(targetDeviceId.prefix(8)): \(error.localizedDescription)")
                            #endif
                        }
                    }
                } else {
                    #if canImport(os)
                    logger.warning("⚠️ [LanSyncTransport] No connection found for target device \(targetDeviceId.prefix(8))")
                    #endif
                }
            }
        } else {
            // Unencrypted message or broadcast - send to all peers
            #if canImport(os)
            logger.debug("📡 [LanSyncTransport] Broadcasting to \(activeConnections.count) peer(s)")
            #endif
            server.sendToAll(framed)
            
            // Also send to disconnected peers via persistent connections
            if let getDiscoveredPeers = getDiscoveredPeers {
                let discoveredPeers = getDiscoveredPeers()
                let activeDeviceIds = Set(activeConnections.compactMap { connectionId in
                    server.connectionMetadata(for: connectionId)?.deviceId
                })
                
                let disconnectedPeers = discoveredPeers.filter { peer in
                    guard let deviceId = peer.endpoint.metadata["device_id"] else { return false }
                    return !activeDeviceIds.contains(deviceId)
                }
                
                #if canImport(os)
                logger.debug("📡 [LanSyncTransport] Attempting delivery to \(disconnectedPeers.count) disconnected peer(s)")
                #endif
                
                for peer in disconnectedPeers {
                    let deviceId = peer.endpoint.metadata["device_id"] ?? peer.serviceName
                    
                    if let clientTransport = clientTransports[deviceId] {
                        Task {
                            do {
                                if !clientTransport.isConnected() {
                                    try await clientTransport.connect()
                                }
                                try await clientTransport.send(envelope)
                                #if canImport(os)
                                logger.debug("✅ [LanSyncTransport] Sent to peer \(peer.serviceName)")
                                #endif
                            } catch {
                                #if canImport(os)
                                logger.debug("⏭️ [LanSyncTransport] Failed to send to peer \(peer.serviceName): \(error.localizedDescription) (best-effort, continuing)")
                                #endif
                            }
                        }
                    }
                }
            }
        }
    }
    
    /// Close all LAN connections (for sleep optimization).
    /// Connections will be re-established when reconnectAllConnections() is called.
    public func closeAllConnections() async {
        #if canImport(os)
        logger.info("🔌 [LanSyncTransport] Closing all LAN connections (sleep optimization)")
        #endif
        
        // Disconnect all peer connections but keep the transport objects
        for (deviceId, transport) in clientTransports {
            await transport.disconnect()
            #if canImport(os)
            logger.debug("   [LanSyncTransport] Disconnected peer \(deviceId)")
            #endif
        }
        
        // Cancel all connection maintenance tasks
        for (deviceId, task) in connectionTasks {
            task.cancel()
            #if canImport(os)
            logger.debug("   [LanSyncTransport] Cancelled connection maintenance for peer \(deviceId)")
            #endif
        }
        connectionTasks.removeAll()
        
        // Keep clientTransports and peerURLs intact - we'll reconnect to the same peers
    }
    
    /// Reconnect all LAN connections (for wake optimization).
    /// Re-establishes connections to all discovered peers.
    public func reconnectAllConnections() async {
        #if canImport(os)
        logger.info("🔄 [LanSyncTransport] Reconnecting all LAN connections (wake optimization)")
        #endif
        
        // Re-sync peer connections to re-establish connections
        await syncPeerConnections()
    }
    
    public func disconnect() async {
        isConnected = false
        
        // Cancel all peer connection maintenance tasks
        for (deviceId, task) in connectionTasks {
            task.cancel()
            #if canImport(os)
            logger.info("🔌 [LanSyncTransport] Cancelled connection maintenance for peer \(deviceId)")
            #endif
        }
        connectionTasks.removeAll()
        clientTransports.removeAll()
        peerURLs.removeAll()
        
        #if canImport(os)
        logger.info("LAN transport disconnected")
        #endif
    }
    
    // Helper method for receiving messages (called by delegate)
    public func handleReceivedMessage(_ data: Data) async throws {
        let envelope = try decoder.decode(SyncEnvelope.self, from: data)
        
        #if canImport(os)
        logger.debug("📥 [LanSyncTransport] Received clipboard envelope: type=\(envelope.type.rawValue), from=\(envelope.payload.deviceId.prefix(8))")
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
