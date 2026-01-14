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
    var maximumMessageSize: Int { get set }
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
        var data: Data
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
    // Track pending control message queries (query ID -> continuation)
    // Thread-safe access using a serial queue
    private let pendingControlQueriesQueue = DispatchQueue(label: "com.hypo.clipboard.pendingControlQueries")
    private var pendingControlQueries: [String: CheckedContinuation<[String: Any], Never>] = [:]

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
            await reconnecting.value
            // After reconnection completes, check if we're now connected
            if case .connected = state {
                return
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
        
        // CRITICAL: Set maximumMessageSize to 1GB to support large file transfers
        // This allows WebSocket to automatically fragment large messages using RFC 6455 fragmentation
        // The server already supports 1GB frames, so this enables end-to-end large file support
        task.maximumMessageSize = 1_073_741_824 // 1GB
        logger.debug("📏 [WebSocketTransport] Set maximumMessageSize to 1GB for automatic fragmentation")
        
        state = .connecting

        // CRITICAL: Retain self and session during connection to prevent deallocation
        let retainedSelf = self
        let retainedSession = session
        
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Ensure session and self are retained
                let _ = retainedSelf
                let _ = retainedSession
                
                handshakeContinuation = continuation
                task.resume()
            }
            logger.debug("✅ [WebSocketTransport] Connection established")
        } catch {
            logger.error("❌ [WebSocketTransport] Connection failed: \(error.localizedDescription)")
            // Clear handshake continuation if it's still set (timeout case)
            if handshakeContinuation != nil {
                logger.error("⚠️ [WebSocketTransport] Handshake continuation still set after error - clearing it")
                handshakeContinuation = nil
            }
            state = .idle
            throw error
        }
    }

    public func send(_ envelope: SyncEnvelope) async throws {
        // Encode message - WebSocket will automatically fragment if needed (up to 1GB)
        let encodedData = try frameCodec.encode(envelope)
        await pendingRoundTrips.store(date: Date(), for: envelope.id)
        
        // Queue Overflow Protection: Max 100 messages
        // Drop oldest messages if queue is full
        let maxQueueSize = 100
        if messageQueue.count >= maxQueueSize {
            // Drop oldest messages until we have space
            // (Drop up to 10 messages at a time to create buffer)
            let dropCount = min(10, messageQueue.count)
            let dropped = messageQueue.prefix(dropCount)
            messageQueue.removeFirst(dropCount)
            
            for msg in dropped {
                _ = await pendingRoundTrips.remove(id: msg.envelope.id)
            }
            logger.warning("⚠️ [WebSocketTransport] Queue overflow: dropped \(dropCount) oldest messages to make room")
        }
        
        // Ensure connection before queuing
        // This prevents queuing messages when we know we can't send them
        try await ensureConnected()
        
        // Add to queue
        let queuedMessage = QueuedMessage(
            envelope: envelope,
            data: encodedData,
            queuedAt: Date(),
            retryCount: 0
        )
        messageQueue.append(queuedMessage)
        
        logger.debug("📥 [WebSocketTransport] Queued message: type=\(envelope.payload.contentType), size=\(encodedData.count.formattedAsKB), id=\(envelope.id.uuidString.prefix(8)), queue=\(messageQueue.count)")
        
        // Start queue processor if not already running
        // The queue processor will handle sending and retries
        // ensureConnected() already handles waiting for reconnection if needed
        if queueProcessingTask == nil || queueProcessingTask?.isCancelled == true {
            queueProcessingTask = Task { [weak self] in
                await self?.processMessageQueue()
            }
        }
        
        // Return immediately - queue processor will handle sending
        // If connection fails, ensureConnected() will wait for reconnection
        // If send fails, queue processor will retry with backoff
    }
    
    private func processMessageQueue() async {
        let maxRetries: UInt = 8
        let initialBackoff: TimeInterval = 1.0 // 1 second
        let maxTimeout: TimeInterval = 600.0 // 10 minutes (connection timeout)
        let messageExpiration: TimeInterval = 300.0 // 5 minutes (strict expiration)
        
        
        while !messageQueue.isEmpty {
            let queueSizeBefore = messageQueue.count
            var queuedMessage = messageQueue.removeFirst()
            
            // Check Message Expiration (5 min strict)
            let timeInQueue = Date().timeIntervalSince(queuedMessage.queuedAt)
            if timeInQueue > messageExpiration {
                logger.info("❌ [WebSocketTransport] Message expired (queued \(Int(timeInQueue))s ago), dropping: id=\(queuedMessage.envelope.id.uuidString.prefix(8))")
                _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                continue
            }
            
            // Check Connection Timeout (10 minutes from queue time - fallback)
            if timeInQueue > maxTimeout {
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

                
                // CRITICAL FIX: For large messages (>100KB), add a delay after connection
                // and verify readiness with ping/pong to ensure the WebSocket handshake is
                // fully complete on the server side. This prevents actix_ws buffer overflow
                // during handshake when large messages are sent immediately after connection.
                // 
                // Root cause: actix_ws has an internal buffer limit during WebSocket upgrade.
                // If a large message is sent too quickly after connection, the server's
                // actix_ws::handle() may still be processing the handshake and overflow occurs.
                let messageSize = queuedMessage.data.count
                if messageSize > 100_000 { // 100KB threshold
                    // Delay scales with message size: 
                    // - 200KB: ~500ms
                    // - 400KB: ~1000ms (1 second)
                    // - 500KB+: ~1500ms (1.5 seconds)
                    let delayMs = min(1500, max(500, Int(messageSize / 400))) // 500-1500ms range
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    
                    // Additional safety: Send ping and wait for pong to confirm connection is ready
                    guard case .connected(let pingTask) = state else {
                        logger.warning("⚠️ [WebSocketTransport] Connection lost during delay, requeuing message")
                        queuedMessage.retryCount += 1
                        if queuedMessage.retryCount <= maxRetries {
                            messageQueue.append(queuedMessage)
                        } else {
                            logger.info("❌ [WebSocketTransport] Max retries reached, dropping message")
                            _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                        }
                        continue
                    }
                    

                    do {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            pingTask.sendPing { error in
                                if let error {
                                    continuation.resume(throwing: error)
                                } else {
                                    continuation.resume(returning: ())
                                }
                            }
                        }

                    } catch {
                        logger.warning("⚠️ [WebSocketTransport] Ping failed, connection may not be ready: \(error.localizedDescription)")
                        // Continue anyway - the delay should be sufficient
                    }
                }
            } catch {
                logger.warning("⚠️ [WebSocketTransport] Connection failed on retry \(queuedMessage.retryCount): \(error.localizedDescription)")
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
                self.logger.debug("📤 [WebSocketTransport] Message in-flight: type=\(contentType), size=\(frameSize.formattedAsKB), id=\(messageId.uuidString.prefix(8))")
                
                // Set up timeout to handle cases where server doesn't respond
                // If no error response is received within timeout, check connection state:
                // - If connection is valid, assume success (server may not send explicit ack)
                // - If connection is invalid, requeue message for retry
                let timeoutDuration: TimeInterval = frameSize > 100_000 ? 10.0 : 5.0 // Longer timeout for large messages
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutDuration * 1_000_000_000))
                    guard let strongSelf = self else { return }
                    await MainActor.run {
                        // Check if message is still in-flight
                        guard let queuedMessage = strongSelf.inFlightMessages.removeValue(forKey: messageId) else {
                            // Message was already removed (either confirmed or failed)
                            return
                        }
                        
                        // Check connection state before assuming success
                        let isConnected: Bool
                        switch strongSelf.state {
                        case .connected:
                            isConnected = true
                        default:
                            isConnected = false
                        }
                        
                        if isConnected {
                            // Connection is valid - assume message was sent successfully
                            strongSelf.logger.debug("✅ [WebSocketTransport] Message confirmed (timeout, connection valid): id=\(messageId.uuidString.prefix(8))")
                            Task {
                                _ = await strongSelf.pendingRoundTrips.remove(id: messageId)
                            }
                        } else {
                            // Connection is invalid - don't requeue here to avoid duplicate nonce errors
                            // The message will be retried at HistoryStore level if it truly failed
                            strongSelf.logger.warning("⚠️ [WebSocketTransport] Message timeout but connection invalid: id=\(messageId.uuidString.prefix(8)), frame=\(queuedMessage.data.count.formattedAsKB)")
                        }
                    }
                }
                
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
                    self.logger.info("⚠️ [WebSocketTransport] \(errorType.capitalized) during send (likely during large payload transmission), requeuing message")
                    // Don't increment retry count for transient errors - this is expected for large payloads
                    messageQueue.append(queuedMessage)
                    
                    // Only trigger reconnection if socket is actually not connected
                    // For cancellation errors, the connection might still be valid - just retry the send
                    if isSocketNotConnected {
                        // Socket is closed - need to reconnect
                        reconnectWithBackoff()
                    } else if isCancellationError {
                        // Cancellation error but connection might still be valid
                        // Check if we're still connected - if not, trigger reconnection
                        if case .connected = state {
                            // Still connected - just retry without reconnecting
                            self.logger.debug("🔄 [WebSocketTransport] Connection still valid, will retry send")
                            // CRITICAL: Restart queue processor if it stopped
                            await triggerQueueProcessingIfNeeded()
                        } else {
                            // Not connected - trigger reconnection
                            reconnectWithBackoff()
                        }
                    }
                    
                    // CRITICAL: Always restart queue processor after requeuing, regardless of error type
                    // The processor may have exited while we were handling the error
                    await triggerQueueProcessingIfNeeded()
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
        
        // Check if queue is actually empty before stopping
        // Messages may have been requeued while we were processing (e.g., after cancellation)
        if messageQueue.isEmpty {
            queueProcessingTask = nil
            logger.debug("✅ [WebSocketTransport] Message queue empty, stopping processor")
        } else {
            // Queue has new messages (possibly requeued), continue processing
            // Don't set queueProcessingTask to nil - let it continue
        }
    }

    /// Enter sleep mode: disconnect but preserve message queue (pause sync)
    public func enterSleepMode() async {
        logger.info("💤 [WebSocketTransport] Entering sleep mode - disconnecting but preserving queue")
        await disconnect(clearQueue: false)
    }
    
    /// Exit sleep mode: reconnect and resume sync
    public func exitSleepMode() async {
        logger.info("🌅 [WebSocketTransport] Exiting sleep mode - reconnecting")
        // Check if we need to reconnect
        if !isConnected() {
            try? await connect()
        }
        // Trigger queue processing to resume sending
        await triggerQueueProcessingIfNeeded()
    }
    
    public func disconnect() async {
        await disconnect(clearQueue: true)
    }
    
    private func disconnect(clearQueue: Bool) async {
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
        
        // Only clear message queue on intentional disconnect (not during reconnection)
        // During reconnection, we want to preserve requeued messages for retry
        if clearQueue {
            let queueSize = messageQueue.count
            if queueSize > 0 {
                logger.debug("🧹 [WebSocketTransport] Clearing \(queueSize) queued messages on disconnect")
                for queuedMessage in messageQueue {
                    _ = await pendingRoundTrips.remove(id: queuedMessage.envelope.id)
                }
                messageQueue.removeAll()
            }
        } else {
            let queueSize = messageQueue.count
            if queueSize > 0 {
                logger.debug("🔄 [WebSocketTransport] Preserving \(queueSize) queued messages during reconnection")
            }
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
    
    /// Query connected peers from cloud relay (only works for cloud connections)
    /// Returns list of connected device IDs, or empty array if query fails
    /// - Parameter peerIds: Optional list of device IDs to check presence for. If nil, returns all connected peers (server may limit this).
    public func queryConnectedPeers(_ peerIds: [String]? = nil) async -> [String] {
        guard configuration.environment == "cloud" else {
            logger.debug("⚠️ [WebSocketTransport] queryConnectedPeers only works for cloud connections")
            return []
        }
        
        guard case .connected(let task) = state else {
            logger.debug("⚠️ [WebSocketTransport] Cannot query connected peers: not connected")
            return []
        }
        
        let queryId = UUID().uuidString.lowercased()
        
        var payload: [String: Any] = [
            "action": "query_connected_peers",
            "original_message_id": queryId
        ]
        
        if let peerIds = peerIds {
            payload["device_ids"] = peerIds
        }
        
        // Create control message as raw JSON (not SyncEnvelope)
        let controlMessage: [String: Any] = [
            "id": queryId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "version": "1.0",
            "type": "control",
            "payload": payload
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: controlMessage),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            logger.warning("⚠️ [WebSocketTransport] Failed to encode control message")
            return []
        }
        
        let responsePayload = await withCheckedContinuation { continuation in
            // Store continuation for response handling (thread-safe)
            self.pendingControlQueriesQueue.sync {
                self.pendingControlQueries[queryId] = continuation
            }
            
            // Send raw JSON control message
            task.send(.string(jsonString)) { error in
                if let error = error {
                    self.logger.warning("⚠️ [WebSocketTransport] Failed to send query_connected_peers: \(error.localizedDescription)")
                    // Only resume if we successfully remove the continuation (prevents double resume)
                    // Thread-safe removal
                    if let pending = self.pendingControlQueriesQueue.sync(execute: { self.pendingControlQueries.removeValue(forKey: queryId) }) {
                        pending.resume(returning: [:])
                    }
                } else {
                    // Set timeout - if no response in 5 seconds, return empty dictionary (will result in empty array)
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        // Only resume if we successfully remove the continuation (prevents double resume)
                        // This ensures that if the response came in first, we won't try to resume again
                        // Thread-safe removal
                        if let pending = self.pendingControlQueriesQueue.sync(execute: { self.pendingControlQueries.removeValue(forKey: queryId) }) {
                            pending.resume(returning: [:])
                        }
                    }
                }
            }
        }
        
        // Extract connected_devices array from payload
        if let devicesArray = responsePayload["connected_devices"] as? [String] {
            return devicesArray
        }
        return []
    }

    private func ensureConnected() async throws {
        // Wait for any in-progress reconnection to complete
        if let reconnecting = reconnectingTask, !reconnecting.isCancelled {
            logger.debug("⏳ [WebSocketTransport] Waiting for in-progress reconnection...")
            await reconnecting.value
        }
        
        switch state {
        case .connected:
            return
        case .idle, .connecting:
            // If not reconnecting, try to connect
            // But first check if a reconnection is scheduled (even if not started yet)
            if let reconnecting = reconnectingTask, !reconnecting.isCancelled {
                logger.debug("⏳ [WebSocketTransport] Reconnection scheduled, waiting...")
                await reconnecting.value
                // After waiting, if still not connected, try direct connect
                if case .connected = state {
                    // already connected, nothing to do
                } else {
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
            
            // Disconnect first, but preserve message queue for retry
            await self.disconnect(clearQueue: false)
            
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
        
        // Check for in-flight messages when connection closes
        let inFlightCount = inFlightMessages.count
        let inFlightSizes = inFlightMessages.values.map { $0.data.count.formattedAsKB }.joined(separator: ", ")
        
        // Enhanced logging for cloud connections
        var closeMsg = "🔌 [WebSocketTransport] WebSocket closed\n"
        closeMsg += "   Close code: \(closeCode.rawValue) (\(closeCodeMsg))\n"
        closeMsg += "   Reason: \(reasonStr)\n"
        closeMsg += "   URL: \(configuration.url.absoluteString)\n"
        closeMsg += "   Environment: \(configuration.environment)\n"
        closeMsg += "   State: \(state)\n"
        if inFlightCount > 0 {
            closeMsg += "   ⚠️ In-flight messages: \(inFlightCount) (sizes: \(inFlightSizes))\n"
            closeMsg += "   This suggests the server closed the connection during large message transmission\n"
        }
        
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
        
        // Check for in-flight messages - if socket closes during large payload transmission
        // NOTE: We don't requeue here because:
        // 1. The message may have already been successfully sent (send callback fired)
        // 2. Requeuing would use the same nonce, causing Android to reject it as duplicate
        // 3. If the message truly failed, it will be retried at the HistoryStore level,
        //    which will go through DualSyncTransport and generate a new nonce
        if !inFlightMessages.isEmpty {
            let inFlightCount = inFlightMessages.count
            logger.info("⚠️ [WebSocketTransport] Socket closed with \(inFlightCount) in-flight message(s)")
            // Not requeuing - messages may have been sent successfully. If not, they will be retried at HistoryStore level with new nonces.
            // Clear in-flight messages - don't requeue to avoid duplicate nonce errors
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
        guard !messageQueue.isEmpty else {
            return
        }
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
                    self.logger.info("📥 [WebSocketTransport] Received binary message: \(data.count.formattedAsKB), environment=\(self.configuration.environment), url=\(self.configuration.url.absoluteString)")
                    self.handleIncoming(data: data)
                } else if case .string(let str) = message {
                    self.logger.info("📝 [WebSocketTransport] Received text message: \(str.prefix(100))")
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
                
                // Log detailed error information to diagnose connection failures
                let inFlightCount = inFlightMessages.count
                let inFlightSizes = inFlightMessages.values.map { $0.data.count.formattedAsKB }.joined(separator: ", ")
                
                if isSocketNotConnected {
                    // Socket is not connected - this could be:
                    // 1. Server closed the connection (check close code in didCompleteWithError)
                    // 2. Network issue during large message transmission
                    // 3. Receive callback from stale socket (already handled above)
                    if inFlightCount > 0 {
                        logger.warning("⚠️ [WebSocketTransport] Receive failed: Socket not connected during large message send")
                        logger.warning("   In-flight messages: \(inFlightCount) (sizes: \(inFlightSizes))")
                        logger.warning("   Error: \(errorDescription)")
                        logger.warning("   Error domain: \(nsError.domain), code: \(nsError.code)")
                        logger.warning("   This suggests the connection was closed by server or network during transmission")
                    } else {
                        logger.debug("ℹ️ [WebSocketTransport] Receive failed: Socket is not connected (no in-flight messages)")
                    }
                    
                    // If we have in-flight messages, the connection was likely closed during send
                    // NOTE: We don't requeue here because:
                    // 1. The message may have already been successfully sent (send callback fired)
                    // 2. Requeuing would use the same nonce, causing Android to reject it as duplicate
                    // 3. If the message truly failed, it will be retried at the HistoryStore level,
                    //    which will go through DualSyncTransport and generate a new nonce
                    if !inFlightMessages.isEmpty {
                        logger.info("⚠️ [WebSocketTransport] Socket disconnected with \(inFlightCount) in-flight message(s)")
                        logger.info("ℹ️ [WebSocketTransport] Not requeuing - messages may have been sent successfully. If not, they will be retried at HistoryStore level with new nonces.")
                        
                        // Update state to idle to prevent further sends on this connection
                        state = .idle
                        
                        // Clear in-flight messages - don't requeue to avoid duplicate nonce errors
                        inFlightMessages.removeAll()
                        
                        // Trigger reconnection immediately (don't wait)
                        reconnectWithBackoff()
                    } else {
                        // No in-flight messages, but receive failed - connection might be dead
                        // Update state and trigger reconnection
                        state = .idle
                        reconnectWithBackoff()
                    }
                } else {
                    logger.warning("❌ [WebSocketTransport] Receive failed: \(errorDescription)")
                    logger.warning("   Error domain: \(nsError.domain), code: \(nsError.code)")
                    if inFlightCount > 0 {
                        logger.warning("   In-flight messages: \(inFlightCount) (sizes: \(inFlightSizes))")
                    }
                    // Update state to idle and trigger reconnection for real failures
                    state = .idle
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
                            // Try to parse as error message
                            if let jsonDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                               let type = jsonDict["type"] as? String,
                               type == "error",
                               let payload = jsonDict["payload"] as? [String: Any] {
                                let code = payload["code"] as? String ?? "unknown"
                                let message = payload["message"] as? String ?? "Unknown error"
                                let targetDeviceId = payload["target_device_id"] as? String
                                let connectedDevices = payload["connected_devices"] as? [String]
                                let originalMessageIdStr = payload["original_message_id"] as? String
                                
                                // Skip logging for expected errors when sending to offline devices
                                // device_not_connected is expected when sending to offline peers (relay will queue)
                                let isExpectedError = code == "device_not_connected" || code == "incorrect_device_id"
                                
                                // Only log unexpected errors
                                if !isExpectedError {
                                    logger.warning("⚠️ [WebSocketTransport] Received error from relay: code=\(code), message=\(message)")
                                    if let targetDeviceId = targetDeviceId {
                                        logger.warning("   Target device: \(targetDeviceId.prefix(8))...")
                                    }
                                    if let originalMessageIdStr = originalMessageIdStr {
                                        logger.warning("   Original message ID: \(originalMessageIdStr.prefix(8))...")
                                    }
                                    if let connectedDevices = connectedDevices, !connectedDevices.isEmpty {
                                        logger.warning("   Connected devices: \(connectedDevices.map { $0.prefix(8) + "..." }.joined(separator: ", "))")
                                    } else {
                                        logger.warning("   No devices currently connected to relay")
                                    }
                                }
                                
                                // Check if this error is for an in-flight message
                                if let originalMessageIdStr = originalMessageIdStr,
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
                                
                                // Error messages are informational - don't try to decode as SyncEnvelope
                                return
                            }
                        }
                        
                        // Control messages have structure: {"type":"control","payload":{...}}
                        // They don't have a "contentType" field, so decoding as SyncEnvelope will fail
                        // Check for control messages by parsing JSON first (more reliable than string contains)
                        if let jsonDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let msgType = jsonDict["type"] as? String,
                           msgType == "control",
                           let payload = jsonDict["payload"] as? [String: Any],
                           let action = payload["action"] as? String {
                            logger.debug("📋 [WebSocketTransport] Control message: \(action)")
                            
                            // Handle query_connected_peers response
                            if action == "query_connected_peers" {
                                if let originalMessageId = payload["original_message_id"] as? String,
                                   let continuation = self.pendingControlQueriesQueue.sync(execute: { self.pendingControlQueries.removeValue(forKey: originalMessageId) }) {
                                    // Return the payload which contains connected_devices array
                                    continuation.resume(returning: payload)
                                    return
                                } else {
                                    logger.debug("⚠️ [WebSocketTransport] query_connected_peers response received but no matching continuation found (original_message_id: \(payload["original_message_id"] as? String ?? "nil"))")
                                }
                            }
                            
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
                            
                            // Control messages are informational - don't try to decode as SyncEnvelope
                            return
                        }
                    }
                }
            }
            
            let envelope = try frameCodec.decode(data)
            
            // Log envelope details for debugging
            logger.info("📦 [WebSocketTransport] Decoded envelope: type=\(envelope.type.rawValue), id=\(envelope.id.uuidString.prefix(8)), target=\(envelope.payload.target ?? "nil"), deviceId=\(envelope.payload.deviceId.prefix(8))")
            
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
                logger.info("✅ [WebSocketTransport] Calling onIncomingMessage handler: origin=\(transportOrigin.rawValue), envelopeType=\(envelope.type.rawValue)")
                Task {
                    await handler(data, transportOrigin)
                }
            } else {
                logger.warning("⚠️ [WebSocketTransport] No onIncomingMessage handler set - message will be dropped!")
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
                logger.error("   Frame header: length=\(length.formattedAsKB), total data=\(data.count.formattedAsKB)")
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
