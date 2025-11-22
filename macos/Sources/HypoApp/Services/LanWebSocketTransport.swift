import Foundation
import Crypto
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

public struct LanWebSocketConfiguration: Sendable, Equatable {
    public let url: URL
    public let pinnedFingerprint: String?
    public let headers: [String: String]
    public let idleTimeout: TimeInterval
    public let environment: String
    public let roundTripTimeout: TimeInterval

    public init(
        url: URL,
        pinnedFingerprint: String?,
        headers: [String: String] = [:],
        idleTimeout: TimeInterval = 30,
        environment: String = "lan",
        roundTripTimeout: TimeInterval = 60
    ) {
        self.url = url
        self.pinnedFingerprint = pinnedFingerprint
        self.headers = headers
        self.idleTimeout = idleTimeout
        self.environment = environment
        self.roundTripTimeout = roundTripTimeout
    }
}

public protocol WebSocketTasking: AnyObject {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, Error>) -> Void)
}

extension URLSessionWebSocketTask: WebSocketTasking {}

public protocol URLSessionProviding {
    func webSocketTask(with request: URLRequest) -> WebSocketTasking
    func invalidateAndCancel()
}

extension URLSession: URLSessionProviding {
    public func webSocketTask(with request: URLRequest) -> WebSocketTasking {
        return (self as URLSession).webSocketTask(with: request) as URLSessionWebSocketTask
    }
}

public final class LanWebSocketTransport: NSObject, SyncTransport {
    private enum ConnectionState {
        case idle
        case connecting
        case connected(WebSocketTasking)
    }

    private let configuration: LanWebSocketConfiguration
    private let sessionFactory: @Sendable (URLSessionDelegate, TimeInterval) -> URLSessionProviding
    private let frameCodec: TransportFrameCodec
    private let metricsRecorder: TransportMetricsRecorder
    private let analytics: TransportAnalytics
    private var session: URLSessionProviding?
    private var state: ConnectionState = .idle
    private var handshakeContinuation: CheckedContinuation<Void, Error>?
    private var watchdogTask: Task<Void, Never>?
    private var lastActivity: Date = Date()
    private var handshakeStartedAt: Date?
    private let pendingRoundTrips: PendingRoundTripStore
    private var onIncomingMessage: ((Data) async -> Void)?

    public init(
        configuration: LanWebSocketConfiguration,
        frameCodec: TransportFrameCodec = TransportFrameCodec(),
        metricsRecorder: TransportMetricsRecorder = NullTransportMetricsRecorder(),
        analytics: TransportAnalytics = NoopTransportAnalytics(),
        sessionFactory: @escaping @Sendable (URLSessionDelegate, TimeInterval) -> URLSessionProviding = { delegate, timeout in
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = max(timeout, 60) // Minimum 60 seconds for WebSocket handshake
            config.timeoutIntervalForResource = max(timeout * 2, 120) // Longer timeout for WebSocket connections
            config.waitsForConnectivity = true
            return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        },
        onIncomingMessage: ((Data) async -> Void)? = nil
    ) {
        self.configuration = configuration
        self.frameCodec = frameCodec
        self.metricsRecorder = metricsRecorder
        self.analytics = analytics
        self.sessionFactory = sessionFactory
        self.pendingRoundTrips = PendingRoundTripStore(maxAge: configuration.roundTripTimeout)
        self.onIncomingMessage = onIncomingMessage
    }
    
    public func setOnIncomingMessage(_ handler: @escaping (Data) async -> Void) {
        self.onIncomingMessage = handler
    }

    deinit {
        watchdogTask?.cancel()
        session?.invalidateAndCancel()
    }

