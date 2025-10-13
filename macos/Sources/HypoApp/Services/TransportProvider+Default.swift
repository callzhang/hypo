import Foundation

@MainActor
public final class DefaultTransportProvider: TransportProvider {
    private let server: LanWebSocketServer
    private let lanTransport: LanSyncTransport
    
    public init(server: LanWebSocketServer) {
        self.server = server
        self.lanTransport = LanSyncTransport(server: server)
    }

    public func preferredTransport(for preference: TransportPreference) -> SyncTransport {
        switch preference {
        case .lanFirst:
            return lanTransport
        case .cloudOnly:
            // TODO: Implement CloudRelayTransport when cloud fallback is needed
            return lanTransport
        }
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
