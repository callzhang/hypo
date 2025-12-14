import Foundation
import CryptoKit
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
        idleTimeout: TimeInterval = 3600, // 1 hour (for compatibility, but LAN uses ping/pong now)
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

// Protocols WebSocketTasking and URLSessionProviding are defined in WebSocketTransport.swift
// Import them from there to avoid duplicate definitions

public final class LanWebSocketTransport: NSObject, SyncTransport {
    private let logger = HypoLogger(category: "LanWebSocketTransport")
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
    private var reconnectingTask: Task<Void, Never>? // Guard to prevent concurrent reconnection attempts

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
        logger.info("🔌 [LanWebSocketTransport] connect() called, state: \(state), url: \(configuration.url)")
        
        switch state {
        case .connected:
            logger.info("✅ [LanWebSocketTransport] Already connected")
            return
        case .connecting:
            logger.info("⏳ [LanWebSocketTransport] Already connecting, waiting...")
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
            logger.warning("⚠️ [LanWebSocketTransport] WARNING: Headers dictionary is EMPTY!")
            fflush(stdout)
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
            logger.info("☁️ [LanWebSocketTransport] Cloud connection - preserving query parameters: \(originalURL.absoluteString)")
        } else {
            // For LAN connections, remove query parameters
            let cleanURLString = "\(scheme)://\(host)\(path)"
            guard let url = URL(string: cleanURLString) else {
                logger.error("❌ [LanWebSocketTransport] Failed to create clean URL from: \(cleanURLString)")
                throw NSError(domain: "LanWebSocketTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create clean URL"])
            }
            finalURL = url
            logger.info("📡 [LanWebSocketTransport] LAN connection - removed query parameters: \(cleanURLString)")
        }
        request.url = finalURL
        // Verify the URL was set correctly (log only if mismatch)
        if let requestURL = request.url?.absoluteString, requestURL != finalURL.absoluteString {
            logger.warning("⚠️ [LanWebSocketTransport] URL mismatch! Expected: \(finalURL.absoluteString), Got: \(requestURL)")
            fflush(stdout)
        }
        logger.info("📋 [LanWebSocketTransport] Request headers: \(request.allHTTPHeaderFields ?? [:])")
        fflush(stdout)

        let task = session.webSocketTask(with: request)
        state = .connecting
        
        logger.info("🚀 [LanWebSocketTransport] Resuming WebSocket task")

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
            logger.info("✅ [LanWebSocketTransport] Connection established successfully")
        } catch {
            logger.info("❌ [LanWebSocketTransport] Connection failed: \(error.localizedDescription)")
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
        
        logger.debug("📥 [LanWebSocketTransport] Queued message (queue size: \(messageQueue.count))")
        
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
                logger.info("❌ [LanWebSocketTransport] Message timeout after \(queuedMessage.retryCount) retries (10 min elapsed), dropping")
                _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                continue
            }
            
            // Calculate backoff: 1s, 2s, 4s, 8s, 16s, 32s, 64s, 128s
            let backoff = initialBackoff * pow(2.0, Double(queuedMessage.retryCount))
            
            // Wait before retry (skip wait on first attempt)
            if queuedMessage.retryCount > 0 {
                logger.info("⏳ [LanWebSocketTransport] Retry \(queuedMessage.retryCount)/\(maxRetries) after \(Int(backoff))s backoff")
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
            
            // Ensure connection before each attempt
            do {
                try await ensureConnected()
            } catch {
                logger.info("⚠️ [LanWebSocketTransport] Connection failed on retry \(queuedMessage.retryCount): \(error.localizedDescription)")
                queuedMessage.retryCount += 1
                if queuedMessage.retryCount <= maxRetries {
                    messageQueue.append(queuedMessage)
                } else {
                    logger.info("❌ [LanWebSocketTransport] Max retries reached, dropping message")
                    _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                }
                continue
            }
            
            guard case .connected(let task) = state else {
                logger.info("⚠️ [LanWebSocketTransport] Not connected after ensureConnected() on retry \(queuedMessage.retryCount)")
                queuedMessage.retryCount += 1
                if queuedMessage.retryCount <= maxRetries {
                    messageQueue.append(queuedMessage)
                } else {
                    logger.info("❌ [LanWebSocketTransport] Max retries reached, dropping message")
                    _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
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
                self.logger.info("✅ [LanWebSocketTransport] Message sent successfully after \(queuedMessage.retryCount) retries (queue size: \(messageQueue.count))")
                _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                
            } catch {
                let errorDescription = error.localizedDescription
                let nsError = error as NSError
                
                // Check if this is a cancellation error (Operation canceled)
                let isCancellationError = error is CancellationError ||
                                         errorDescription.contains("Operation canceled") ||
                                         errorDescription.contains("cancelled") ||
                                         (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
                
                // Check if this is a "Socket is not connected" error
                let isSocketNotConnected = errorDescription.contains("Socket is not connected") || 
                                          errorDescription.contains("not connected") ||
                                          (nsError.domain == "NSPOSIXErrorDomain" && nsError.code == 57)
                
                // Treat cancellation and socket closure as transient errors - requeue without incrementing retry count
                // This is especially important for large payloads (images/files) that may take time to send
                if isCancellationError || isSocketNotConnected {
                    let errorType = isCancellationError ? "cancellation" : "socket closure"
                    self.logger.info("⚠️ [LanWebSocketTransport] \(errorType.capitalized) during send (likely during large payload transmission), requeuing message")
                    // Don't increment retry count for transient errors - this is expected for large payloads
                    messageQueue.append(queuedMessage)
                    
                    // Only trigger reconnection if socket is actually not connected
                    // For cancellation errors, the connection might still be valid - just retry the send
                    if isSocketNotConnected {
                        // Socket is closed - need to reconnect
                        if case .idle = state {
                            // Only trigger reconnection if we're idle (not already reconnecting)
                            Task { [weak self] in
                                do {
                                    try await self?.connect()
                                } catch {
                                    self?.logger.info("⚠️ [LanWebSocketTransport] Reconnection failed: \(error.localizedDescription)")
                                }
                            }
                        }
                    } else if isCancellationError {
                        // Cancellation error but connection might still be valid
                        // Check if we're still connected - if not, trigger reconnection
                        if case .connected = state {
                            // Still connected - just retry without reconnecting
                            self.logger.debug("🔄 [LanWebSocketTransport] Connection still valid, will retry send")
                        } else if case .idle = state {
                            // Not connected - trigger reconnection
                            Task { [weak self] in
                                do {
                                    try await self?.connect()
                                } catch {
                                    self?.logger.info("⚠️ [LanWebSocketTransport] Reconnection failed: \(error.localizedDescription)")
                                }
                            }
                        }
                    }
                } else {
                    self.logger.info("❌ [LanWebSocketTransport] Send failed on retry \(queuedMessage.retryCount)/\(maxRetries): \(errorDescription)")
                    queuedMessage.retryCount += 1
                    if queuedMessage.retryCount <= maxRetries {
                        messageQueue.append(queuedMessage)
                    } else {
                        logger.info("❌ [LanWebSocketTransport] Max retries reached, dropping message")
                        _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                    }
                }
            }
        }
        
        // Queue is empty, stop processing
        queueProcessingTask = nil
        logger.info("✅ [LanWebSocketTransport] Message queue empty, stopping processor")
    }

    public func disconnect() async {
        watchdogTask?.cancel()
        watchdogTask = nil
        queueProcessingTask?.cancel()
        queueProcessingTask = nil
        reconnectingTask?.cancel()
        reconnectingTask = nil
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
            logger.info("🧹 [LanWebSocketTransport] Clearing \(queueSize) queued messages on disconnect")
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
        // Wait for any in-progress reconnection to complete
        if let reconnecting = reconnectingTask {
            logger.info("⏳ [LanWebSocketTransport] Waiting for in-progress reconnection...")
            await reconnecting.value
        }
        
        switch state {
        case .connected:
            return
        case .idle, .connecting:
            // If not reconnecting, try to connect
            try await connect()
        }
    }
    
    private func reconnectWithBackoff() {
        // Prevent concurrent reconnection attempts
        guard reconnectingTask == nil || reconnectingTask?.isCancelled == true else {
            logger.info("⏭️ [LanWebSocketTransport] Reconnection already in progress, skipping")
            return
        }
        
        let initialBackoff: TimeInterval = 1.0
        let maxBackoff: TimeInterval = 128.0
        let backoff: TimeInterval
        if receiveRetryCount < 8 {
            backoff = initialBackoff * pow(2.0, Double(receiveRetryCount))
        } else {
            backoff = maxBackoff
        }
        
        receiveRetryCount += 1
        lastReceiveFailure = Date()
        
        let isCloud = configuration.environment == "cloud" || configuration.url.scheme == "wss"
        logger.info("🔄 [LanWebSocketTransport] Scheduling reconnection (cloud=\(isCloud), retry \(receiveRetryCount)) after \(Int(backoff))s backoff...")
        
        reconnectingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            
            // Wait for backoff
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            
            // Disconnect first
            await self.disconnect()
            
            // Try to reconnect
            do {
                try await self.connect()
                // Reset retry count on successful connection
                self.receiveRetryCount = 0
                self.lastReceiveFailure = nil
                self.logger.info("✅ [LanWebSocketTransport] Reconnection successful")
            } catch {
                self.logger.info("❌ [LanWebSocketTransport] Reconnection failed: \(error.localizedDescription)")
                // Will retry again on next failure
            }
            
            // Clear reconnecting task
            self.reconnectingTask = nil
        }
    }

    private func startWatchdog(for task: WebSocketTasking) {
        watchdogTask?.cancel()
        // For cloud relay connections, use ping/pong keepalive instead of idle timeout
        if configuration.environment == "cloud" || configuration.url.scheme == "wss" {
            logger.info("⏰ [LanWebSocketTransport] Starting ping/pong keepalive for cloud relay connection")
            fflush(stdout)
            // Send ping every 20 seconds to keep connection alive
            watchdogTask = Task.detached { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000) // 20 seconds
                    if Task.isCancelled { return }
                    // Access state directly since LanWebSocketTransport is a class, not an actor
                    guard case .connected(let currentTask) = self.state, currentTask === task else {
                        return
                    }
                    // Send ping to keep connection alive
                    currentTask.sendPing(pongReceiveHandler: { [weak self] error in
                        guard let self = self else { return }
                        if let error {
                            self.logger.info("❌ [LanWebSocketTransport] Ping failed: \(error.localizedDescription)")
                            // Use centralized reconnection logic
                            Task { @MainActor [weak self] in
                                guard let self = self else { return }
                                self.reconnectWithBackoff()
                            }
                        } else {
                            self.logger.info("🏓 [LanWebSocketTransport] Ping sent successfully")
                            self.touch()
                            // Reset retry count on successful ping
                            Task { @MainActor [weak self] in
                                self?.receiveRetryCount = 0
                            }
                        }
                    })
                }
            }
            return
        }
        // For LAN connections, use ping/pong keepalive (event-driven, can reconnect when disconnected)
        // Send ping every 30 minutes to keep connection alive
        logger.info("⏰ [LanWebSocketTransport] Starting ping/pong keepalive for LAN connection")
        logger.info("   Sending ping every 30 minutes (event-driven, will reconnect on disconnect)")
        watchdogTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_800_000_000_000) // 30 minutes (30 * 60 * 1_000_000_000)
                if Task.isCancelled { return }
                // Access state directly since LanWebSocketTransport is a class, not an actor
                guard case .connected(let currentTask) = self.state, currentTask === task else {
                    return
                }
                // Send ping to keep connection alive
                currentTask.sendPing(pongReceiveHandler: { [weak self] error in
                    guard let self = self else { return }
                    if let error {
                        self.logger.info("❌ [LanWebSocketTransport] Ping failed: \(error.localizedDescription)")
                        // Use centralized reconnection logic
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            self.reconnectWithBackoff()
                        }
                    } else {
                        self.logger.info("🏓 [LanWebSocketTransport] Ping sent successfully")
                        self.touch()
                        // Reset retry count on successful ping
                        Task { @MainActor [weak self] in
                            self?.receiveRetryCount = 0
                        }
                    }
                })
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
        logger.info("🎉 [LanWebSocketTransport] didOpenWithProtocol called! protocol: \(protocolName ?? "nil")")
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
        logger.info("🔌 [LanWebSocketTransport] close() called: state=\(state), receive retry count=\(receiveRetryCount)")
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
                let userInfo = error.userInfo
                if !userInfo.isEmpty {
                    completeMsg += "   Error UserInfo keys: \(userInfo.keys.joined(separator: ", "))\n"
                    for (key, value) in userInfo {
                        completeMsg += "   UserInfo[\(key)]: \(value)\n"
                    }
                }
            }
        } else if let error = error as NSError? {
            // Log additional error details for non-HTTP errors
            completeMsg += "❌ [LanWebSocketTransport] Error domain: \(error.domain), code: \(error.code)\n"
            let userInfo = error.userInfo
            if !userInfo.isEmpty {
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
        
        logger.info("✅ [LanWebSocketTransport] Connection complete")
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
        logger.info("📡 [LanWebSocketTransport] receiveNext() called, setting up receive callback")
        task.receive { [weak self] result in
            guard let self else {
                NSLog("⚠️ [LanWebSocketTransport] Self is nil in receive callback")
                return
            }
            self.logger.info("📡 [LanWebSocketTransport] receive callback triggered")
            fflush(stdout)
            
            self.logger.info("🔍 [LanWebSocketTransport] Result type: \(String(describing: result))")
            fflush(stdout)
            
            switch result {
            case .success(let message):
                // Log success immediately to catch messages before any processing
                self.logger.info("✅ [LanWebSocketTransport] Receive SUCCESS - message arrived!")
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
                logger.info("✅ [LanWebSocketTransport] Message received: \(messageType)")
                fflush(stdout)
                if case .data(let data) = message {
                    logger.info("📦 [LanWebSocketTransport] Binary data received: \(data.count) bytes")
                    fflush(stdout)
                    self.handleIncoming(data: data)
                } else if case .string(let str) = message {
                    logger.info("📝 [LanWebSocketTransport] Text message received: \(str.prefix(100))")
                    fflush(stdout)
                } else {
                    logger.info("⚠️ [LanWebSocketTransport] Non-binary message received")
                    fflush(stdout)
                }
                self.receiveNext(on: task)
            case .failure(let error):
                logger.info("❌ [LanWebSocketTransport] Receive failed: \(error.localizedDescription)")
                fflush(stdout)
                
                // Use centralized reconnection logic
                reconnectWithBackoff()
            }
        }
    }

    private func handleIncoming(data: Data) {
        do {
            // Check for control messages before decoding as SyncEnvelope
            if data.count >= 4 {
                let lengthBytes = data.prefix(4)
                let lengthValue = lengthBytes.withUnsafeBytes { buffer -> UInt32 in
                    buffer.load(as: UInt32.self)
                }
                let length = Int(UInt32(bigEndian: lengthValue))
                if data.count >= 4 + length {
                    let jsonData = data.subdata(in: 4..<(4 + length))
                    if let jsonString = String(data: jsonData, encoding: .utf8) {
                        // Check if this is a control message (from cloud relay) before trying to decode as SyncEnvelope
                        // Control messages have structure: {"msg_type":"control","payload":{...}}
                        // They don't have an "id" field, so decoding as SyncEnvelope will fail
                        if jsonString.contains("\"msg_type\"") && jsonString.contains("\"control\"") {
                            logger.debug("📋 [LanWebSocketTransport] Received control message from cloud relay")
                            // Try to parse as control message
                            if let jsonDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let msgType = jsonDict["msg_type"] as? String,
                               msgType == "control",
                               let payload = jsonDict["payload"] as? [String: Any],
                               let action = payload["action"] as? String {
                                logger.debug("📋 [LanWebSocketTransport] Control message action: \(action)")
                                if action == "routing_failure" {
                                    if let reason = payload["reason"] as? String {
                                        // Log as debug instead of warning - these are expected when devices are offline
                                        logger.debug("ℹ️ [LanWebSocketTransport] Routing failure: \(reason)")
                                    }
                                    if let targetDeviceId = payload["target_device_id"] as? String {
                                        // Log as debug instead of warning - these are expected when devices are offline
                                        logger.debug("ℹ️ [LanWebSocketTransport] Target device not connected: \(targetDeviceId)")
                                    }
                                }
                            }
                            // Control messages are informational - don't try to decode as SyncEnvelope
                            return
                        }
                    }
                }
            }
            
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
                Task {
                    await handler(data, transportOrigin)
                }
            } else {
                logger.warning("⚠️ [LanWebSocketTransport] No onIncomingMessage handler set")
            }
        } catch let decodingError as DecodingError {
            logger.error("❌ [LanWebSocketTransport] Failed to decode incoming data: \(decodingError)")
            // Log detailed decoding error information
            switch decodingError {
            case .keyNotFound(let key, let context):
                logger.error("   Missing key: \(key.stringValue) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            case .valueNotFound(let type, let context):
                logger.error("   Missing value of type \(String(describing: type)) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            case .typeMismatch(let type, let context):
                logger.error("   Type mismatch: expected \(String(describing: type)) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            case .dataCorrupted(let context):
                logger.error("   Data corrupted: \(context.debugDescription) at path: \(context.codingPath.map { $0.stringValue }.joined(separator: "."))")
            @unknown default:
                logger.error("   Unknown decoding error: \(decodingError)")
            }
            // Log raw data for debugging
            if data.count >= 4 {
                let lengthBytes = data.prefix(4)
                let lengthValue = lengthBytes.withUnsafeBytes { buffer -> UInt32 in
                    buffer.load(as: UInt32.self)
                }
                let length = Int(UInt32(bigEndian: lengthValue))
                logger.error("   Frame header: length=\(length) bytes, total data=\(data.count) bytes")
                if data.count >= 4 + length {
                    let jsonData = data.subdata(in: 4..<(4 + length))
                    if let jsonString = String(data: jsonData, encoding: .utf8) {
                        logger.error("   JSON payload: \(jsonString)")
                    } else {
                        logger.error("   JSON payload (hex): \(jsonData.map { String(format: "%02x", $0) }.joined())")
                    }
                }
            }
            Task {
                await pendingRoundTrips.pruneExpired(referenceDate: Date())
            }
        } catch {
            logger.error("❌ [LanWebSocketTransport] Failed to decode incoming data: \(error)")
            Task {
                await pendingRoundTrips.pruneExpired(referenceDate: Date())
            }
        }
    }

    func handleOpen(task: WebSocketTasking) {
        logger.info("✅ [LanWebSocketTransport] handleOpen() called, connection established")
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
        logger.info("📡 [LanWebSocketTransport] handleOpen: Starting receiveNext()")
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

        // Use SecTrustCopyCertificateChain for macOS 12.0+
        guard let certificateChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let serverCertificate = certificateChain.first else {
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