    public func connect() async throws {
        let connectStartMsg = "🔌 [LanWebSocketTransport] connect() called, state: \(state), url: \(configuration.url)\n"
        print(connectStartMsg)
        try? connectStartMsg.appendToFile(path: "/tmp/hypo_debug.log")
        
        switch state {
        case .connected:
            let alreadyMsg = "✅ [LanWebSocketTransport] Already connected\n"
            print(alreadyMsg)
            try? alreadyMsg.appendToFile(path: "/tmp/hypo_debug.log")
            return
        case .connecting:
            let waitingMsg = "⏳ [LanWebSocketTransport] Already connecting, waiting...\n"
            print(waitingMsg)
            try? waitingMsg.appendToFile(path: "/tmp/hypo_debug.log")
            try await withCheckedThrowingContinuation { continuation in
                handshakeContinuation = continuation
            }
            return
        case .idle:
            break
        }

        state = .connecting
        handshakeStartedAt = Date()
        lastActivity = Date()

        let session = sessionFactory(self, configuration.idleTimeout)
        self.session = session
        
        // Build URL with query parameters as fallback if headers don't work
        var url = configuration.url
        if let deviceId = configuration.headers["X-Device-Id"],
           let platform = configuration.headers["X-Device-Platform"] {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var queryItems = components?.queryItems ?? []
            queryItems.append(URLQueryItem(name: "device_id", value: deviceId))
            queryItems.append(URLQueryItem(name: "platform", value: platform))
            components?.queryItems = queryItems
            if let newUrl = components?.url {
                url = newUrl
            }
        }
        
        var request = URLRequest(url: url)
        let headersCount = configuration.headers.count
        let headersMsg = "📋 [LanWebSocketTransport] Setting \(headersCount) headers + query params\n"
        print(headersMsg)
        fflush(stdout)
        try? headersMsg.appendToFile(path: "/tmp/hypo_debug.log")
        if configuration.headers.isEmpty {
            let emptyMsg = "⚠️ [LanWebSocketTransport] WARNING: Headers dictionary is EMPTY!\n"
            print(emptyMsg)
            fflush(stdout)
            try? emptyMsg.appendToFile(path: "/tmp/hypo_debug.log")
        }
        configuration.headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
            let headerMsg = "📋 [LanWebSocketTransport] Set header: \(key) = \(value)\n"
            print(headerMsg)
            fflush(stdout)
            try? headerMsg.appendToFile(path: "/tmp/hypo_debug.log")
        }
        let allHeadersMsg = "📋 [LanWebSocketTransport] Final URL: \(url.absoluteString)\n"
        print(allHeadersMsg)
        fflush(stdout)
        try? allHeadersMsg.appendToFile(path: "/tmp/hypo_debug.log")
        let requestHeadersMsg = "📋 [LanWebSocketTransport] Request headers: \(request.allHTTPHeaderFields ?? [:])\n"
        print(requestHeadersMsg)
        fflush(stdout)
        try? requestHeadersMsg.appendToFile(path: "/tmp/hypo_debug.log")

        let task = session.webSocketTask(with: request)
        state = .connecting
        
        let resumeMsg = "🚀 [LanWebSocketTransport] Resuming WebSocket task\n"
        print(resumeMsg)
        try? resumeMsg.appendToFile(path: "/tmp/hypo_debug.log")

        // CRITICAL: Retain self and session during connection to prevent deallocation
        let retainedSelf = self
        let retainedSession = session
        
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Ensure session and self are retained
                let _ = retainedSelf
                let _ = retainedSession
                
                retainedSelf.handshakeContinuation = continuation
                task.resume()
            }
            let successMsg = "✅ [LanWebSocketTransport] Connection established successfully\n"
            print(successMsg)
            try? successMsg.appendToFile(path: "/tmp/hypo_debug.log")
        } catch {
            let errorMsg = "❌ [LanWebSocketTransport] Connection failed: \(error.localizedDescription)\n"
            print(errorMsg)
            try? errorMsg.appendToFile(path: "/tmp/hypo_debug.log")
            throw error
        }
    }

    public func send(_ envelope: SyncEnvelope) async throws {
        try await ensureConnected()
        guard case .connected(let task) = state else {
            throw NSError(domain: "LanWebSocketTransport", code: -2, userInfo: [NSLocalizedDescriptionKey: "Transport not connected"])
        }
        let data = try frameCodec.encode(envelope)
        await pendingRoundTrips.store(date: Date(), for: envelope.id)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.send(.data(data)) { [weak self] error in
                guard let self else { return }
                if let error {
                    continuation.resume(throwing: error)
                    Task { await self.pendingRoundTrips.remove(id: envelope.id) }
                } else {
                    self.touch()
                    continuation.resume(returning: ())
                }
            }
        }
    }

    public func disconnect() async {
        watchdogTask?.cancel()
        watchdogTask = nil
        var taskToCancel: WebSocketTasking?
        switch state {
        case .connected(let task):
            taskToCancel = task
        case .connecting:
            if let continuation = handshakeContinuation {
                handshakeContinuation = nil
                continuation.resume(throwing: CancellationError())
            }
        default:
            break
        }
        state = .idle
        taskToCancel?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        session = nil
        handshakeStartedAt = nil
        await pendingRoundTrips.removeAll()
    }
    
    /// Check if the transport is currently connected
    public func isConnected() -> Bool {
        switch state {
        case .connected:
            return true
        case .connecting, .idle:
            return false
        }
    }

    private func ensureConnected() async throws {
        switch state {
        case .connected:
            return
        case .idle, .connecting:
            try await connect()
        }
    }

    private func startWatchdog(for task: WebSocketTasking) {
        watchdogTask?.cancel()
        watchdogTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.configuration.idleTimeout * 1_000_000_000))
                if Task.isCancelled { return }
                let elapsed = Date().timeIntervalSince(self.lastActivity)
                if elapsed >= self.configuration.idleTimeout {
                    await self.closeDueToIdle(task: task)
                    return
                }
            }
        }
    }

    private func touch() {
        lastActivity = Date()
    }

    private func closeDueToIdle(task: WebSocketTasking) async {
        guard case .connected(let current) = state, current === task else {
            return
        }
        task.cancel(with: .goingAway, reason: "Idle timeout".data(using: .utf8))
        await disconnect()
    }
}

