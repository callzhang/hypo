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
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
}

extension URLSessionWebSocketTask: WebSocketTasking {
    // URLSessionWebSocketTask uses sendPing(pongReceiveHandler:), which matches the protocol
    // The protocol conformance is automatic
}

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
    private var onIncomingMessage: ((Data, TransportOrigin) async -> Void)?
    
    // Message queue with retry logic
    private struct QueuedMessage {
        let envelope: SyncEnvelope
        let data: Data
        let queuedAt: Date
        var retryCount: UInt
    }
    private var messageQueue: [QueuedMessage] = []
    private var isProcessingQueue = false
    private var queueProcessingTask: Task<Void, Never>?
    private var receiveRetryCount: UInt = 0
    private var lastReceiveFailure: Date?

    public init(
        configuration: LanWebSocketConfiguration,
        frameCodec: TransportFrameCodec = TransportFrameCodec(),
        metricsRecorder: TransportMetricsRecorder = NullTransportMetricsRecorder(),
        analytics: TransportAnalytics = NoopTransportAnalytics(),
        sessionFactory: @escaping @Sendable (URLSessionDelegate, TimeInterval) -> URLSessionProviding = { delegate, timeout in
            let config = URLSessionConfiguration.default
            // WebSocket connections should stay open indefinitely
            // Use a very long timeout (1 year) instead of greatestFiniteMagnitude which may not work
            let oneYear: TimeInterval = 365 * 24 * 60 * 60
            config.timeoutIntervalForRequest = oneYear
            config.timeoutIntervalForResource = oneYear
            config.waitsForConnectivity = true
            config.isDiscretionary = false
            // Allow background tasks for WebSocket connections
            config.allowsCellularAccess = true
            return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        },
        onIncomingMessage: ((Data, TransportOrigin) async -> Void)? = nil
    ) {
        self.configuration = configuration
        self.frameCodec = frameCodec
        self.metricsRecorder = metricsRecorder
        self.analytics = analytics
        self.sessionFactory = sessionFactory
        self.pendingRoundTrips = PendingRoundTripStore(maxAge: configuration.roundTripTimeout)
        self.onIncomingMessage = onIncomingMessage
    }
    
    public func setOnIncomingMessage(_ handler: @escaping (Data, TransportOrigin) async -> Void) {
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
        
        var request = URLRequest(url: configuration.url)
        if configuration.headers.isEmpty {
            let emptyMsg = "⚠️ [LanWebSocketTransport] WARNING: Headers dictionary is EMPTY!\n"
            print(emptyMsg)
            fflush(stdout)
            try? emptyMsg.appendToFile(path: "/tmp/hypo_debug.log")
        }
        configuration.headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        // CRITICAL: Remove query parameters for LAN connections only
        // URLSessionWebSocketTask doesn't handle query params correctly for LAN connections
        // But cloud relay may require query parameters, so preserve them for cloud connections
        let originalURL = configuration.url
        let scheme = originalURL.scheme ?? "wss"
        let host = originalURL.host ?? ""
        let path = originalURL.path.isEmpty ? "/ws" : originalURL.path
        let isCloudConnection = configuration.environment == "cloud" || scheme == "wss"
        
        let finalURL: URL
        if isCloudConnection {
            // For cloud connections, preserve query parameters if present
            finalURL = originalURL
            let cloudURLMsg = "☁️ [LanWebSocketTransport] Cloud connection - preserving query parameters: \(originalURL.absoluteString)\n"
            print(cloudURLMsg)
            try? cloudURLMsg.appendToFile(path: "/tmp/hypo_debug.log")
        } else {
            // For LAN connections, remove query parameters
            let cleanURLString = "\(scheme)://\(host)\(path)"
            guard let url = URL(string: cleanURLString) else {
                let errorMsg = "❌ [LanWebSocketTransport] Failed to create clean URL from: \(cleanURLString)\n"
                print(errorMsg)
                try? errorMsg.appendToFile(path: "/tmp/hypo_debug.log")
                throw NSError(domain: "LanWebSocketTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create clean URL"])
            }
            finalURL = url
            let lanURLMsg = "📡 [LanWebSocketTransport] LAN connection - removed query parameters: \(cleanURLString)\n"
            print(lanURLMsg)
            try? lanURLMsg.appendToFile(path: "/tmp/hypo_debug.log")
        }
        request.url = finalURL
        // Verify the URL was set correctly (log only if mismatch)
        if let requestURL = request.url?.absoluteString, requestURL != finalURL.absoluteString {
            let verifyMsg = "⚠️ [LanWebSocketTransport] URL mismatch! Expected: \(finalURL.absoluteString), Got: \(requestURL)\n"
            print(verifyMsg)
            fflush(stdout)
            try? verifyMsg.appendToFile(path: "/tmp/hypo_debug.log")
        }
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
        let data = try frameCodec.encode(envelope)
        await pendingRoundTrips.store(date: Date(), for: envelope.id)
        
        // Add to queue
        let queuedMessage = QueuedMessage(
            envelope: envelope,
            data: data,
            queuedAt: Date(),
            retryCount: 0
        )
        messageQueue.append(queuedMessage)
        
        let queueMsg = "📥 [LanWebSocketTransport] Queued message (queue size: \(messageQueue.count))\n"
        print(queueMsg)
        try? queueMsg.appendToFile(path: "/tmp/hypo_debug.log")
        
        // Start queue processor if not already running
        if queueProcessingTask == nil || queueProcessingTask?.isCancelled == true {
            queueProcessingTask = Task { [weak self] in
                await self?.processMessageQueue()
            }
        }
        
        // Wait for message to be sent (with timeout)
        // Note: This is fire-and-forget from caller's perspective, but we track it internally
        // The queue processor will handle retries
    }
    
    private func processMessageQueue() async {
        let maxRetries: UInt = 8
        let initialBackoff: TimeInterval = 1.0 // 1 second
        let maxTimeout: TimeInterval = 600.0 // 10 minutes
        
        while !messageQueue.isEmpty {
            var queuedMessage = messageQueue.removeFirst()
            
            // Check timeout (10 minutes from queue time)
            if Date().timeIntervalSince(queuedMessage.queuedAt) > maxTimeout {
                let timeoutMsg = "❌ [LanWebSocketTransport] Message timeout after \(queuedMessage.retryCount) retries (10 min elapsed), dropping\n"
                print(timeoutMsg)
                try? timeoutMsg.appendToFile(path: "/tmp/hypo_debug.log")
                await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                continue
            }
            
            // Calculate backoff: 1s, 2s, 4s, 8s, 16s, 32s, 64s, 128s
            let backoff = initialBackoff * pow(2.0, Double(queuedMessage.retryCount))
            
            // Wait before retry (skip wait on first attempt)
            if queuedMessage.retryCount > 0 {
                let backoffMsg = "⏳ [LanWebSocketTransport] Retry \(queuedMessage.retryCount)/\(maxRetries) after \(Int(backoff))s backoff\n"
                print(backoffMsg)
                try? backoffMsg.appendToFile(path: "/tmp/hypo_debug.log")
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
            
            // Ensure connection before each attempt
            do {
                try await ensureConnected()
            } catch {
                let connectErrorMsg = "⚠️ [LanWebSocketTransport] Connection failed on retry \(queuedMessage.retryCount): \(error.localizedDescription)\n"
                print(connectErrorMsg)
                try? connectErrorMsg.appendToFile(path: "/tmp/hypo_debug.log")
                queuedMessage.retryCount += 1
                if queuedMessage.retryCount <= maxRetries {
                    messageQueue.append(queuedMessage)
                } else {
                    let maxRetriesMsg = "❌ [LanWebSocketTransport] Max retries reached, dropping message\n"
                    print(maxRetriesMsg)
                    try? maxRetriesMsg.appendToFile(path: "/tmp/hypo_debug.log")
                    await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                }
                continue
            }
            
            guard case .connected(let task) = state else {
                let stateErrorMsg = "⚠️ [LanWebSocketTransport] Not connected after ensureConnected() on retry \(queuedMessage.retryCount)\n"
                print(stateErrorMsg)
                try? stateErrorMsg.appendToFile(path: "/tmp/hypo_debug.log")
                queuedMessage.retryCount += 1
                if queuedMessage.retryCount <= maxRetries {
                    messageQueue.append(queuedMessage)
                } else {
                    let maxRetriesMsg = "❌ [LanWebSocketTransport] Max retries reached, dropping message\n"
                    print(maxRetriesMsg)
                    try? maxRetriesMsg.appendToFile(path: "/tmp/hypo_debug.log")
                    await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                }
                continue
            }
            
            // Attempt to send
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    task.send(.data(queuedMessage.data)) { [weak self] error in
                        guard let self else {
                            continuation.resume(throwing: NSError(domain: "LanWebSocketTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self deallocated"]))
                            return
                        }
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            self.touch()
                            continuation.resume(returning: ())
                        }
                    }
                }
                
                // Success!
                let successMsg = "✅ [LanWebSocketTransport] Message sent successfully after \(queuedMessage.retryCount) retries (queue size: \(messageQueue.count))\n"
                print(successMsg)
                try? successMsg.appendToFile(path: "/tmp/hypo_debug.log")
                await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                
            } catch {
                let errorMsg = "❌ [LanWebSocketTransport] Send failed on retry \(queuedMessage.retryCount)/\(maxRetries): \(error.localizedDescription)\n"
                print(errorMsg)
                try? errorMsg.appendToFile(path: "/tmp/hypo_debug.log")
                queuedMessage.retryCount += 1
                if queuedMessage.retryCount <= maxRetries {
                    messageQueue.append(queuedMessage)
                } else {
                    let maxRetriesMsg = "❌ [LanWebSocketTransport] Max retries reached, dropping message\n"
                    print(maxRetriesMsg)
                    try? maxRetriesMsg.appendToFile(path: "/tmp/hypo_debug.log")
                    await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                }
            }
        }
        
        // Queue is empty, stop processing
        queueProcessingTask = nil
        let emptyMsg = "✅ [LanWebSocketTransport] Message queue empty, stopping processor\n"
        print(emptyMsg)
        try? emptyMsg.appendToFile(path: "/tmp/hypo_debug.log")
    }

    public func disconnect() async {
        watchdogTask?.cancel()
        watchdogTask = nil
        queueProcessingTask?.cancel()
        queueProcessingTask = nil
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
        
        // Clear message queue on disconnect
        let queueSize = messageQueue.count
        if queueSize > 0 {
            let clearMsg = "🧹 [LanWebSocketTransport] Clearing \(queueSize) queued messages on disconnect\n"
            print(clearMsg)
            try? clearMsg.appendToFile(path: "/tmp/hypo_debug.log")
            for queuedMessage in messageQueue {
                _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
            }
            messageQueue.removeAll()
        }
        
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
        // For cloud relay connections, use ping/pong keepalive instead of idle timeout
        if configuration.environment == "cloud" || configuration.url.scheme == "wss" {
            let watchdogMsg = "⏰ [LanWebSocketTransport] Starting ping/pong keepalive for cloud relay connection\n"
            print(watchdogMsg)
            try? watchdogMsg.appendToFile(path: "/tmp/hypo_debug.log")
            fflush(stdout)
            // Send ping every 20 seconds to keep connection alive
            watchdogTask = Task.detached { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000) // 20 seconds
                    if Task.isCancelled { return }
                    guard case .connected(let currentTask) = await self.state, currentTask === task else {
                        return
                    }
                    // Send ping to keep connection alive
                    currentTask.sendPing(pongReceiveHandler: { [weak self] error in
                        if let error {
                            let pingErrorMsg = "❌ [LanWebSocketTransport] Ping failed: \(error.localizedDescription)\n"
                            print(pingErrorMsg)
                            try? pingErrorMsg.appendToFile(path: "/tmp/hypo_debug.log")
                            // If ping fails, the connection is likely dead - disconnect and reconnect
                            Task { @MainActor [weak self] in
                                await self?.disconnect()
                                // Try to reconnect after a short delay
                                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                                try? await self?.connect()
                            }
                        } else {
                            let pingSuccessMsg = "🏓 [LanWebSocketTransport] Ping sent successfully\n"
                            print(pingSuccessMsg)
                            try? pingSuccessMsg.appendToFile(path: "/tmp/hypo_debug.log")
                            self?.touch()
                        }
                    })
                }
            }
            return
        }
        // For LAN connections, use idle timeout
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
        let reasonStr = reason != nil ? String(data: reason!, encoding: .utf8) ?? "binary" : "nil"
        let isCloud = configuration.environment == "cloud" || configuration.url.scheme == "wss"
        
        // Log close code meaning
        let closeCodeMsg: String
        switch closeCode {
        case .invalid:
            closeCodeMsg = "invalid"
        case .normalClosure:
            closeCodeMsg = "normalClosure"
        case .goingAway:
            closeCodeMsg = "goingAway"
        case .protocolError:
            closeCodeMsg = "protocolError"
        case .unsupportedData:
            closeCodeMsg = "unsupportedData"
        case .noStatusReceived:
            closeCodeMsg = "noStatusReceived"
        case .abnormalClosure:
            closeCodeMsg = "abnormalClosure"
        case .invalidFramePayloadData:
            closeCodeMsg = "invalidFramePayloadData"
        case .policyViolation:
            closeCodeMsg = "policyViolation"
        case .messageTooBig:
            closeCodeMsg = "messageTooBig"
        case .mandatoryExtensionMissing:
            closeCodeMsg = "mandatoryExtensionMissing"
        case .internalServerError:
            closeCodeMsg = "internalServerError"
        case .tlsHandshakeFailure:
            closeCodeMsg = "tlsHandshakeFailure"
        @unknown default:
            closeCodeMsg = "unknown(\(closeCode.rawValue))"
        }
        
        // Enhanced logging for cloud connections
        var closeMsg = "🔌 [LanWebSocketTransport] WebSocket closed\n"
        closeMsg += "   Close code: \(closeCode.rawValue) (\(closeCodeMsg))\n"
        closeMsg += "   Reason: \(reasonStr)\n"
        closeMsg += "   URL: \(configuration.url.absoluteString)\n"
        closeMsg += "   Environment: \(configuration.environment)\n"
        closeMsg += "   State: \(state)\n"
        
        // Capture HTTP response details if available (for cloud connections)
        if isCloud, let httpResponse = webSocketTask.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode
            let statusText = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            let responseHeaders = httpResponse.allHeaderFields
            closeMsg += "   HTTP Response: \(statusCode) \(statusText)\n"
            closeMsg += "   Response Headers: \(responseHeaders)\n"
            // Log all response header fields for debugging
            for (key, value) in responseHeaders {
                closeMsg += "   Header[\(key)]: \(value)\n"
            }
        }
        
        // Log connection state and timing
        let idleTime = Date().timeIntervalSince(lastActivity)
        closeMsg += "   Last activity: \(Int(idleTime))s ago\n"
        if let failureTime = lastReceiveFailure {
            let timeSinceFailure = Date().timeIntervalSince(failureTime)
            closeMsg += "   Last receive failure: \(Int(timeSinceFailure))s ago\n"
        }
        closeMsg += "   Receive retry count: \(receiveRetryCount)\n"
        
        print(closeMsg)
        try? closeMsg.appendToFile(path: "/tmp/hypo_debug.log")
        fflush(stdout)
        
        state = .idle
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let errorMsg = error != nil ? error!.localizedDescription : "none"
        let isCloud = configuration.environment == "cloud" || configuration.url.scheme == "wss"
        var completeMsg = "🔚 [LanWebSocketTransport] didCompleteWithError: \(errorMsg)\n"
        completeMsg += "   URL: \(configuration.url.absoluteString)\n"
        completeMsg += "   Environment: \(configuration.environment)\n"
        completeMsg += "   Request URL: \(task.originalRequest?.url?.absoluteString ?? "unknown")\n"
        
        // Capture HTTP response details if available
        if let httpResponse = task.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode
            let statusText = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            let responseHeaders = httpResponse.allHeaderFields
            completeMsg += "❌ [LanWebSocketTransport] HTTP Response: \(statusCode) \(statusText)\n"
            completeMsg += "   Response Headers: \(responseHeaders)\n"
            
            // Log all response header fields for debugging
            for (key, value) in responseHeaders {
                completeMsg += "   Header[\(key)]: \(value)\n"
            }
            
            // Try to capture response body from error if available
            if let error = error as NSError? {
                let errorBody = error.userInfo[NSLocalizedDescriptionKey] as? String ?? ""
                let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError
                let underlyingBody = underlyingError?.userInfo[NSLocalizedDescriptionKey] as? String ?? ""
                if !errorBody.isEmpty {
                    completeMsg += "   Error description: \(errorBody)\n"
                }
                if !underlyingBody.isEmpty {
                    completeMsg += "   Underlying error: \(underlyingBody)\n"
                }
                completeMsg += "   Error domain: \(error.domain), code: \(error.code)\n"
                
                // Log all userInfo keys for debugging
                if let userInfo = error.userInfo as? [String: Any], !userInfo.isEmpty {
                    completeMsg += "   Error UserInfo keys: \(userInfo.keys.joined(separator: ", "))\n"
                    for (key, value) in userInfo {
                        completeMsg += "   UserInfo[\(key)]: \(value)\n"
                    }
                }
            }
        } else if let error = error as NSError? {
            // Log additional error details for non-HTTP errors
            completeMsg += "❌ [LanWebSocketTransport] Error domain: \(error.domain), code: \(error.code)\n"
            if let userInfo = error.userInfo as? [String: Any], !userInfo.isEmpty {
                completeMsg += "   Error UserInfo keys: \(userInfo.keys.joined(separator: ", "))\n"
                for (key, value) in userInfo {
                    completeMsg += "   UserInfo[\(key)]: \(value)\n"
                }
            }
        }
        
        // Log connection state and timing
        let idleTime = Date().timeIntervalSince(lastActivity)
        completeMsg += "   Last activity: \(Int(idleTime))s ago\n"
        if let failureTime = lastReceiveFailure {
            let timeSinceFailure = Date().timeIntervalSince(failureTime)
            completeMsg += "   Last receive failure: \(Int(timeSinceFailure))s ago\n"
        }
        completeMsg += "   Receive retry count: \(receiveRetryCount)\n"
        
        // Log request headers for cloud connections
        if isCloud, let request = task.originalRequest {
            completeMsg += "   Request Headers: \(request.allHTTPHeaderFields ?? [:])\n"
        }
        
        print(completeMsg)
        try? completeMsg.appendToFile(path: "/tmp/hypo_debug.log")
        fflush(stdout)
        
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
            fflush(stdout)
            
            let resultTypeMsg = "🔍 [LanWebSocketTransport] Result type: \(String(describing: result))\n"
            print(resultTypeMsg)
            try? resultTypeMsg.appendToFile(path: "/tmp/hypo_debug.log")
            fflush(stdout)
            
            switch result {
            case .success(let message):
                // Log success immediately to catch messages before any processing
                let successImmediateMsg = "✅ [LanWebSocketTransport] Receive SUCCESS - message arrived!\n"
                print(successImmediateMsg)
                try? successImmediateMsg.appendToFile(path: "/tmp/hypo_debug.log")
                fflush(stdout)
                
                self.touch()
                let messageType: String
                switch message {
                case .string(let str):
                    messageType = "text(\(str.count) chars)"
                case .data(let data):
                    messageType = "data(\(data.count) bytes)"
                @unknown default:
                    messageType = "unknown"
                }
                let successMsg = "✅ [LanWebSocketTransport] Message received: \(messageType)\n"
                print(successMsg)
                try? successMsg.appendToFile(path: "/tmp/hypo_debug.log")
                fflush(stdout)
                if case .data(let data) = message {
                    let dataMsg = "📦 [LanWebSocketTransport] Binary data received: \(data.count) bytes\n"
                    print(dataMsg)
                    try? dataMsg.appendToFile(path: "/tmp/hypo_debug.log")
                    fflush(stdout)
                    self.handleIncoming(data: data)
                } else if case .string(let str) = message {
                    let textMsg = "📝 [LanWebSocketTransport] Text message received: \(str.prefix(100))\n"
                    print(textMsg)
                    try? textMsg.appendToFile(path: "/tmp/hypo_debug.log")
                    fflush(stdout)
                } else {
                    let nonDataMsg = "⚠️ [LanWebSocketTransport] Non-binary message received\n"
                    print(nonDataMsg)
                    try? nonDataMsg.appendToFile(path: "/tmp/hypo_debug.log")
                    fflush(stdout)
                }
                self.receiveNext(on: task)
            case .failure(let error):
                let errorMsg = "❌ [LanWebSocketTransport] Receive failed: \(error.localizedDescription)\n"
                print(errorMsg)
                try? errorMsg.appendToFile(path: "/tmp/hypo_debug.log")
                fflush(stdout)
                
                // For cloud connections, try to reconnect with exponential backoff
                // This handles the case where the server closes the connection
                if self.configuration.environment == "cloud" || self.configuration.url.scheme == "wss" {
                    // Calculate exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, 64s, 128s
                    let maxRetries: UInt = 8
                    let initialBackoff: TimeInterval = 1.0 // 1 second
                    let backoff = initialBackoff * pow(2.0, Double(self.receiveRetryCount))
                    let cappedBackoff = min(backoff, 128.0) // Cap at 128 seconds
                    
                    self.receiveRetryCount += 1
                    self.lastReceiveFailure = Date()
                    
                    if self.receiveRetryCount <= maxRetries {
                        let reconnectMsg = "🔄 [LanWebSocketTransport] Cloud connection reset (retry \(self.receiveRetryCount)/\(maxRetries)), reconnecting after \(Int(cappedBackoff))s backoff...\n"
                        print(reconnectMsg)
                        try? reconnectMsg.appendToFile(path: "/tmp/hypo_debug.log")
                        fflush(stdout)
                        
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            await self.disconnect()
                            // Reconnect after exponential backoff
                            try? await Task.sleep(nanoseconds: UInt64(cappedBackoff * 1_000_000_000))
                            do {
                                try await self.connect()
                                // Reset retry count on successful connection
                                self.receiveRetryCount = 0
                                self.lastReceiveFailure = nil
                            } catch {
                                let connectErrorMsg = "❌ [LanWebSocketTransport] Reconnect failed: \(error.localizedDescription)\n"
                                print(connectErrorMsg)
                                try? connectErrorMsg.appendToFile(path: "/tmp/hypo_debug.log")
                            }
                        }
                    } else {
                        let maxRetriesMsg = "❌ [LanWebSocketTransport] Max receive retries (\(maxRetries)) reached, giving up on cloud connection\n"
                        print(maxRetriesMsg)
                        try? maxRetriesMsg.appendToFile(path: "/tmp/hypo_debug.log")
                        fflush(stdout)
                        Task { await self.disconnect() }
                    }
                } else {
                    // For LAN connections, just disconnect
                    Task { await self.disconnect() }
                }
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
            // Determine transport origin based on configuration
            let transportOrigin: TransportOrigin = (configuration.environment == "cloud" || configuration.url.scheme == "wss") ? .cloud : .lan
            if let handler = onIncomingMessage {
                let forwardMsg = "📤 [LanWebSocketTransport] Forwarding to onIncomingMessage handler (origin: \(transportOrigin.rawValue))\n"
                print(forwardMsg)
                try? forwardMsg.appendToFile(path: "/tmp/hypo_debug.log")
                Task {
                    await handler(data, transportOrigin)
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
        // Reset receive retry count on successful connection
        receiveRetryCount = 0
        lastReceiveFailure = nil
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
