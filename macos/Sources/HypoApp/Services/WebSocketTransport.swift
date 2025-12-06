import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/**
 * Configuration for WebSocket transport connections (both LAN and cloud).
 * Behavior is determined by environment field ("lan" or "cloud").
 */
public struct WebSocketConfiguration: Sendable, Equatable {
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

/**
 * Unified WebSocket transport for both LAN and cloud connections.
 * Behavior is determined by configuration.environment ("lan" or "cloud").
 * For LAN: uses peer discovery to find connection URLs dynamically.
 * For cloud: uses configuration.url for relay server connection.
 */
public final class WebSocketTransport: NSObject, SyncTransport {
    private let logger = HypoLogger(category: "WebSocketTransport")
    private enum ConnectionState {
        case idle
        case connecting
        case connected(WebSocketTasking)
    }

    private let configuration: WebSocketConfiguration
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
    // Track messages that are "in flight" - send callback fired but transmission may not be complete
    private var inFlightMessages: [UUID: QueuedMessage] = [:] // message ID -> queued message

    public init(
        configuration: WebSocketConfiguration,
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
        // If a reconnection is in progress, wait for it to complete
        if let reconnecting = reconnectingTask, !reconnecting.isCancelled {
            logger.debug("⏳ [WebSocketTransport] Reconnection in progress, waiting...")
            do {
                await reconnecting.value
                // After reconnection completes, check if we're now connected
                if case .connected = state {
                    return
                }
            } catch {
                logger.debug("⚠️ [WebSocketTransport] Reconnection task failed, proceeding with direct connect")
            }
        }
        
        switch state {
        case .connected:
            return
        case .connecting:
            logger.debug("⏳ [WebSocketTransport] Already connecting, waiting...")
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
            logger.warning("⚠️ [WebSocketTransport] WARNING: Headers dictionary is EMPTY!")
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
        } else {
            // For LAN connections, remove query parameters
            let cleanURLString = "\(scheme)://\(host)\(path)"
            guard let url = URL(string: cleanURLString) else {
                logger.error("❌ [WebSocketTransport] Failed to create clean URL from: \(cleanURLString)")
                throw NSError(domain: "WebSocketTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create clean URL"])
            }
            finalURL = url
        }
        request.url = finalURL
        let task = session.webSocketTask(with: request)
        state = .connecting

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
            logger.debug("✅ [WebSocketTransport] Connection established")
        } catch {
            logger.warning("❌ [WebSocketTransport] Connection failed: \(error.localizedDescription)")
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
        
        logger.debug("📥 [WebSocketTransport] Queued message: type=\(envelope.payload.contentType), size=\(data.count) bytes, id=\(envelope.id.uuidString.prefix(8)), queue=\(messageQueue.count)")
        
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
                logger.info("❌ [WebSocketTransport] Message timeout after \(queuedMessage.retryCount) retries (10 min elapsed), dropping")
                _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                continue
            }
            
            // Calculate backoff: 1s, 2s, 4s, 8s, 16s, 32s, 64s, 128s
            let backoff = initialBackoff * pow(2.0, Double(queuedMessage.retryCount))
            
