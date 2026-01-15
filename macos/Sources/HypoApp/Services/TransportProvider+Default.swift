import Foundation

@MainActor
public final class DefaultTransportProvider: TransportProvider {
    private let server: LanWebSocketServer
    private let lanTransport: LanSyncTransport
    private let cloudTransport: CloudRelayTransport
    private let dualTransport: DualSyncTransport
    
    public init(server: LanWebSocketServer, onIncomingMessage: (@Sendable (Data, TransportOrigin) async -> Void)? = nil) {
        self.server = server
        self.lanTransport = LanSyncTransport(server: server)
        
        // Initialize cloud relay transport with production configuration
        let cloudConfig = CloudRelayDefaults.production()
        self.cloudTransport = CloudRelayTransport(configuration: cloudConfig)
        
        // Set incoming message handler for cloud relay
        if let handler = onIncomingMessage {
            self.cloudTransport.setOnIncomingMessage(handler)
        }
        
        // Create dual transport that sends to both LAN and cloud simultaneously
        // Note: Crypto service and key provider will be set when SyncEngine is created
        // For now, we create DualSyncTransport without them - it will send same envelope to both
        // (nonce reuse will be handled by Android's nonce deduplication)
        // TODO: Pass crypto service and key provider to DualSyncTransport to enable unique nonces
        self.dualTransport = DualSyncTransport(
            lanTransport: lanTransport,
            cloudTransport: cloudTransport,
            cryptoService: nil,  // Will be set when SyncEngine is created
            keyProvider: nil     // Will be set when SyncEngine is created
        )
    }
    
    /// Set handler for incoming messages from cloud relay
    public func setCloudIncomingMessageHandler(_ handler: @escaping @Sendable (Data, TransportOrigin) async -> Void) {
        cloudTransport.setOnIncomingMessage(handler)
    }

    public func preferredTransport() -> SyncTransport {
        // Always use dual transport (sends to both LAN and cloud simultaneously)
        // This ensures maximum reliability regardless of preference
        return dualTransport
    }
    
    /// Get cloud transport instance for fallback scenarios
    public func getCloudTransport() -> CloudRelayTransport {
        return cloudTransport
    }
    
    /// Set the closure for getting discovered peers (used by LanSyncTransport for client-side connections)
    public func setGetDiscoveredPeers(_ closure: @escaping () -> [DiscoveredPeer]) {
        lanTransport.setGetDiscoveredPeers(closure)
    }
    
    /// Sync peer connections in LanSyncTransport (maintain persistent connections to all discovered peers)
    /// Called when peers are discovered/removed to keep connections in sync
    public func syncPeerConnections() async {
        await lanTransport.syncPeerConnections()
    }
    
    /// Get LAN transport instance for peer connection management
    public func getLanTransport() -> LanSyncTransport {
        return lanTransport
    }
}
