import Foundation

public struct DefaultTransportProvider: TransportProvider {
    public init() {}

    public func preferredTransport(for preference: TransportPreference) -> SyncTransport {
        NoopSyncTransport(preference: preference)
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