            // Wait before retry (skip wait on first attempt)
            if queuedMessage.retryCount > 0 {
                logger.info("⏳ [WebSocketTransport] Retry \(queuedMessage.retryCount)/\(maxRetries) after \(Int(backoff))s backoff")
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
            
            // Ensure connection before each attempt
            do {
                try await ensureConnected()
            } catch {
                logger.info("⚠️ [WebSocketTransport] Connection failed on retry \(queuedMessage.retryCount): \(error.localizedDescription)")
                queuedMessage.retryCount += 1
                if queuedMessage.retryCount <= maxRetries {
                    messageQueue.append(queuedMessage)
                } else {
                    logger.info("❌ [WebSocketTransport] Max retries reached, dropping message")
                    _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                }
                continue
            }
            
            guard case .connected(let task) = state else {
                logger.debug("⚠️ [WebSocketTransport] Not connected after ensureConnected() on retry \(queuedMessage.retryCount)")
                queuedMessage.retryCount += 1
                if queuedMessage.retryCount <= maxRetries {
                    messageQueue.append(queuedMessage)
                } else {
                    logger.info("❌ [WebSocketTransport] Max retries reached, dropping message")
                    _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                }
                continue
            }
            
            // Attempt to send
            do {
                // Double-check connection state right before sending (socket might have closed)
                guard case .connected(let currentTask) = state, currentTask === task else {
                    logger.info("⚠️ [WebSocketTransport] Connection lost between check and send, requeuing message")
                    queuedMessage.retryCount += 1
                    if queuedMessage.retryCount <= maxRetries {
                        messageQueue.append(queuedMessage)
                    } else {
                        logger.info("❌ [WebSocketTransport] Max retries reached, dropping message")
                        _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                    }
                    continue
                }
                
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    currentTask.send(.data(queuedMessage.data)) { [weak self] error in
                        guard let self else {
                            continuation.resume(throwing: NSError(domain: "WebSocketTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Self deallocated"]))
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
                
                // Send callback fired - message is now in-flight, waiting for server feedback
                // NEVER mark as successful immediately - wait for server confirmation (success or error)
                let messageId = queuedMessage.envelope.id
                let frameSize = queuedMessage.data.count
                let contentType = queuedMessage.envelope.payload.contentType
                
                // Track all messages as in-flight until we get server feedback
                inFlightMessages[messageId] = queuedMessage
                self.logger.debug("📤 [WebSocketTransport] Message in-flight: type=\(contentType), size=\(frameSize) bytes, id=\(messageId.uuidString.prefix(8))")
                
                // Set up timeout to handle cases where server doesn't respond
                // If no error response is received within timeout, assume success (server may not send explicit ack)
                let timeoutDuration: TimeInterval = frameSize > 100_000 ? 10.0 : 5.0 // Longer timeout for large messages
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutDuration * 1_000_000_000))
                    guard let strongSelf = self else { return }
                    await MainActor.run {
                        // If still in-flight after timeout and no error was received, assume success
                        if strongSelf.inFlightMessages.removeValue(forKey: messageId) != nil {
                            strongSelf.logger.debug("✅ [WebSocketTransport] Message confirmed (timeout): id=\(messageId.uuidString.prefix(8))")
                            Task {
                                _ = await strongSelf.pendingRoundTrips.remove(id: messageId)
                            }
                        }
                    }
                }
                
            } catch {
                let errorDescription = error.localizedDescription
                let nsError = error as NSError
                
                // Check if this is a "Socket is not connected" error
                let isSocketNotConnected = errorDescription.contains("Socket is not connected") || 
                                          errorDescription.contains("not connected") ||
                                          (nsError.domain == "NSPOSIXErrorDomain" && nsError.code == 57)
                
                if isSocketNotConnected {
                    self.logger.info("⚠️ [WebSocketTransport] Socket closed during send (likely during large payload transmission), requeuing message")
                    // Don't increment retry count for socket closure during send - this is expected for large payloads
                    // The reconnection logic will handle reconnecting, and we'll retry the send once connected
                    messageQueue.append(queuedMessage)
                    // Trigger reconnection if not already in progress
                    reconnectWithBackoff()
                } else {
                    self.logger.info("❌ [WebSocketTransport] Send failed on retry \(queuedMessage.retryCount)/\(maxRetries): \(errorDescription)")
                    queuedMessage.retryCount += 1
                    if queuedMessage.retryCount <= maxRetries {
                        messageQueue.append(queuedMessage)
                    } else {
                        logger.info("❌ [WebSocketTransport] Max retries reached, dropping message")
                        _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                    }
                }
            }
        }
        
        // Queue is empty, stop processing
        queueProcessingTask = nil
        logger.debug("✅ [WebSocketTransport] Message queue empty, stopping processor")
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
            logger.debug("🧹 [WebSocketTransport] Clearing \(queueSize) queued messages on disconnect")
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
        if let reconnecting = reconnectingTask, !reconnecting.isCancelled {
            logger.debug("⏳ [WebSocketTransport] Waiting for in-progress reconnection...")
            do {
                await reconnecting.value
            } catch {
                logger.debug("⚠️ [WebSocketTransport] Reconnection task completed with error")
            }
        }
        
        switch state {
        case .connected:
            return
        case .idle, .connecting:
            // If not reconnecting, try to connect
            // But first check if a reconnection is scheduled (even if not started yet)
            if let reconnecting = reconnectingTask, !reconnecting.isCancelled {
                logger.debug("⏳ [WebSocketTransport] Reconnection scheduled, waiting...")
                do {
                    await reconnecting.value
                } catch {
                    logger.debug("⚠️ [WebSocketTransport] Reconnection task failed")
                    // If reconnection failed, try direct connect
                    try await connect()
                }
            } else {
                try await connect()
            }
        }
    }
    
    private func reconnectWithBackoff() {
        // Prevent concurrent reconnection attempts
        if let existing = reconnectingTask, !existing.isCancelled {
            logger.debug("⏭️ [WebSocketTransport] Reconnection already in progress, skipping")
            return
        }
        
        // Cancel any existing reconnection task before creating a new one
        reconnectingTask?.cancel()
        
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
        
        logger.debug("🔄 [WebSocketTransport] Scheduling reconnection (retry \(receiveRetryCount)) after \(Int(backoff))s")
        
        reconnectingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            
            // Check if task was cancelled before starting
            guard !Task.isCancelled else {
                self.reconnectingTask = nil
                return
            }
            
            // Wait for backoff (check for cancellation during sleep)
            do {
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            } catch {
                // Task was cancelled during sleep
                self.reconnectingTask = nil
                return
            }
            
            // Check again if cancelled
            guard !Task.isCancelled else {
                self.reconnectingTask = nil
                return
            }
            
            // Disconnect first
            await self.disconnect()
            
            // Check again if cancelled
            guard !Task.isCancelled else {
                self.reconnectingTask = nil
                return
            }
            
            // Try to reconnect
            do {
                try await self.connect()
                // Reset retry count on successful connection
                self.receiveRetryCount = 0
                self.lastReceiveFailure = nil
                self.logger.debug("✅ [WebSocketTransport] Reconnection successful")
            } catch {
                self.logger.warning("❌ [WebSocketTransport] Reconnection failed: \(error.localizedDescription)")
                // Will retry again on next failure
            }
            
            // Clear reconnecting task
            self.reconnectingTask = nil
        }
    }

    private func startWatchdog(for task: WebSocketTasking) {
        watchdogTask?.cancel()
        // For cloud relay connections, use ping/pong keepalive instead of idle timeout
        // Fly.io idle_timeout is configured to 900 seconds (15 minutes, max allowed) in fly.toml
        // We send pings every 14 minutes (840 seconds) to:
        // 1. Keep connection alive (well before 15-minute timeout)
        // 2. Detect dead connections quickly (within 14 minutes)
        if configuration.environment == "cloud" || configuration.url.scheme == "wss" {
            logger.debug("⏰ [WebSocketTransport] Starting ping/pong keepalive")
            logger.debug("   Sending ping every 14 minutes (840s) - Fly.io timeout: 900s (max)")
            watchdogTask = Task.detached { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 840_000_000_000) // 14 minutes (840 seconds)
                    if Task.isCancelled { return }
                    // Access state directly since WebSocketTransport is a class, not an actor
                    guard case .connected(let currentTask) = self.state, currentTask === task else {
                        return
                    }
                    // Send ping to keep connection alive
                    currentTask.sendPing(pongReceiveHandler: { [weak self] error in
                        guard let self = self else { return }
                        if let error {
                            self.logger.warning("❌ [WebSocketTransport] Ping failed: \(error.localizedDescription)")
                            // If ping fails, the connection is likely dead - disconnect and reconnect
                            // Use centralized reconnection logic
                            Task { @MainActor [weak self] in
                                guard let self = self else { return }
                                self.reconnectWithBackoff()
                            }
                        } else {
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

extension WebSocketTransport: @unchecked Sendable {}

extension WebSocketTransport: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocolName: String?) {
        logger.debug("✅ [WebSocketTransport] Connection opened")
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
        var closeMsg = "🔌 [WebSocketTransport] WebSocket closed\n"
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
        logger.info("🔌 [WebSocketTransport] close() called: state=\(state), receive retry count=\(receiveRetryCount)")
        fflush(stdout)
        
        // Check for in-flight messages - if socket closes during large payload transmission, requeue them
        if !inFlightMessages.isEmpty {
            let inFlightCount = inFlightMessages.count
            logger.info("⚠️ [WebSocketTransport] Socket closed with \(inFlightCount) in-flight message(s) - requeuing for retry")
            for (messageId, queuedMessage) in inFlightMessages {
                logger.info("🔄 [WebSocketTransport] Requeuing in-flight message: id=\(messageId.uuidString.prefix(8)), type=\(queuedMessage.envelope.payload.contentType), frame=\(queuedMessage.data.count) bytes")
                messageQueue.append(queuedMessage)
            }
            inFlightMessages.removeAll()
            
            // Trigger queue processing after reconnection
            Task { [weak self] in
                guard let self else { return }
                // Wait a bit for reconnection, then trigger queue processing
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                await self.triggerQueueProcessingIfNeeded()
            }
        }
        
        state = .idle
        watchdogTask?.cancel()
        watchdogTask = nil
    }
    
    private func triggerQueueProcessingIfNeeded() async {
        guard !messageQueue.isEmpty else { return }
        if queueProcessingTask == nil || queueProcessingTask?.isCancelled == true {
            queueProcessingTask = Task { [weak self] in
                await self?.processMessageQueue()
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Capture state at entry so we can distinguish active vs stale tasks
        let previousState = state
        
        // Only treat completion as significant if it belongs to the currently active task
        // Stale tasks can complete after we've reconnected and should be ignored to avoid
        // tearing down a healthy connection.
        var isCurrentTask = true
        if case .connected(let currentTask) = previousState,
           let currentWsTask = currentTask as? URLSessionWebSocketTask,
           let completedWsTask = task as? URLSessionWebSocketTask {
            if currentWsTask !== completedWsTask {
                isCurrentTask = false
            }
        } else if case .idle = previousState {
            // When we're idle, any completion is necessarily for a task we no longer treat as active
            isCurrentTask = false
        }
        
        if !isCurrentTask {
            logger.info("⚠️ [WebSocketTransport] didCompleteWithError for stale task, ignoring (previous state: \(previousState))")
            fflush(stdout)
            return
        }
        
        let errorMsg = error != nil ? error!.localizedDescription : "none"
        let isCloud = configuration.environment == "cloud" || configuration.url.scheme == "wss"
        var completeMsg = "🔚 [WebSocketTransport] didCompleteWithError: \(errorMsg)\n"
        completeMsg += "   URL: \(configuration.url.absoluteString)\n"
        completeMsg += "   Environment: \(configuration.environment)\n"
        completeMsg += "   Request URL: \(task.originalRequest?.url?.absoluteString ?? "unknown")\n"
        
        // Capture HTTP response details if available
        if let httpResponse = task.response as? HTTPURLResponse {
            let statusCode = httpResponse.statusCode
            let statusText = HTTPURLResponse.localizedString(forStatusCode: statusCode)
            let responseHeaders = httpResponse.allHeaderFields
            completeMsg += "❌ [WebSocketTransport] HTTP Response: \(statusCode) \(statusText)\n"
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
            completeMsg += "❌ [WebSocketTransport] Error domain: \(error.domain), code: \(error.code)\n"
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
        
        logger.info("✅ [WebSocketTransport] Connection complete")
        fflush(stdout)
        
        if let continuation = handshakeContinuation {
            handshakeContinuation = nil
            continuation.resume(throwing: error ?? NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown))
        }
        handshakeStartedAt = nil
        state = .idle
        watchdogTask?.cancel()
        watchdogTask = nil
        
        // Unified reconnection logic: trigger reconnection for both cloud and LAN when connection
        // completes with error, but only when the completed task was the active connection.
        // This avoids reconnect loops caused by stale tasks completing after we've already
        // established a new WebSocket.
        if error != nil {
            switch previousState {
            case .connected, .connecting:
                // Connection was closed with an error - trigger reconnection
                reconnectWithBackoff()
            case .idle:
                logger.debug("ℹ️ [WebSocketTransport] didCompleteWithError received while idle, skipping reconnection")
            }
        }
    }

    private func receiveNext(on task: WebSocketTasking) {
        task.receive { [weak self] result in
            guard let self else {
                NSLog("⚠️ [WebSocketTransport] Self is nil in receive callback")
                return
            }
            
            // Ignore callbacks from stale tasks that have been closed after a reconnect.
            // Without this guard, a completion from an old task can trigger a new reconnect,
            // tearing down a healthy replacement connection and causing repeated failures
            // like "Socket is not connected".
            guard case .connected(let currentTask) = self.state, currentTask === task else {
                self.logger.debug("⚠️ [WebSocketTransport] Receive callback from stale task, ignoring")
                return
            }
            
            switch result {
            case .success(let message):
                self.touch()
                if case .data(let data) = message {
                    self.handleIncoming(data: data)
                }
                self.receiveNext(on: task)
            case .failure(let error):
                let errorDescription = error.localizedDescription
                let nsError = error as NSError
                
                // Check if this is a "Socket is not connected" error from a stale/closed socket
                let isSocketNotConnected = errorDescription.contains("Socket is not connected") || 
                                          errorDescription.contains("not connected") ||
                                          (nsError.domain == "NSPOSIXErrorDomain" && nsError.code == 57)
                
                // Double-check state - if we're no longer connected, this is a stale callback
                let isStaleCallback: Bool
                if case .connected(let currentTask) = self.state {
                    isStaleCallback = currentTask !== task
                } else {
                    isStaleCallback = true
                }
                
                if isStaleCallback {
                    logger.debug("⚠️ [WebSocketTransport] Receive callback from stale socket, ignoring")
                    return
                }
                
                // Socket is not connected is an expected condition when socket is closed
                // Log at debug level instead of warning
                if isSocketNotConnected {
                    logger.debug("ℹ️ [WebSocketTransport] Receive failed: Socket is not connected (expected when socket is closed)")
                } else {
                    logger.warning("❌ [WebSocketTransport] Receive failed: \(errorDescription)")
                    // Only trigger reconnection for real failures, not expected disconnections
                    reconnectWithBackoff()
                }
            }
        }
    }

    private func handleIncoming(data: Data) {
        do {
            // Check for error/control messages before decoding as SyncEnvelope
            if data.count >= 4 {
                let lengthBytes = data.prefix(4)
                let lengthValue = lengthBytes.withUnsafeBytes { buffer -> UInt32 in
                    buffer.load(as: UInt32.self)
                }
                let length = Int(UInt32(bigEndian: lengthValue))
                if data.count >= 4 + length {
                    let jsonData = data.subdata(in: 4..<(4 + length))
                    if let jsonString = String(data: jsonData, encoding: .utf8) {
                        // Check for error messages with structure: {"type":"error","payload":{...}}
                        if jsonString.contains("\"type\"") && jsonString.contains("\"error\"") {
                            logger.debug("⚠️ [WebSocketTransport] Received error message from relay")
                            // Try to parse as error message
                            if let jsonDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let type = jsonDict["type"] as? String,
                               type == "error",
                               let payload = jsonDict["payload"] as? [String: Any] {
                                let code = payload["code"] as? String ?? "unknown"
                                let message = payload["message"] as? String ?? "Unknown error"
                                let targetDeviceId = payload["target_device_id"] as? String
                                let connectedDevices = payload["connected_devices"] as? [String]
                                
                                // Check if this error is for an in-flight message
                                if let originalMessageIdStr = payload["original_message_id"] as? String,
                                   let originalMessageId = UUID(uuidString: originalMessageIdStr) {
                                    // Mark in-flight message as failed and requeue for retry
                                    if var failedMessage = self.inFlightMessages.removeValue(forKey: originalMessageId) {
                                        // Check if this is a permanent error that shouldn't be retried
                                        let isPermanentError = code == "device_not_connected" || code == "incorrect_device_id"
                                        
                                        if isPermanentError {
                                            // Permanent error - don't retry, just log and drop
                                            // device_not_connected and incorrect_device_id are expected conditions - log as debug
                                            if code == "device_not_connected" || code == "incorrect_device_id" {
                                                self.logger.debug("ℹ️ [WebSocketTransport] Permanent error for message \(originalMessageIdStr.prefix(8)): \(code) - dropping")
                                            } else {
                                                self.logger.warning("❌ [WebSocketTransport] Permanent error for message \(originalMessageIdStr.prefix(8)): \(code) - dropping message")
                                            }
                                            Task {
                                                _ = await self.pendingRoundTrips.remove(id: originalMessageId)
                                            }
                                        } else {
                                            // Transient error - increment retry count and requeue with backoff
                                            failedMessage.retryCount += 1
                                            let maxRetries: UInt = 8
                                            
                                            if failedMessage.retryCount <= maxRetries {
                                                self.logger.warning("❌ [WebSocketTransport] Server error for message \(originalMessageIdStr.prefix(8)): \(code), requeuing (retry \(failedMessage.retryCount)/\(maxRetries))")
                                                self.messageQueue.append(failedMessage)
                                                // Don't immediately trigger queue processing - let normal retry logic handle backoff
                                                // Only trigger if queue processor is not running
                                                if self.queueProcessingTask == nil || self.queueProcessingTask?.isCancelled == true {
                                                    self.queueProcessingTask = Task { [weak self] in
                                                        await self?.processMessageQueue()
                                                    }
                                                }
                                            } else {
                                                self.logger.error("❌ [WebSocketTransport] Max retries reached for message \(originalMessageIdStr.prefix(8)), dropping")
                                                Task {
                                                    _ = await self.pendingRoundTrips.remove(id: originalMessageId)
                                                }
                                            }
                                        }
                                    }
                                }
                                
                                // Log error message (these are expected when target device is not connected)
                                // Only log non-permanent errors here (permanent errors already logged above)
                                if code != "device_not_connected" && code != "incorrect_device_id" {
                                    logger.debug("⚠️ [WebSocketTransport] Server error: \(code) - \(message)")
                                }
                                if let targetDeviceId = targetDeviceId {
                                    logger.debug("   Target device: \(targetDeviceId)")
                                }
                                if let connectedDevices = connectedDevices, !connectedDevices.isEmpty {
                                    logger.debug("   Currently connected devices: \(connectedDevices.joined(separator: ", "))")
                                } else {
                                    logger.debug("   No devices currently connected to relay")
                                }
                                
                                // Error messages are informational - don't try to decode as SyncEnvelope
                                return
                            }
                        }
                        
                        // Control messages have structure: {"msg_type":"control","payload":{...}}
                        // They don't have an "id" field, so decoding as SyncEnvelope will fail
                        if jsonString.contains("\"msg_type\"") && jsonString.contains("\"control\"") {
                            // Try to parse as control message
                            if let jsonDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let msgType = jsonDict["msg_type"] as? String,
                               msgType == "control",
                               let payload = jsonDict["payload"] as? [String: Any],
                               let action = payload["action"] as? String {
                                logger.debug("📋 [WebSocketTransport] Control message: \(action)")
                                if action == "routing_failure" {
                                    if let reason = payload["reason"] as? String {
                                        // Log as debug instead of warning - these are expected when devices are offline
                                        logger.debug("ℹ️ [WebSocketTransport] Routing failure: \(reason)")
                                    }
                                    if let targetDeviceId = payload["target_device_id"] as? String {
                                        // Log as debug instead of warning - these are expected when devices are offline
                                        logger.debug("ℹ️ [WebSocketTransport] Target device not connected: \(targetDeviceId)")
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
            
            // Check if this is an acknowledgment for an in-flight message
            // (In some scenarios, the server may echo back the same envelope ID as acknowledgment)
            if self.inFlightMessages.removeValue(forKey: envelope.id) != nil {
                self.logger.debug("✅ [WebSocketTransport] Received ack for message \(envelope.id.uuidString.prefix(8))")
                // Remove from pending round trips since we got server confirmation
                Task {
                    _ = await self.pendingRoundTrips.remove(id: envelope.id)
                }
            }
            
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
                logger.info("📤 [WebSocketTransport] Forwarding to onIncomingMessage handler (origin: \(transportOrigin.rawValue))")
                Task {
                    await handler(data, transportOrigin)
                }
            } else {
                logger.warning("⚠️ [WebSocketTransport] No onIncomingMessage handler set")
            }
        } catch let decodingError as DecodingError {
            logger.error("❌ [WebSocketTransport] Failed to decode incoming data: \(decodingError)")
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
            logger.error("❌ [WebSocketTransport] Failed to decode incoming data: \(error)")
            Task {
                await pendingRoundTrips.pruneExpired(referenceDate: Date())
            }
        }
    }

    func handleOpen(task: WebSocketTasking) {
        logger.debug("✅ [WebSocketTransport] Connection opened")
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
        logger.info("📡 [WebSocketTransport] handleOpen: Starting receiveNext()")
        receiveNext(on: task)
    }
}

extension WebSocketTransport: URLSessionDelegate {
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
