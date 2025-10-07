import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CloudRelayConfiguration: Sendable, Equatable {
    public let url: URL
    public let fingerprint: String?
    public let headers: [String: String]
    public let idleTimeout: TimeInterval

    public init(
        url: URL,
        fingerprint: String?,
        headers: [String: String] = [:],
        idleTimeout: TimeInterval = 30
    ) {
        self.url = url
        self.fingerprint = fingerprint
        self.headers = headers
        self.idleTimeout = idleTimeout
    }
}

public final class CloudRelayTransport: SyncTransport {
    private let delegate: LanWebSocketTransport

    public init(
        configuration: CloudRelayConfiguration,
        frameCodec: TransportFrameCodec = TransportFrameCodec(),
        metricsRecorder: TransportMetricsRecorder = NullTransportMetricsRecorder(),
        analytics: TransportAnalytics = NoopTransportAnalytics(),
        sessionFactory: @escaping @Sendable (URLSessionDelegate, TimeInterval) -> URLSessionProviding = { delegate, timeout in
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        }
    ) {
        let lanConfiguration = LanWebSocketConfiguration(
            url: configuration.url,
            pinnedFingerprint: configuration.fingerprint,
            headers: configuration.headers,
            idleTimeout: configuration.idleTimeout,
            environment: "cloud"
        )
        delegate = LanWebSocketTransport(
            configuration: lanConfiguration,
            frameCodec: frameCodec,
            metricsRecorder: metricsRecorder,
            analytics: analytics,
            sessionFactory: sessionFactory
        )
    }

    public func connect() async throws {
        try await delegate.connect()
    }

    public func send(_ envelope: SyncEnvelope) async throws {
        try await delegate.send(envelope)
    }

    public func disconnect() async {
        await delegate.disconnect()
    }

    func handleOpen(task: WebSocketTasking) {
        delegate.handleOpen(task: task)
    }

    var underlying: LanWebSocketTransport { delegate }
}
