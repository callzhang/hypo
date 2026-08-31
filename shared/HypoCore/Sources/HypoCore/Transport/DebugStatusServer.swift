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
    /// Which binary answered. The harness and the menu bar app both link this
    /// server, and when one of them is down the other answers on the same port --
    /// which reads as the app reporting nonsense rather than as the wrong process.
    public let processName: String
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

/// The result of asking the app to open a WebSocket to a peer, in its own words.
///
/// Whether a connection works from a terminal says little about whether it works
/// from inside the app: sandboxing, entitlements and the local-network permission
/// all apply to one and not the other. This makes the app answer for itself.
public struct DebugProbeResult: Codable, Sendable {
    public let url: String
    public let reachable: Bool
    public let error: String?
    public let errorDomain: String?
    public let errorCode: Int?

    public init(url: String, reachable: Bool, error: String? = nil, errorDomain: String? = nil, errorCode: Int? = nil) {
        self.url = url
        self.reachable = reachable
        self.error = error
        self.errorDomain = errorDomain
        self.errorCode = errorCode
    }
}

/// Opens a WebSocket to a peer exactly the way LAN pairing does, and reports what
/// happened rather than a friendly summary of it.
public enum LanReachabilityProbe {
    public static func probe(host: String, port: Int, deviceId: String) async -> DebugProbeResult {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "device_id", value: deviceId)]
        guard let url = components.url else {
            return DebugProbeResult(url: "\(host):\(port)", reachable: false, error: "could not build a URL")
        }

        var request = URLRequest(url: url)
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        let session = URLSession(configuration: .ephemeral)
        let task: URLSessionWebSocketTask = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        do {
            // A ping is the cheapest thing that fails when the handshake did.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            return DebugProbeResult(url: url.absoluteString, reachable: true)
        } catch {
            let nsError = error as NSError
            return DebugProbeResult(
                url: url.absoluteString,
                reachable: false,
                error: nsError.localizedDescription,
                errorDomain: nsError.domain,
                errorCode: nsError.code
            )
        }
    }
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

    /// Set by the owner so `/probe` can use the app's own identity.
    public var localDeviceId: String = ""

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let target = Self.requestTarget(from: request)
                if target?.path == "/probe" {
                    await self.respondToProbe(query: target?.query ?? [:], on: connection)
                } else {
                    self.respond(to: target?.path, on: connection)
                }
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
                body: Data(#"{"error":"try /status or /probe?host=&port="}"#.utf8)
            )
        }
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func respondToProbe(query: [String: String], on connection: NWConnection) async {
        guard let host = query["host"], !host.isEmpty, let port = query["port"].flatMap(Int.init) else {
            let body = Data(#"{"error":"try /probe?host=10.0.0.5&port=7010"}"#.utf8)
            connection.send(content: Self.httpResponse(status: "400 Bad Request", body: body), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        let result = await LanReachabilityProbe.probe(host: host, port: port, deviceId: localDeviceId)
        let body = (try? encoder.encode(result)) ?? Data(#"{"error":"could not encode result"}"#.utf8)
        connection.send(content: Self.httpResponse(status: "200 OK", body: body), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func requestTarget(from request: String) -> (path: String, query: [String: String])? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://localhost" + target) else {
            return (path: target, query: [:])
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return (path: components.path, query: query)
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
