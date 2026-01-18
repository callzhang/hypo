import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Represents a connected peer device with its ID and optional name.
public struct ConnectedPeer: Sendable, Equatable {
    public let deviceId: String
    public let name: String?
    
    public init(deviceId: String, name: String?) {
        self.deviceId = deviceId
        self.name = name
    }
}

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

private struct ConnectedDeviceInfoResponse: Decodable {
    let device_id: String
    let last_seen: Date
}

private struct ConnectedPeersResponse: Decodable {
    let connected_devices: [ConnectedDeviceInfoResponse]
}

@MainActor
public final class CloudRelayTransport: SyncTransport, @unchecked Sendable {
    private let delegate: WebSocketTransport
    private var nameLookup: ((String) -> String?)?
    private let presenceDecoder: JSONDecoder
    private let httpSession: URLSession

    public init(
        configuration: CloudRelayConfiguration,
        frameCodec: TransportFrameCodec = TransportFrameCodec(),
        metricsRecorder: TransportMetricsRecorder = NullTransportMetricsRecorder(),
        analytics: TransportAnalytics = NoopTransportAnalytics(),
        nameLookup: ((String) -> String?)? = nil,
        sessionFactory: @escaping @Sendable (URLSessionDelegate, TimeInterval) -> URLSessionProviding = { delegate, timeout in
            let config = URLSessionConfiguration.ephemeral
            // WebSocket connections should stay open indefinitely
            // Use a very long timeout (1 year) instead of greatestFiniteMagnitude which may not work
            let oneYear: TimeInterval = 365 * 24 * 60 * 60
            config.timeoutIntervalForRequest = oneYear
            config.timeoutIntervalForResource = oneYear
            config.waitsForConnectivity = true
            config.isDiscretionary = false
            config.allowsCellularAccess = true
            return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        },
        urlSession: URLSession = .shared
    ) {
        let webSocketConfiguration = WebSocketConfiguration(
            url: configuration.url,
            pinnedFingerprint: configuration.fingerprint,
            headers: configuration.headers,
            idleTimeout: configuration.idleTimeout,
            environment: "cloud"
        )
        delegate = WebSocketTransport(
            configuration: webSocketConfiguration,
            frameCodec: frameCodec,
            metricsRecorder: metricsRecorder,
            analytics: analytics,
            sessionFactory: sessionFactory
        )
        self.nameLookup = nameLookup
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.presenceDecoder = decoder
        self.httpSession = urlSession
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

    var underlying: WebSocketTransport { delegate }
    
    /// Check if the cloud transport is currently connected
    public func isConnected() -> Bool {
        return delegate.isConnected()
    }
    
    /// Set handler for incoming messages from cloud relay
    public func setOnIncomingMessage(_ handler: @escaping @Sendable (Data, TransportOrigin) async -> Void) {
        delegate.setOnIncomingMessage(handler)
    }
    
    /// Set the closure for looking up device names by device ID
    /// This closure will be used when querying connected peers to include device names
    public func setNameLookup(_ lookup: @escaping (String) -> String?) {
        nameLookup = lookup
    }
    
    /// Force reconnection by disconnecting and reconnecting.
    /// Used when network changes to ensure connection uses new IP address.
    public func reconnect() async {
        await delegate.disconnect()
        // Small delay to let connection close
        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        try? await delegate.connect()
    }
    
    /// Query connected peers from cloud relay
    /// Returns list of connected peers with their IDs and names, or empty array if query fails
    /// Device names are looked up using the nameLookup closure if provided
    /// - Parameter peerIds: Optional list of device IDs to check presence for. If nil, returns all connected peers (server may limit this).
    public func queryConnectedPeers(peerIds: [String]? = nil) async -> [ConnectedPeer] {
        guard let peerIds, !peerIds.isEmpty else { return [] }
        guard let baseURL = presenceBaseURL(from: delegate.configuration.url) else { return [] }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""
        if !path.hasSuffix("/") {
            path += "/"
        }
        components?.path = path + "peers"
        components?.queryItems = peerIds.map { URLQueryItem(name: "device_id", value: $0) }

        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await httpSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            let payload = try presenceDecoder.decode(ConnectedPeersResponse.self, from: data)
            return payload.connected_devices.map { device in
                let name = nameLookup?(device.device_id)
                return ConnectedPeer(deviceId: device.device_id, name: name)
            }
        } catch {
            return []
        }
    }

    private func presenceBaseURL(from wsURL: URL) -> URL? {
        guard var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        default:
            break
        }
        if components.path.hasSuffix("/ws") {
            components.path = String(components.path.dropLast(3))
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.url
    }
}
