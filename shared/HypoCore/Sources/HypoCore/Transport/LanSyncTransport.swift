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
    private var onIncomingMessage: (@Sendable (Data, TransportOrigin) async -> Void)?
    // Persistent connections: one WebSocketTransport per peer (deviceId)
    // Connections are maintained for all discovered peers, mirroring Android's architecture
    private var clientTransports: [String: WebSocketTransport] = [:] // deviceId -> transport
    // Track URLs for each peer to detect IP changes
    private var peerURLs: [String: URL] = [:] // deviceId -> URL
    // Track connection tasks for each peer to enable cleanup
    private var connectionTasks: [String: Task<Void, Never>] = [:] // deviceId -> connection maintenance task
    private weak var transportManager: TransportManager?
    
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
    
    /// Routes frames arriving on outbound connections.
    ///
    /// Without this, a device that dials out can send but never receive: the
    /// incoming handler is wired to the server's delegate, and connections we
    /// opened ourselves do not go through the server at all. On macOS that is
    /// invisible, because peers dial it and their frames arrive server-side.
    /// On iOS it means nothing can ever be received — iOS never listens, so
    /// every inbound frame comes back over a connection it opened.
    public func setOnIncomingMessage(_ handler: @escaping @Sendable (Data, TransportOrigin) async -> Void) {
        self.onIncomingMessage = handler
        for transport in clientTransports.values {
            transport.setOnIncomingMessage(handler)
        }
    }

    public func setGetDiscoveredPeers(_ closure: @escaping () -> [DiscoveredPeer]) {
        self.getDiscoveredPeers = closure
    }
    
    public func setTransportManager(_ manager: TransportManager) {
        self.transportManager = manager
    }

    static func normalizedPeers(_ peers: [DiscoveredPeer]) -> [DiscoveredPeer] {
        var latestPeers: [String: DiscoveredPeer] = [:]

        for peer in peers.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            let deviceId = peer.endpoint.metadata["device_id"] ?? peer.serviceName
            if latestPeers[deviceId] == nil {
                latestPeers[deviceId] = peer
            }
        }

        return latestPeers.values.sorted { lhs, rhs in
            if lhs.lastSeen == rhs.lastSeen {
                let lhsId = lhs.endpoint.metadata["device_id"] ?? lhs.serviceName
                let rhsId = rhs.endpoint.metadata["device_id"] ?? rhs.serviceName
                return lhsId < rhsId
            }

            return lhs.lastSeen > rhs.lastSeen
        }
    }

    private func removePersistentConnection(for deviceId: String) async {
        connectionTasks[deviceId]?.cancel()
        connectionTasks.removeValue(forKey: deviceId)

        if let transport = clientTransports.removeValue(forKey: deviceId) {
            await transport.disconnect()
        }

        peerURLs.removeValue(forKey: deviceId)
    }

    private func createPersistentConnection(for peer: DiscoveredPeer, deviceId: String, url: URL) {
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
                // deviceIdString, not deviceId.uuidString: the latter is
                // uppercase, every target id in the system is lowercase, and
                // the peer matches connections to targets by string equality —
                // so an uppercase identify meant a peer could never find the
                // connection to send back over.
                "X-Device-Id": deviceIdentity.deviceIdString,
                // Was hardcoded "macos"; DeviceIdentity knows what this is.
                "X-Device-Platform": deviceIdentity.platform.rawValue
            ],
            idleTimeout: 3600,
            environment: "lan",
            roundTripTimeout: 60
        )

        let clientTransport = WebSocketTransport(
            configuration: config,
            frameCodec: TransportFrameCodec(),
            metricsRecorder: NullTransportMetricsRecorder(),
            analytics: NoopTransportAnalytics()
        )
        if let onIncomingMessage {
            clientTransport.setOnIncomingMessage(onIncomingMessage)
        }
        clientTransports[deviceId] = clientTransport
        peerURLs[deviceId] = url

        connectionTasks[deviceId] = Task { [weak self] in
            await self?.maintainPeerConnection(deviceId: deviceId, transport: clientTransport, peerName: peer.serviceName)
        }
    }
    
    /// Maintain persistent connections to all discovered peers (mirrors Android architecture)
    /// Called when peers are discovered/removed to keep connections in sync
    public func syncPeerConnections() async {
        guard let getDiscoveredPeers = getDiscoveredPeers else { return }
        let discoveredPeers = Self.normalizedPeers(getDiscoveredPeers())
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
            await removePersistentConnection(for: deviceId)
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
                createPersistentConnection(for: peer, deviceId: deviceId, url: url)
            } else {
                // Update URL if peer IP changed (reconnect if needed)
                let existingURL = peerURLs[deviceId]
                if existingURL != url {
                    #if canImport(os)
                    logger.info("🔄 [LanSyncTransport] Peer \(peer.serviceName) IP changed: \(existingURL?.absoluteString ?? "nil") → \(url.absoluteString), reconnecting...")
                    #endif
                    await removePersistentConnection(for: deviceId)
                    createPersistentConnection(for: peer, deviceId: deviceId, url: url)
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
            let deviceDesc = transportManager?.getDeviceName(targetDeviceId) ?? "\(targetDeviceId.prefix(8))..."
            logger.debug("📡 [LanSyncTransport] Unicasting to target device: \(deviceDesc)")
            #endif
            
            // Find connection(s) for target device
            var sentToTarget = false
            for connectionId in activeConnections {
                // Case-insensitive: clients are not consistent about how they
                // present a UUID, and a mismatch here silently drops the item.
                if let metadata = server.connectionMetadata(for: connectionId),
                   metadata.deviceId?.lowercased() == targetDeviceId.lowercased() {
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
                
                let deviceDesc = transportManager?.getDeviceName(targetDeviceId) ?? "\(targetDeviceId.prefix(8))..."

                guard let clientTransport = clientTransports[targetDeviceId] else {
                    // Reaching nobody is a failure, and it used to be reported
                    // as success: the caller saw send() return normally and
                    // told the user the item had gone. On iOS that made every
                    // send read as "Sent to 1 device" with nothing sent.
                    #if canImport(os)
                    logger.warning("⚠️ [LanSyncTransport] No connection found for target device \(deviceDesc)")
                    #endif
                    throw LanSyncTransportError.noConnectionToTarget(targetDeviceId)
                }

                // Awaited, not fired into a detached Task. A Task swallows the
                // error the same way the missing branch above did.
                do {
                    if !clientTransport.isConnected() {
                        try await clientTransport.connect()
                    }
                    try await clientTransport.send(envelope)
                    #if canImport(os)
                    logger.debug("✅ [LanSyncTransport] Sent to target device \(deviceDesc) via persistent connection")
                    #endif
                } catch {
                    #if canImport(os)
                    logger.warning("⚠️ [LanSyncTransport] Failed to send to target device \(deviceDesc): \(error.localizedDescription)")
                    #endif
                    throw error
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
                let discoveredPeers = Self.normalizedPeers(getDiscoveredPeers())
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
        let deviceDesc = transportManager?.getDeviceName(envelope.payload.deviceId) ?? "\(envelope.payload.deviceId.prefix(8))..."
        logger.debug("📥 [LanSyncTransport] Received clipboard envelope: type=\(envelope.type.rawValue), from=\(deviceDesc)")
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

public enum LanSyncTransportError: LocalizedError {
    case noConnectionToTarget(String)

    public var errorDescription: String? {
        switch self {
        case .noConnectionToTarget(let deviceId):
            return "No LAN connection to device \(deviceId.prefix(8))"
        }
    }
}
