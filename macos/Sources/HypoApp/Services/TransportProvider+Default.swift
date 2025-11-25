import Foundation

@MainActor
public final class DefaultTransportProvider: TransportProvider {
    private let server: LanWebSocketServer
    private let lanTransport: LanSyncTransport
    private let cloudTransport: CloudRelayTransport
    private let dualTransport: DualSyncTransport
    
    public init(server: LanWebSocketServer, onIncomingMessage: ((Data, TransportOrigin) async -> Void)? = nil) {
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
        self.dualTransport = DualSyncTransport(
            lanTransport: lanTransport,
            cloudTransport: cloudTransport
        )
    }
    
    /// Set handler for incoming messages from cloud relay
    public func setCloudIncomingMessageHandler(_ handler: @escaping (Data, TransportOrigin) async -> Void) {
        cloudTransport.setOnIncomingMessage(handler)
    }

    public func preferredTransport(for preference: TransportPreference) -> SyncTransport {
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
}

private struct NoopSyncTransport: SyncTransport {
    let preference: TransportPreference

    func connect() async throws {}

    func send(_ envelope: SyncEnvelope) async throws {
        // No-op: Placeholder transport used until real LAN/cloud transports are wired in.
    }

    func disconnect() async {}
}