extension LanWebSocketTransport: @unchecked Sendable {}

extension LanWebSocketTransport: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocolName: String?) {
        let delegateMsg = "🎉 [LanWebSocketTransport] didOpenWithProtocol called! protocol: \(protocolName ?? "nil")\n"
        print(delegateMsg)
        try? delegateMsg.appendToFile(path: "/tmp/hypo_debug.log")
        handleOpen(task: webSocketTask)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let closeMsg = "🔌 [LanWebSocketTransport] didCloseWith: code=\(closeCode.rawValue), reason=\(reason != nil ? String(data: reason!, encoding: .utf8) ?? "binary" : "nil")\n"
        print(closeMsg)
        try? closeMsg.appendToFile(path: "/tmp/hypo_debug.log")
        state = .idle
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let errorMsg = error != nil ? error!.localizedDescription : "none"
        let completeMsg = "🔚 [LanWebSocketTransport] didCompleteWithError: \(errorMsg)\n"
        print(completeMsg)
        try? completeMsg.appendToFile(path: "/tmp/hypo_debug.log")
        
        if let continuation = handshakeContinuation {
            handshakeContinuation = nil
            continuation.resume(throwing: error ?? NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown))
        }
        handshakeStartedAt = nil
        state = .idle
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func receiveNext(on task: WebSocketTasking) {
        let receiveMsg = "📡 [LanWebSocketTransport] receiveNext() called, setting up receive callback\n"
        print(receiveMsg)
        try? receiveMsg.appendToFile(path: "/tmp/hypo_debug.log")
        task.receive { [weak self] result in
            guard let self else {
                let nilMsg = "⚠️ [LanWebSocketTransport] Self is nil in receive callback\n"
                print(nilMsg)
                try? nilMsg.appendToFile(path: "/tmp/hypo_debug.log")
                return
            }
            let callbackMsg = "📡 [LanWebSocketTransport] receive callback triggered\n"
            print(callbackMsg)
            try? callbackMsg.appendToFile(path: "/tmp/hypo_debug.log")
            switch result {
            case .success(let message):
                self.touch()
                let successMsg = "✅ [LanWebSocketTransport] Message received: \(message)\n"
                print(successMsg)
                try? successMsg.appendToFile(path: "/tmp/hypo_debug.log")
                if case .data(let data) = message {
                    let dataMsg = "📦 [LanWebSocketTransport] Binary data received: \(data.count) bytes\n"
                    print(dataMsg)
                    try? dataMsg.appendToFile(path: "/tmp/hypo_debug.log")
                    self.handleIncoming(data: data)
                } else {
                    let nonDataMsg = "⚠️ [LanWebSocketTransport] Non-binary message received\n"
                    print(nonDataMsg)
                    try? nonDataMsg.appendToFile(path: "/tmp/hypo_debug.log")
                }
                self.receiveNext(on: task)
            case .failure(let error):
                let errorMsg = "❌ [LanWebSocketTransport] Receive failed: \(error.localizedDescription)\n"
                print(errorMsg)
                try? errorMsg.appendToFile(path: "/tmp/hypo_debug.log")
                Task { await self.disconnect() }
            }
        }
    }

    private func handleIncoming(data: Data) {
        let handleMsg = "📥 [LanWebSocketTransport] handleIncoming: \(data.count) bytes\n"
        print(handleMsg)
        try? handleMsg.appendToFile(path: "/tmp/hypo_debug.log")
        
        do {
            let envelope = try frameCodec.decode(data)
            Task { [metricsRecorder] in
                let now = Date()
                if let startedAt = await pendingRoundTrips.remove(id: envelope.id) {
                    let duration = now.timeIntervalSince(startedAt)
                    metricsRecorder.recordRoundTrip(envelopeId: envelope.id.uuidString, duration: duration)
                }
                await pendingRoundTrips.pruneExpired(referenceDate: now)
            }
            
            // Forward to incoming message handler (for cloud relay messages)
            if let handler = onIncomingMessage {
                let forwardMsg = "📤 [LanWebSocketTransport] Forwarding to onIncomingMessage handler\n"
                print(forwardMsg)
                try? forwardMsg.appendToFile(path: "/tmp/hypo_debug.log")
                Task {
                    await handler(data)
                }
            } else {
                let noHandlerMsg = "⚠️ [LanWebSocketTransport] No onIncomingMessage handler set\n"
                print(noHandlerMsg)
                try? noHandlerMsg.appendToFile(path: "/tmp/hypo_debug.log")
            }
        } catch {
            let errorMsg = "❌ [LanWebSocketTransport] Failed to decode incoming data: \(error)\n"
            print(errorMsg)
            try? errorMsg.appendToFile(path: "/tmp/hypo_debug.log")
            Task {
                await pendingRoundTrips.pruneExpired(referenceDate: Date())
            }
        }
    }

    func handleOpen(task: WebSocketTasking) {
        let openMsg = "✅ [LanWebSocketTransport] handleOpen() called, connection established\n"
        print(openMsg)
        try? openMsg.appendToFile(path: "/tmp/hypo_debug.log")
        state = .connected(task)
        touch()
        startWatchdog(for: task)
        if let startedAt = handshakeStartedAt {
            let duration = Date().timeIntervalSince(startedAt)
            metricsRecorder.recordHandshake(duration: duration, timestamp: Date())
        }
        handshakeStartedAt = nil
        handshakeContinuation?.resume(returning: ())
        handshakeContinuation = nil
        let receiveNextMsg = "📡 [LanWebSocketTransport] handleOpen: Starting receiveNext()\n"
        print(receiveNextMsg)
        try? receiveNextMsg.appendToFile(path: "/tmp/hypo_debug.log")
        receiveNext(on: task)
    }
}

