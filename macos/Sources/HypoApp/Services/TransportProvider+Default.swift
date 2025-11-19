import Foundation

@MainActor
public final class DefaultTransportProvider: TransportProvider {
    private let server: LanWebSocketServer
    private let lanTransport: LanSyncTransport
    private let cloudTransport: CloudRelayTransport
    
    public init(server: LanWebSocketServer) {
        self.server = server
        self.lanTransport = LanSyncTransport(server: server)
        
        // Initialize cloud relay transport with production configuration
        let cloudConfig = CloudRelayDefaults.production()
        self.cloudTransport = CloudRelayTransport(configuration: cloudConfig)
    }

    public func preferredTransport(for preference: TransportPreference) -> SyncTransport {
        switch preference {
        case .lanFirst:
            return lanTransport
        case .cloudOnly:
            return cloudTransport
        }
    }
    
    /// Get cloud transport instance for fallback scenarios
    public func getCloudTransport() -> CloudRelayTransport {
        return cloudTransport
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
