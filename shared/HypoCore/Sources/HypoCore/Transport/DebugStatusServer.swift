import Foundation
#if canImport(Network)
import Network
#endif

/// What the app knows about itself, in the shape a person debugging it needs.
///
/// Everything here was reconstructed by hand at least once — from `defaults read`,
/// from `log stream`, from the relay's own `/status` — while the app sitting right
/// there had all of it. None of it is secret: the relay token is reported as
/// present or absent, never echoed.
public struct DebugStatus: Codable, Sendable {
    public struct Device: Codable, Sendable {
        public let id: String
        public let name: String
        public let platform: String
        public let isOnline: Bool
        public let lastSeen: Date
        public let bonjourHost: String?
        public let bonjourPort: Int?
    }

    public struct Peer: Codable, Sendable {
        public let serviceName: String
        public let host: String
        public let port: Int
        public let deviceId: String?
        /// Without an advertised agreement key a peer cannot be paired with at all.
        public let advertisesPairingKey: Bool
        public let isPaired: Bool
        public let lastSeen: Date
    }

    public let generatedAt: Date
    public let version: String
    public let deviceId: String
    public let deviceName: String
    public let platform: String
    /// A build with no relay token gets 401 on every connection and shows every
    /// cloud peer as offline. Worth being able to ask.
    public let hasRelayToken: Bool
    public let connectionState: String
    public let lanServerPort: Int?
    /// How many peers the pairing UI is actually observing. If this is 0 while
    /// `discoveredPeers` is not, the published list is stale rather than the
    /// network being quiet.
    public let publishedPeerCount: Int
    /// The list the Nearby sheet draws, by service name.
    public let pairablePeers: [String]
    public let pairedDevices: [Device]
    public let discoveredPeers: [Peer]
}

#if canImport(Network)
/// Serves `DebugStatus` as JSON over HTTP on the loopback interface.
///
/// Loopback only, read-only, and bound late enough that it cannot interfere with
/// the LAN listener. `curl -s localhost:7011/status | jq` beats reading a plist.
@MainActor
public final class DebugStatusServer {
    public static let defaultPort = 7011

    private let port: Int
    private let snapshot: @MainActor () -> DebugStatus
    private var listener: NWListener?
    private let logger = HypoLogger(category: "DebugStatusServer")
    private let encoder: JSONEncoder

    public init(port: Int = DebugStatusServer.defaultPort, snapshot: @escaping @MainActor () -> DebugStatus) {
        self.port = port
        self.snapshot = snapshot
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    public func start() throws {
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "DebugStatusServer", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid debug port \(port)"
            ])
        }
        // Bind the loopback address explicitly rather than every interface: this
        // reports device names and ids, and none of that belongs on the network.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        // The port comes from `requiredLocalEndpoint`; passing it again via `on:`
        // is rejected as an invalid argument.
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handle(connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        logger.info("🩺 [DebugStatusServer] Listening on http://127.0.0.1:\(port)/status")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = Self.requestPath(from: request)
                self.respond(to: path, on: connection)
            }
        }
    }

    private func respond(to path: String?, on connection: NWConnection) {
        let response: Data
        switch path {
        case "/", "/status":
            do {
                response = Self.httpResponse(status: "200 OK", body: try encoder.encode(snapshot()))
            } catch {
                logger.error("❌ [DebugStatusServer] Could not encode status: \(error.localizedDescription)")
                response = Self.httpResponse(
                    status: "500 Internal Server Error",
                    body: Data(#"{"error":"could not encode status"}"#.utf8)
                )
            }
        default:
            response = Self.httpResponse(
                status: "404 Not Found",
                body: Data(#"{"error":"try /status"}"#.utf8)
            )
        }
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func requestPath(from request: String) -> String? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1].split(separator: "?").first ?? "")
    }

    private static func httpResponse(status: String, body: Data) -> Data {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        return Data(header.utf8) + body
    }
}
#endif