extension LanWebSocketTransport: URLSessionDelegate {
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
#if canImport(Security)
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let expected = configuration.pinnedFingerprint else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverCertificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            analytics.record(
                .pinningFailure(
                    environment: configuration.environment,
                    host: configuration.url.host ?? "unknown",
                    message: "Missing server certificate",
                    timestamp: Date()
                )
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let serverData = SecCertificateCopyData(serverCertificate) as Data
        let digest = SHA256.hash(data: serverData)
        let fingerprint = digest.compactMap { String(format: "%02x", $0) }.joined()
        if fingerprint.caseInsensitiveCompare(expected) == .orderedSame {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            analytics.record(
                .pinningFailure(
                    environment: configuration.environment,
                    host: configuration.url.host ?? "unknown",
                    message: "Fingerprint mismatch",
                    timestamp: Date()
                )
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
#else
        completionHandler(.performDefaultHandling, nil)
#endif
    }
}

private actor PendingRoundTripStore {
    private var storage: [UUID: Date] = [:]
    private let maxAge: TimeInterval

    init(maxAge: TimeInterval) {
        self.maxAge = max(0, maxAge)
    }

    func store(date: Date, for id: UUID) {
        pruneExpired(referenceDate: date)
        storage[id] = date
    }

    func remove(id: UUID) -> Date? {
        storage.removeValue(forKey: id)
    }

    func pruneExpired(referenceDate: Date) {
        guard maxAge > 0 else {
            storage.removeAll()
            return
        }
        let cutoff = referenceDate.addingTimeInterval(-maxAge)
        storage = storage.filter { $0.value >= cutoff }
    }

    func removeAll() {
        storage.removeAll()
    }
}
