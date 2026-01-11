package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.sync.SyncEnvelope
import com.hypo.clipboard.sync.SyncTransport
import com.hypo.clipboard.transport.NoopTransportAnalytics
import com.hypo.clipboard.transport.NoopTransportMetricsRecorder
import com.hypo.clipboard.transport.TransportAnalytics
import com.hypo.clipboard.transport.TransportAnalyticsEvent
import com.hypo.clipboard.transport.TransportMetricsRecorder
import java.io.IOException
import java.net.ConnectException
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.net.ssl.SSLPeerUnverifiedException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withTimeout
import kotlin.coroutines.coroutineContext
import okhttp3.CertificatePinner
import java.net.URI
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.of
import kotlin.math.max
import kotlin.math.min
import java.util.concurrent.TimeUnit
import org.json.JSONObject

interface WebSocketConnector {
    fun connect(listener: WebSocketListener): WebSocket
}

class OkHttpWebSocketConnector @Inject constructor(
    private val config: TlsWebSocketConfig,
    okHttpClient: OkHttpClient? = null
) : WebSocketConnector {
    private val client: OkHttpClient
    private val request: Request

    init {
        val baseClient = okHttpClient ?: OkHttpClient()
        
        // For LAN connections, URL may be null (will be provided when peer is discovered)
        // However, we should never create a connector without a URL - it must be created after discovery
        if (config.url == null) {
            if (config.environment == "cloud") {
                throw IllegalArgumentException("Cloud WebSocket URL cannot be null")
            }
            // LAN connection without URL - this connector should never be created
            // Connectors for LAN connections must be created after peer discovery with the discovered URL
            throw IllegalStateException("LAN WebSocket connector cannot be created without a URL. Connector must be created after peer discovery.")
        } else {
            val urlString = config.url
            val normalizedUrl = normalizeWebSocketUrl(urlString)
            // Validate URL before parsing
            if (normalizedUrl.isBlank()) {
                throw IllegalArgumentException("WebSocket URL cannot be blank")
            }
            // Log the URL being parsed for debugging
            android.util.Log.d("OkHttpWebSocketConnector", "🔗 Parsing WebSocket URL: $normalizedUrl (original: $urlString)")
            val url = try {
                normalizedUrl.toHttpUrl()
            } catch (e: IllegalArgumentException) {
                android.util.Log.e("OkHttpWebSocketConnector", "❌ Failed to parse URL: $normalizedUrl", e)
                throw IllegalArgumentException("Invalid WebSocket URL: $normalizedUrl (original: $urlString)", e)
            }
            android.util.Log.d("OkHttpWebSocketConnector", "✅ Parsed URL - scheme: ${url.scheme}, host: ${url.host}, port: ${url.port}")
        val builder = baseClient.newBuilder()
            // Configure timeouts to match roundTripTimeoutMillis for large payloads (images)
            // Default OkHttpClient has 10s timeouts, which can be too short for large image transfers
            // Use roundTripTimeoutMillis (60s default) or a minimum of 30s for connection establishment
            val connectTimeoutMs = max(config.roundTripTimeoutMillis, 30_000L)
            val readTimeoutMs = max(config.roundTripTimeoutMillis, 30_000L)
            val writeTimeoutMs = max(config.roundTripTimeoutMillis, 30_000L)
            builder.connectTimeout(connectTimeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
            builder.readTimeout(readTimeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
            builder.writeTimeout(writeTimeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
            android.util.Log.d("OkHttpWebSocketConnector", "⏱️ Configured timeouts: connect=${connectTimeoutMs}ms, read=${readTimeoutMs}ms, write=${writeTimeoutMs}ms")
            // Only apply certificate pinning for secure connections (wss:// -> https://)
            // Skip pinning for non-secure connections (ws:// -> http://)
            val isSecure = urlString.startsWith("wss://", ignoreCase = true)
            val fingerprint = config.fingerprintSha256?.takeIf { it.isNotBlank() }
            if (isSecure && fingerprint != null) {
                val hex = fingerprint
                try {
            val pin = hexToPin(hex)
            val pinner = CertificatePinner.Builder()
                .add(url.host, "sha256/$pin")
                .build()
            builder.certificatePinner(pinner)
                } catch (e: IllegalArgumentException) {
                    // Invalid fingerprint format - log and skip pinning
                    android.util.Log.w("OkHttpWebSocketConnector", "Invalid fingerprint format: ${e.message}, skipping certificate pinning")
                }
        }
        client = builder.build()
        val requestBuilder = Request.Builder().url(url)
        config.headers.forEach { (key, value) ->
            requestBuilder.addHeader(key, value)
        }
            // Debug: Log headers being sent
            if (config.headers.isNotEmpty()) {
                android.util.Log.d("OkHttpWebSocketConnector", "📤 WebSocket headers: ${config.headers.keys.joinToString()}")
            } else {
                android.util.Log.w("OkHttpWebSocketConnector", "⚠️ No headers configured for WebSocket connection to $url")
            }
        request = requestBuilder.build()
        }
    }

    override fun connect(listener: WebSocketListener): WebSocket {
        // For LAN connections with null URL, this should never be called
        // The connector will be replaced when peer is discovered
        if (config.url == null && config.environment == "lan") {
            throw IllegalStateException("WebSocket connector not initialized with URL (LAN connection requires peer discovery)")
        }
        return client.newWebSocket(request, listener)
    }

    companion object {
        fun hexToPin(hex: String): String = fingerprintToPin(hex)

        private fun normalizeWebSocketUrl(rawUrl: String): String {
            val trimmed = rawUrl.trim()
            return when {
                trimmed.startsWith("wss://", ignoreCase = true) -> "https://" + trimmed.substring(6)
                trimmed.startsWith("ws://", ignoreCase = true) -> "http://" + trimmed.substring(5)
                trimmed.startsWith("https://", ignoreCase = true) -> trimmed // Already normalized
                trimmed.startsWith("http://", ignoreCase = true) -> trimmed // Already normalized
                trimmed.startsWith("/") -> {
                    // If URL starts with /, it's likely a path - this is an error
                    android.util.Log.e("OkHttpWebSocketConnector", "❌ Invalid URL format: starts with '/' - $trimmed")
                    throw IllegalArgumentException("Invalid WebSocket URL: URL cannot start with '/' - $trimmed")
                }
                else -> {
                    // If no scheme, assume it's a host:port and add http:// (for ws:// connections)
                    android.util.Log.w("OkHttpWebSocketConnector", "⚠️ URL missing scheme, assuming http:// (ws://): $trimmed")
                    "http://$trimmed"
                }
            }
        }
    }
}

/**
 * Unified WebSocket transport client for both LAN and cloud connections.
 * Behavior is determined by config.environment ("lan" or "cloud").
 * For LAN: uses peer discovery to find connection URL dynamically.
 * For cloud: uses config.url for relay server connection.
 */
class WebSocketTransportClient @Inject constructor(
    private val config: TlsWebSocketConfig,
    private val connector: WebSocketConnector?, // Nullable for LAN connections (created after peer discovery)
    private val frameCodec: TransportFrameCodec = TransportFrameCodec(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val clock: Clock = Clock.systemUTC(),
    private val metricsRecorder: TransportMetricsRecorder = NoopTransportMetricsRecorder,
    private val analytics: TransportAnalytics = NoopTransportAnalytics,
    private val transportManager: com.hypo.clipboard.transport.TransportManager? = null
) : SyncTransport {
    private val sendQueue = Channel<SyncEnvelope>(Channel.BUFFERED)
    private val mutex = Mutex()
    private var webSocket: WebSocket? = null
    private var connectionJob: Job? = null
    private var watchdogJob: Job? = null
    private var lastActivity: Instant = clock.instant()
    private val isClosed = AtomicBoolean(false)
    private val isOpen = AtomicBoolean(false) // Track if onOpen was actually called
    @Volatile private var handshakeStarted: Instant? = null
    private val pendingLock = Any()
    private val pendingRoundTrips = mutableMapOf<String, Instant>()
    private val pendingTtl = Duration.ofMillis(max(0L, config.roundTripTimeoutMillis))
    private var onIncomingClipboard: ((SyncEnvelope, com.hypo.clipboard.domain.model.TransportOrigin) -> Unit)? = null
    private var onPairingAck: ((String) -> Unit)? = null  // ACK as JSON string
    private var onPairingChallenge: (suspend (String) -> String?)? = null  // Challenge as JSON string -> ACK JSON or null
    private var onSyncError: ((String, String) -> Unit)? = null  // Error handler: (deviceName, errorMessage) -> Unit
    private val pendingControlQueries = mutableMapOf<String, CompletableDeferred<org.json.JSONObject>>()
    @Volatile private var connectionSignal = CompletableDeferred<Unit>()
    @Volatile private var currentConnector: WebSocketConnector? = connector // Nullable for LAN (created after discovery)
    @Volatile private var lastKnownUrl: String? = null  // Use only lastKnownUrl - updated when peer is discovered
    private var allowedDeviceIdsProvider: (() -> Set<String>)? = null
    // Event-driven reconnection: track consecutive connection failures for exponential backoff
    private var consecutiveFailures = 0  // Track failures for both cloud and LAN connections
    private val maxBackoffDelay = 128_000L // 128 seconds max delay
    private val baseBackoffDelay = 1_000L // 1 second base delay
    // Guard against concurrent reconnection attempts (prevent duplicate ensureConnection() calls)
    @Volatile private var isReconnecting = false
    
    // Determine transport origin based on config environment
    private val transportOrigin: com.hypo.clipboard.domain.model.TransportOrigin = 
        if (config.environment == "cloud") {
            com.hypo.clipboard.domain.model.TransportOrigin.CLOUD
        } else {
            com.hypo.clipboard.domain.model.TransportOrigin.LAN
        }
    
    fun setIncomingClipboardHandler(handler: (SyncEnvelope, com.hypo.clipboard.domain.model.TransportOrigin) -> Unit) {
        onIncomingClipboard = handler
    }
    
    // Backward compatibility: handler without transport origin (defaults to LAN)
    fun setIncomingClipboardHandler(handler: (SyncEnvelope) -> Unit) {
        onIncomingClipboard = { envelope, _ -> handler(envelope) }
    }
    
    fun setPairingAckHandler(handler: (String) -> Unit) {
        onPairingAck = handler
    }
    
    fun setPairingChallengeHandler(handler: (suspend (String) -> String?)) {
        onPairingChallenge = handler
    }
    
    fun setSyncErrorHandler(handler: (String, String) -> Unit) {
        onSyncError = handler
    }

    /** Allow caller to restrict which discovered peers we connect to (e.g., only paired devices). */
    fun setAllowedDeviceIdsProvider(provider: () -> Set<String>) {
        allowedDeviceIdsProvider = provider
    }
    
    /**
     * Check if the WebSocket is currently connected.
     * This is used to determine connection status in the UI.
     */
    fun isConnected(): Boolean {
        return mutex.tryLock().let { locked ->
            try {
                // Check if WebSocket exists, is open (onOpen was called), and is not closed
                val hasWebSocket = webSocket != null
                val isOpenState = isOpen.get()
                val isClosedState = isClosed.get()
                if (!hasWebSocket || !isOpenState || isClosedState) {
                    return false
                }
                // For cloud connections, verify we're using the config URL
                val isCloudConnection = config.environment == "cloud"
                if (isCloudConnection) {
                    // For cloud, lastKnownUrl should be null (we use config.url)
                    // config.url should not be null for cloud connections
                    if (lastKnownUrl != null || config.url == null) {
                        return false
                    }
                }
                true
            } finally {
                if (locked) mutex.unlock()
            }
        }
    }

    override suspend fun send(envelope: SyncEnvelope) {
        val isCloudConnection = config.environment == "cloud"
        
        // Only resolve peer URLs for LAN connections - cloud connections always use config.url
        if (!isCloudConnection) {
            // Resolve target device's IP address from discovered peers (LAN only)
            val targetDeviceId = envelope.payload.target
            if (targetDeviceId != null && transportManager != null) {
                val peers = transportManager.currentPeers()
                val peer = peers.find { 
                    val peerDeviceId = it.attributes["device_id"] ?: it.serviceName
                    peerDeviceId == targetDeviceId || peerDeviceId.equals(targetDeviceId, ignoreCase = true)
                }
                
                val peerUrl = when {
                    peer != null && peer.host != "unknown" && peer.host != "127.0.0.1" -> {
                        // Use discovered peer's IP address
                        // Fix: Wrap IPv6 addresses in brackets (required by OkHttp/URI)
                        val host = if (peer.host.contains(":")) "[${peer.host}]" else peer.host
                        "ws://$host:${peer.port}"
                    }
                    peer != null && peer.host == "127.0.0.1" -> {
                        // Emulator case: replace localhost with host IP
                        // For emulator, 10.0.2.2 is the special IP to reach host machine
                        val emulatorHost = "10.0.2.2"
                        "ws://$emulatorHost:${peer.port}"
                    }
                    else -> null
                }
                
                if (peerUrl != null && peerUrl != lastKnownUrl) {
                    // Peer IP changed - update lastKnownUrl and trigger reconnection (LAN only)
                    android.util.Log.d("WebSocketTransportClient", "🔄 Peer IP changed in send(): $peerUrl (was: $lastKnownUrl) - reconnecting")
                    lastKnownUrl = peerUrl
                    val isSecure = peerUrl.startsWith("wss://", ignoreCase = true)
                    val peerConfig = TlsWebSocketConfig(
                        url = peerUrl,
                        fingerprintSha256 = if (isSecure) peer?.fingerprint else null, // No pinning for ws://
                        headers = config.headers,
                        environment = config.environment,
                        idleTimeoutMillis = config.idleTimeoutMillis,
                        roundTripTimeoutMillis = config.roundTripTimeoutMillis
                    )
                    val newConnector = OkHttpWebSocketConnector(peerConfig)
                    
                    mutex.withLock {
                        webSocket?.close(1000, "Peer IP changed")
                        webSocket = null
                        isOpen.set(false)
                        connectionJob?.cancel()
                        connectionJob = null
                        currentConnector = newConnector
                    }
                    // Trigger reconnection with new URL
                    ensureConnection()
                } else if (peerUrl != null) {
                    // Peer URL matches lastKnownUrl - ensure it's set (LAN only)
                    lastKnownUrl = peerUrl
                } else {
                    // Peer not in current discovery cache - this is normal if:
                    // 1. Discovery hasn't completed yet (NSD can take a few seconds)
                    // 2. Peer was temporarily removed from cache but we have lastKnownUrl
                    // 3. Network conditions changed but discovery hasn't refreshed yet
                    // Using lastKnownUrl is a valid fallback - connection will work if peer is still reachable
                    if (lastKnownUrl != null) {
                        android.util.Log.d("WebSocketTransportClient", "ℹ️ Target device $targetDeviceId not in discovery cache (${peers.size} peers), using lastKnownUrl: $lastKnownUrl")
                    } else {
                        android.util.Log.w("WebSocketTransportClient", "⚠️ Target device $targetDeviceId not found in discovered peers (${peers.size} peers) and no lastKnownUrl available")
                    }
                }
            }
        } else {
            // Cloud connections: ensure lastKnownUrl is null (should never be set for cloud)
            if (lastKnownUrl != null) {
                android.util.Log.w("WebSocketTransportClient", "⚠️ Cloud connection has lastKnownUrl set ($lastKnownUrl) - clearing it (should always use config.url)")
                lastKnownUrl = null
            }
        }
        
        ensureConnection()
        try {
            sendQueue.send(envelope)
        } catch (e: Exception) {
            android.util.Log.e("WebSocketTransportClient", "❌ Failed to queue envelope: ${e.message}", e)
            throw e
        }
    }
    
    /**
     * Send a control message and wait for response.
     * Returns the response payload as JSONObject, or null if timeout or error.
     */
    suspend fun sendControlMessage(action: String, timeoutMs: Long = 5000): org.json.JSONObject? {
        if (!isConnected()) {
            android.util.Log.w("WebSocketTransportClient", "⚠️ Cannot send control message: not connected")
            return null
        }
        
        val queryId = java.util.UUID.randomUUID().toString()
        val responseDeferred = CompletableDeferred<org.json.JSONObject>()
        pendingControlQueries[queryId] = responseDeferred
        
        try {
            // Create SyncEnvelope with proper Payload structure for control messages
            // Note: deviceId and devicePlatform are optional for control messages
            // The server identifies the device from WebSocket headers (X-Device-Id, X-Device-Platform)
            val envelope = com.hypo.clipboard.sync.SyncEnvelope(
                id = queryId,
                timestamp = java.time.Instant.now().toString(),
                version = "1.0",
                type = com.hypo.clipboard.sync.MessageType.CONTROL,
                payload = com.hypo.clipboard.sync.Payload(
                    deviceId = null,  // Optional for control messages - server uses WebSocket headers
                    devicePlatform = null,  // Optional for control messages - server uses WebSocket headers
                    target = null,  // Control messages don't target specific devices
                    action = action,  // Use action field for control messages
                    message = "Control message: $action",
                    originalMessageId = queryId
                )
            )
            
            // Encode as binary frame (4-byte length + JSON) to match server expectations
            val frame = frameCodec.encode(envelope)
            
            mutex.withLock {
                val socket = webSocket ?: throw IllegalStateException("WebSocket not connected")
                val sent = socket.send(okio.ByteString.of(*frame))
                if (!sent) {
                    throw IOException("websocket send failed")
                }
                touch()
            }
            
            return withTimeout(timeoutMs) {
                responseDeferred.await()
            }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            android.util.Log.w("WebSocketTransportClient", "⚠️ Control message query timed out: $action")
            pendingControlQueries.remove(queryId)
            return null
        } catch (e: Exception) {
            android.util.Log.w("WebSocketTransportClient", "⚠️ Failed to send control message: ${e.message}", e)
            pendingControlQueries.remove(queryId)
            return null
        }
    }
    
    /**
     * Send raw JSON data (for pairing messages that need to be detected by macOS)
     */
    suspend fun sendRawJson(jsonData: ByteArray) {
        ensureConnection()
        
        // Wait for connection to be established (with timeout)
        // Capture the current connectionSignal to avoid race conditions where it might be reassigned
        val signalToWait = mutex.withLock {
            if (connectionSignal.isCompleted) {
                // Connection already established, create a completed deferred
                CompletableDeferred<Unit>().also { it.complete(Unit) }
            } else {
                connectionSignal
            }
        }
        
        try {
            withTimeout(10_000) { // 10 second timeout
                signalToWait.await()
            }
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            // Check if connection is actually established (might have been completed after we captured signal)
            if (!isConnected()) {
                // Re-throw the timeout exception - can't create new TimeoutCancellationException (internal constructor)
                throw e
            }
            // Connection is established, continue
        }
        
        mutex.withLock {
            val socket = webSocket ?: throw IllegalStateException("WebSocket not connected")
            val sent = socket.send(of(*jsonData))
            if (!sent) {
                android.util.Log.w("WebSocketTransportClient", "⚠️ WebSocket send failed in sendRawJson (connection may be closed)")
                throw IOException("websocket send failed")
            }
            touch()
        }
    }

    /**
     * Cancel the connection job without closing the socket.
     * Used when reconnecting during an in-progress connection to avoid "Socket closed" errors.
     * 
     * **CRITICAL: Race Condition Prevention**
     * This function MUST reset `isReconnecting = false` to allow subsequent connection attempts.
     * Without this reset, the flag would remain true and block all future `ensureConnection()` calls,
     * causing the connection to be stuck indefinitely.
     * 
     * **When This Is Called:**
     * - Network change during handshake (see `RelayWebSocketClient.reconnect()`)
     * - Peer IP change during connection setup
     * 
     * **Flag Lifecycle:**
     * 1. `ensureConnection()` sets `isReconnecting = true`
     * 2. Connection job starts, handshake begins
     * 3. Network change triggers this function
     * 4. Job is cancelled, flag is reset here ← CRITICAL!
     * 5. New `ensureConnection()` call can proceed
     * 
     * **Debugging:**
     * If connections get stuck after network changes, check:
     * - Is this function being called? (look for "🛑 Cancelling connection job")
     * - Is `isReconnecting` being reset? (should see flag = false after cancel)
     * - Is a new connection attempt happening? (should see "🔌 ensureConnection() starting")
     */
    suspend fun cancelConnectionJob() {
        mutex.withLock {
            android.util.Log.d("WebSocketTransportClient", "🛑 Cancelling connection job (handshake may be in progress)")
            connectionJob?.cancel()
            connectionJob = null
            handshakeStarted = null
            // CRITICAL: Reset reconnecting flag to allow new connection attempts
            // Without this, all future ensureConnection() calls will be blocked
            isReconnecting = false
            // Don't close socket or set isClosed - let the connection job cleanup handle it
        }
    }

    /**
     * Disconnect the current connection without closing sendQueue.
     * Used for reconnection scenarios where we want to close the socket but keep the client alive.
     * 
     * **CRITICAL: Race Condition Prevention**
     * This function MUST reset `isReconnecting = false` after cancelling the connection job.
     * Without this reset, if `disconnect()` is called while a connection is active (e.g., due to
     * network change), the flag would remain true and block all future connection attempts.
     * 
     * **Difference from `close()`:**
     * - `disconnect()`: Closes socket, keeps sendQueue open (for reconnection)
     * - `close()`: Closes socket AND sendQueue (permanent shutdown)
     * 
     * **When This Is Called:**
     * - Network change on established connection (see `RelayWebSocketClient.reconnect()`)
     * - Manual reconnect triggered by user or network monitor
     * - Connection quality degradation requiring fresh connection
     * 
     * **Flag Lifecycle:**
     * 1. Connection is established, `isReconnecting = false`
     * 2. Network change detected, this function called
     * 3. Connection job cancelled, waits for completion
     * 4. `isReconnecting = false` reset here ← CRITICAL!
     * 5. `isClosed = false` reset to allow reconnection
     * 6. New `ensureConnection()` can proceed
     * 
     * **Debugging:**
     * If reconnection fails after network changes, check:
     * - Is `disconnect()` completing successfully? (look for "🔌 disconnect() called")
     * - Is `connectionJob?.cancelAndJoin()` hanging? (job may be stuck)
     * - Is `isReconnecting` being reset? (should be false after this function)
     * - Is a new connection attempt happening? (should see ensureConnection() logs)
     */
    suspend fun disconnect() {
        android.util.Log.d("WebSocketTransportClient", "🔌 disconnect() called - closing socket but keeping sendQueue open for reconnection")
        mutex.withLock {
            // Check if handshake is in progress - if so, cancel the connection job instead of closing socket
            // Closing socket during handshake causes "Socket closed" errors
            val handshakeInProgress = handshakeStarted != null && !isOpen.get()
            if (handshakeInProgress) {
                android.util.Log.d("WebSocketTransportClient", "🔌 disconnect() called during handshake - cancelling connection job instead of closing socket")
                // Cancel connection job - this will cause runConnectionLoop to exit cleanly
                connectionJob?.cancel()
                // Don't close socket here as it might not be fully established yet
                // The connection job cancellation will handle cleanup
            } else {
                // Handshake complete or no handshake - safe to close socket
                webSocket?.close(1000, "reconnecting")
                webSocket = null
                isOpen.set(false)
            }
            // Mark as closed for connection state, but don't close sendQueue
            isClosed.set(true)
        }
        watchdogJob?.cancelAndJoin()
        watchdogJob = null
        connectionJob?.cancelAndJoin()
        connectionJob = null
        synchronized(pendingLock) { pendingRoundTrips.clear() }
        handshakeStarted = null
        // CRITICAL: Reset flags for reconnection
        // Without this, all future ensureConnection() calls will be blocked
        isReconnecting = false  // Reset reconnecting flag to allow new connection attempts
        // Reset isClosed flag so we can reconnect
        isClosed.set(false)
    }

    suspend fun close() {
        if (isClosed.compareAndSet(false, true)) {
            android.util.Log.d("WebSocketTransportClient", "🔌 close() called - permanently shutting down (closing sendQueue)")
            mutex.withLock {
                // Check if handshake is in progress - if so, cancel the connection job instead of closing socket
                // Closing socket during handshake causes "Socket closed" errors
                val handshakeInProgress = handshakeStarted != null && !isOpen.get()
                if (handshakeInProgress) {
                    android.util.Log.d("WebSocketTransportClient", "🔌 close() called during handshake - cancelling connection job instead of closing socket")
                    // Cancel connection job - this will cause runConnectionLoop to exit cleanly
                    connectionJob?.cancel()
                    // Don't close socket here as it might not be fully established yet
                    // The connection job cancellation will handle cleanup
                } else {
                    // Handshake complete or no handshake - safe to close socket
                    webSocket?.close(1000, "client shutdown")
                    webSocket = null
                    isOpen.set(false)
                }
            }
            sendQueue.close() // Only close sendQueue on permanent shutdown
            watchdogJob?.cancelAndJoin()
            watchdogJob = null
            connectionJob?.cancelAndJoin()
            connectionJob = null
            synchronized(pendingLock) { pendingRoundTrips.clear() }
            handshakeStarted = null
        }
    }

    /**
     * Ensure a connection is established. This is called when sending messages,
     * but can also be called proactively to maintain a connection for receiving messages.
     * Event-driven: for cloud connections, applies exponential backoff based on consecutive failures.
     * 
     * **CRITICAL: Concurrency Control with `isReconnecting` Flag**
     * 
     * This function uses the `isReconnecting` flag to prevent race conditions from concurrent calls.
     * The flag lifecycle is:
     * 1. Check if `isReconnecting == true` → if yes, SKIP (another attempt in progress)
     * 2. Set `isReconnecting = true` (claim exclusive access)
     * 3. Apply backoff delay if previous failures
     * 4. Launch connection job within mutex lock
     * 5. Connection job's `finally` block resets `isReconnecting = false`
     * 
     * **CRITICAL BUG THAT WAS FIXED:**
     * Previous code incorrectly reset `isReconnecting = false` in the "connection already active"
     * branch (line ~622). This created a race window:
     * - Thread A: Sets flag=true, starts job
     * - Thread B: Sees job active, skips, resets flag=false ❌
     * - Thread C: Sees flag=false, starts DUPLICATE job ❌
     * - Result: Multiple overlapping handshakes → stuck forever
     * 
     * **Fix:** Only reset flag in three places:
     * 1. Connection job's `finally` block (normal completion/cancellation)
     * 2. `disconnect()` after cancelling job
     * 3. `cancelConnectionJob()` after cancelling job
     * 4. Exception handler in this function
     * 
     * **Why Multiple Calls Happen:**
     * - Network changes trigger callbacks (WiFi → cellular → WiFi)
     * - App foregrounding/backgrounding
     * - Sending messages while connection in progress
     * - Periodic connection health checks
     * 
     * **Debugging Stuck Connections:**
     * If connection gets stuck in "Connecting..." state:
     * 1. Check if `isReconnecting` is stuck at `true`
     *    → Log: "⏸️ ensureConnection() skipped - reconnection already in progress"
     * 2. Check if connection job is active but not progressing
     *    → Look for "🔌 Connection job started" without "onOpen" or "Handshake exception"
     * 3. Check if network change cancels the stuck job
     *    → Look for "🛑 Cancelling connection job" or "disconnect() called"
     * 4. Verify flag is reset after cancellation
     *    → Should see `isReconnecting = false` in disconnect/cancel logs
     * 
     * **Expected Log Sequence for Successful Connection:**
     * ```
     * 🔌 ensureConnection() starting new connection job
     * 🔌 Connection job started, calling runConnectionLoop()
     * 🚀 Connecting to: wss://hypo.fly.dev/ws (cloud)
     * ☁️ Starting cloud connection - updating state to ConnectingCloud
     * 🔌 Socket created, handshake in progress...
     * ☁️ Cloud connection opened: wss://hypo.fly.dev/ws
     * ☁️ Updating TransportManager state to ConnectedCloud
     * ✅ Handshake signal received, connection established
     * 🔌 Connection job completed and cleared  ← flag reset here
     * ```
     * 
     * **Expected Log Sequence for Network Change During Connection:**
     * ```
     * 🔌 ensureConnection() starting new connection job
     * 🔌 Socket created, handshake in progress...
     * 🔄 Reconnecting cloud WebSocket due to network change  ← external trigger
     * 🛑 Cancelling connection job (handshake may be in progress)  ← flag reset here
     * ⚠️ Handshake cancelled (connection job was cancelled externally)
     * 🔌 Connection loop cancelled (expected during reconnect/shutdown)
     * [500ms delay]
     * 🔌 ensureConnection() starting new connection job  ← new attempt
     * ☁️ Cloud connection opened  ← success!
     * ```
     */
    private suspend fun ensureConnection() {
        val isCloudConnection = config.environment == "cloud"
        
        // Guard against concurrent reconnection attempts
        // Check if reconnection is already in progress (prevents duplicate calls from onClosed/onFailure)
        if (isReconnecting) {
            android.util.Log.d("WebSocketTransportClient", "⏸️ ensureConnection() skipped - reconnection already in progress (isCloud=$isCloudConnection)")
            return
        }
        
        // Set reconnecting flag early to prevent concurrent attempts
        // This flag is checked before backoff delay to prevent multiple coroutines from waiting
        isReconnecting = true
        
        try {
            // Apply exponential backoff before starting connection attempt (for both cloud and LAN)
            if (consecutiveFailures > 0) {
                val backoffDelay = if (consecutiveFailures <= 8) {
                    baseBackoffDelay * (1 shl (consecutiveFailures - 1))
                } else {
                    maxBackoffDelay // Keep retrying every 128s indefinitely
                }
                android.util.Log.d("WebSocketTransportClient", 
                    "⏳ Applying exponential backoff: ${backoffDelay}ms (consecutive failures: $consecutiveFailures, cloud=$isCloudConnection)")
                delay(backoffDelay)
            }
            
            mutex.withLock {
                val urlToUse = if (isCloudConnection) {
                    config.url ?: throw IllegalStateException("Cloud connection config URL cannot be null")
                } else {
                    // For LAN: prefer lastKnownUrl (from discovery), but allow config.url for pairing connections
                    lastKnownUrl ?: config.url
                }
                
                if (connectionJob == null || connectionJob?.isActive != true) {
                    android.util.Log.d("WebSocketTransportClient", "🔌 ensureConnection() starting new connection job (isCloud=$isCloudConnection, url=${urlToUse ?: "null"}, failures=$consecutiveFailures)")
                    // Reset connection signal for new connection attempt
                    if (connectionSignal.isCompleted) {
                        connectionSignal = CompletableDeferred()
                    }
                    val job = scope.launch {
                        try {
                            android.util.Log.d("WebSocketTransportClient", "🔌 Connection job started, calling runConnectionLoop()")
                            runConnectionLoop()
                            // runConnectionLoop() exits when connection closes - event-driven reconnection will handle restart
                            android.util.Log.d("WebSocketTransportClient", "🔌 runConnectionLoop() exited normally")
                        } catch (e: kotlinx.coroutines.CancellationException) {
                            // Cancellation is expected when reconnecting or shutting down
                            // Don't log as error - this is normal lifecycle behavior
                            android.util.Log.d("WebSocketTransportClient", "🔌 Connection loop cancelled (expected during reconnect/shutdown)")
                            throw e // Re-throw to properly propagate cancellation
                        } catch (e: Exception) {
                            android.util.Log.e("WebSocketTransportClient", "❌ Error in connection loop: ${e.message}", e)
                            // Don't increment failure count here - onFailure callback already handles it
                            // This prevents double-counting failures
                            // Event-driven: onClosed/onFailure will trigger ensureConnection() automatically
                        } finally {
                            val current = coroutineContext[Job]
                            mutex.withLock {
                                if (connectionJob === current) {
                                    connectionJob = null
                                    isReconnecting = false  // Reset reconnecting flag when job completes
                                    android.util.Log.d("WebSocketTransportClient", "🔌 Connection job completed and cleared")
                                }
                            }
                        }
                    }
                    connectionJob = job
                    android.util.Log.d("WebSocketTransportClient", "🔌 Starting long-lived connection for receiving messages (event-driven, no polling)")
                    // Keep isReconnecting = true until connection job completes (in finally block)
                    // This prevents duplicate ensureConnection() calls while connection is in progress
                } else {
                    android.util.Log.d("WebSocketTransportClient", "⏸️ ensureConnection() skipped - connection job already active (isCloud=$isCloudConnection)")
                    // Don't reset isReconnecting here - let the active job's finally block handle it
                    // Resetting here creates a race window where another ensureConnection() can slip through
                }
            }
        } catch (e: Exception) {
            // Reset reconnecting flag on error
            isReconnecting = false
            android.util.Log.e("WebSocketTransportClient", "❌ Error in ensureConnection(): ${e.message}", e)
            throw e
        }
    }
    
    /**
     * Start maintaining a persistent connection to receive incoming messages.
     * This should be called when a peer is discovered to ensure we can receive messages.
     * If transportManager is available, it will discover peers and connect to the first discovered peer.
     */
    /**
     * Start maintaining a persistent connection to receive incoming messages.
     * Event-driven: only connects when peer is discovered or connection disconnects.
     * Updates lastKnownUrl when peer is discovered.
     */
    fun startReceiving() {
        val isCloudConnection = config.environment == "cloud"
        android.util.Log.d("WebSocketTransportClient", "   Starting to receive messages...Config URL: ${config.url ?: "null (LAN - will use peer discovery)"}")
        android.util.Log.d("WebSocketTransportClient", "   Is cloud connection: $isCloudConnection")
        android.util.Log.d("WebSocketTransportClient", "   Last known URL: $lastKnownUrl")
        
        scope.launch {
            // Check if this is a cloud relay connection - never switch URLs for cloud connections
            // Note: isCloudConnection is already defined in outer scope, using it here
            
            // If we have a transport manager AND this is NOT a cloud connection, try to discover peers
            if (transportManager != null && !isCloudConnection) {
                val peers = transportManager.currentPeers()
                android.util.Log.d("WebSocketTransportClient", "   Discovered peers: ${peers.size}")
                val allowedIds = allowedDeviceIdsProvider?.invoke() ?: emptySet()
                val filteredPeers = if (allowedIds.isNotEmpty()) {
                    peers.filter { peer ->
                        val id = peer.attributes["device_id"] ?: peer.serviceName
                        allowedIds.any { it.equals(id, ignoreCase = true) }
                    }
                } else peers
                
                val peerList = if (filteredPeers.isNotEmpty()) filteredPeers else peers
                
                if (peerList.isNotEmpty()) {
                    // Use the first allowed peer's IP address
                    val peer = peerList.first()
                    android.util.Log.d("WebSocketTransportClient", "📡 Discovered peer: ${peer.serviceName} at ${peer.host}:${peer.port} (device_id: ${peer.attributes["device_id"]?.take(20) ?: "unknown"})")
                    val peerUrl = when {
                        peer.host != "unknown" && peer.host != "127.0.0.1" -> {
                            "ws://${peer.host}:${peer.port}"
                        }
                        peer.host == "127.0.0.1" -> {
                            // Emulator case: replace localhost with host IP
                            val emulatorHost = "10.0.2.2"
                            "ws://$emulatorHost:${peer.port}"
                        }
                        else -> null
                    }
                    
                    if (peerUrl != null && peerUrl != lastKnownUrl) {
                        android.util.Log.d("WebSocketTransportClient", "🔄 Peer discovered: updating lastKnownUrl to $peerUrl (previous: $lastKnownUrl)")
                        val previousUrl = lastKnownUrl
                        lastKnownUrl = peerUrl
                        val peerConfig = TlsWebSocketConfig(
                            url = peerUrl,
                            fingerprintSha256 = null, // No pinning for ws://
                            headers = config.headers,
                            environment = "lan",
                            idleTimeoutMillis = config.idleTimeoutMillis,
                            roundTripTimeoutMillis = config.roundTripTimeoutMillis
                        )
                        val newConnector = OkHttpWebSocketConnector(peerConfig)
                        
                        mutex.withLock {
                            // Only close existing connection if it's actually open
                            val wasOpen = isOpen.get()
                            val oldSocket = webSocket
                            if (wasOpen && oldSocket != null) {
                                android.util.Log.d("WebSocketTransportClient", "🔌 Closing existing connection to $previousUrl before switching to $peerUrl")
                                try {
                                    oldSocket.close(1000, "Peer IP changed")
                                } catch (e: Exception) {
                                    android.util.Log.w("WebSocketTransportClient", "⚠️ Error closing old socket: ${e.message}")
                                }
                            } else {
                                android.util.Log.d("WebSocketTransportClient", "⏸️ No active connection to close, updating connector for new peer")
                            }
                            // Clear socket reference BEFORE cancelling job to avoid race condition
                            webSocket = null
                            isOpen.set(false)
                            currentConnector = newConnector
                            
                            // Only cancel connection job if we're not in the middle of a handshake
                            // If handshake is in progress, let it complete/fail naturally, then reconnect
                            val handshakeInProgress = handshakeStarted != null
                            if (handshakeInProgress) {
                                android.util.Log.d("WebSocketTransportClient", "⏳ Handshake in progress, will reconnect after current attempt completes")
                                // Don't cancel - let the current attempt finish, then runConnectionLoop will reconnect with new URL
                            } else {
                                android.util.Log.d("WebSocketTransportClient", "🛑 Cancelling connection job (no handshake in progress)")
                                // Cancel job but don't wait for it - let it clean up asynchronously
                                connectionJob?.cancel()
                                connectionJob = null
                            }
                        }
                    } else if (peerUrl != null) {
                        // Peer URL matches lastKnownUrl - ensure it's set
                        lastKnownUrl = peerUrl
                    }
                } else {
                    android.util.Log.d("WebSocketTransportClient", "ℹ️ No peers discovered, will use lastKnownUrl: $lastKnownUrl")
                }
            } else if (isCloudConnection) {
                // For cloud connections, use config URL (lastKnownUrl should be null)
                android.util.Log.d("WebSocketTransportClient", "☁️ Cloud connection detected - using config URL: ${config.url}")
                android.util.Log.d("WebSocketTransportClient", "   Environment: ${config.environment}")
                android.util.Log.d("WebSocketTransportClient", "   Has transportManager: ${transportManager != null}")
                lastKnownUrl = null
                mutex.withLock {
                    // Cloud connections use the connector from DI (which has a valid URL)
                    currentConnector = connector ?: throw IllegalStateException("Cloud connection requires a connector from DI")
                }
            }
            
            // For LAN connections, use lastKnownUrl if available (from discovery), otherwise fall back to config.url (for pairing)
            // For cloud connections, always use config.url
            val urlToUse = if (isCloudConnection) {
                config.url ?: throw IllegalStateException("Cloud connection config URL cannot be null")
            } else {
                // For LAN: prefer lastKnownUrl (from discovery), but allow config.url for pairing connections
                lastKnownUrl ?: config.url
            }
            
            if (urlToUse == null || urlToUse.isBlank()) {
                if (!isCloudConnection) {
                    android.util.Log.d("WebSocketTransportClient", "⏸️ No peer URL available for LAN connection, waiting for discovery event")
                    return@launch
                } else {
                    android.util.Log.e("WebSocketTransportClient", "❌ Cloud connection config URL is empty!")
                    return@launch
                }
            }
            
            android.util.Log.d("WebSocketTransportClient", "🔌 Calling ensureConnection() for URL: $urlToUse (isCloud=${isCloudConnection})")
            ensureConnection()
        }
    }
    
    /**
     * Force an immediate connection attempt (for debugging/testing).
     * Useful for verifying connectivity from ADB or UI.
     */
    fun forceConnectOnce() {
        scope.launch {
            val isCloudConnection = config.environment == "cloud"
            val urlToUse = if (isCloudConnection) {
                config.url ?: throw IllegalStateException("Cloud connection config URL cannot be null")
            } else {
                lastKnownUrl
            }
            
            if (urlToUse == null || urlToUse.isBlank()) {
                android.util.Log.w("WebSocketTransportClient", "⚠️ forceConnectOnce() called but no URL available (isCloud=$isCloudConnection)")
                return@launch
            }
            
            android.util.Log.d("WebSocketTransportClient", "🔌 forceConnectOnce() @${System.currentTimeMillis()} url=$urlToUse")
            ensureConnection()
        }
    }

    /**
     * Establish a long-lived WebSocket connection for receiving messages.
     * Event-driven for LAN: only connects when peer is discovered or connection disconnects.
     * Retry with backoff for cloud: cloud connections should retry since URL is always available.
     * 
     * Note: Despite the name "loop", this is NOT a polling loop. It maintains a single
     * long-lived WebSocket connection and processes incoming messages. The loop only exists
     * to keep the connection alive and handle reconnection on failure.
     */
    private suspend fun runConnectionLoop() {
        val isCloudConnection = config.environment == "cloud"
        android.util.Log.d("WebSocketTransportClient", "🔌 runConnectionLoop() started (isCloud=$isCloudConnection)")
        
        // Check if sendQueue is closed - if so, we can't continue (client is shutting down)
        if (sendQueue.isClosedForReceive) {
            android.util.Log.w("WebSocketTransportClient", "⚠️ sendQueue is closed - client is shutting down, exiting connection loop")
            return
        }
        
        // For LAN connections, use lastKnownUrl if available (from discovery), otherwise fall back to config.url
        // (config.url is used for pairing connections where the URL is explicitly set)
        // For cloud connections, always use config.url
        val urlToUse = if (isCloudConnection) {
            config.url ?: run {
                android.util.Log.e("WebSocketTransportClient", "❌ Cloud connection config URL is null!")
                throw IllegalStateException("Cloud connection config URL cannot be null")
            }
        } else {
            // For LAN: prefer lastKnownUrl (from discovery), but allow config.url for pairing connections
            lastKnownUrl ?: config.url
        }
        
        android.util.Log.d("WebSocketTransportClient", "   urlToUse=$urlToUse, currentConnector=${currentConnector != null}, lastKnownUrl=$lastKnownUrl, config.url=${config.url}")
        
        // For LAN connections, require a URL to be available (either from discovery or from config for pairing)
        if (!isCloudConnection && (urlToUse == null || urlToUse.isBlank())) {
            android.util.Log.d("WebSocketTransportClient", "⏸️ No peer URL available, waiting for discovery event (urlToUse=$urlToUse, config.url=${config.url})")
            return
        }
        
        if (isCloudConnection && (urlToUse == null || urlToUse.isBlank())) {
            android.util.Log.e("WebSocketTransportClient", "❌ Cloud connection config URL is empty!")
            return
        }
        
        // Check if connector is available
        if (isCloudConnection && currentConnector == null) {
            android.util.Log.e("WebSocketTransportClient", "❌ Cloud connection: currentConnector is null! This should have been set in startReceiving()")
            // Try to use the connector from DI
            mutex.withLock {
                currentConnector = connector
            }
            if (currentConnector == null) {
                android.util.Log.e("WebSocketTransportClient", "❌ Cloud connection: connector from DI is also null!")
                return
            }
        }
        
        android.util.Log.d("WebSocketTransportClient", "🚀 Connecting to: $urlToUse${if (isCloudConnection) " (cloud)" else ""}")
        
        // Set ConnectingCloud state when starting a cloud connection attempt
        if (isCloudConnection && transportManager != null) {
            android.util.Log.d("WebSocketTransportClient", "☁️ Starting cloud connection - updating state to ConnectingCloud")
            transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.ConnectingCloud)
        }
        
        val closedSignal = CompletableDeferred<Unit>()
            val handshakeSignal = mutex.withLock {
                if (connectionSignal.isCompleted) {
                    connectionSignal = CompletableDeferred()
                }
                connectionSignal
            }
            val listener = object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    // Use outer scope variables to avoid shadowing
                    val connUrl = if (isCloudConnection) {
                        config.url ?: "unknown"
                    } else {
                        lastKnownUrl ?: "unknown"
                    }
                    val deviceId = config.headers["X-Device-Id"] ?: "unknown"
                    val transportType = if (isCloudConnection) "☁️ Cloud" else "📡 LAN"
                    android.util.Log.d("WebSocketTransportClient", "$transportType connection opened: $connUrl (device: ${deviceId.take(20)}...)")
                    android.util.Log.d("WebSocketTransportClient", "   onOpen callback fired - will update connection state")
                    android.util.Log.d("WebSocketTransportClient", "   isCloudConnection=$isCloudConnection, config.environment=${config.environment}")
                    scope.launch {
                        mutex.withLock {
                            this@WebSocketTransportClient.webSocket = webSocket
                            isOpen.set(true) // Mark as open
                            isClosed.set(false) // Clear closed flag
                            touch()
                            startWatchdog()
                        }
                        
                        // Notify TransportManager of connection state change (event-driven)
                        if (transportManager != null) {
                            // Reset failure count on successful connection (both cloud and LAN)
                            consecutiveFailures = 0
                            if (isCloudConnection) {
                                android.util.Log.d("WebSocketTransportClient", "☁️ Updating TransportManager state to ConnectedCloud, reset failure count")
                                transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.ConnectedCloud)
                            } else {
                                android.util.Log.d("WebSocketTransportClient", "📡 Updating TransportManager state to ConnectedLan")
                                transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.ConnectedLan)
                                
                                // For LAN connections, update lastSuccessfulTransport for the connected peer
                                // This ensures the UI shows the peer as connected
                                // Try to find the device ID from discovered peers matching this connection URL
                                val peers = transportManager.currentPeers()
                                val matchingPeer = peers.find { peer ->
                                    val peerUrl = when {
                                        peer.host != "unknown" && peer.host != "127.0.0.1" -> {
                                            "ws://${peer.host}:${peer.port}"
                                        }
                                        else -> null
                                    }
                                    peerUrl == lastKnownUrl
                                }
                                val peerDeviceId = matchingPeer?.attributes?.get("device_id")
                                
                                if (peerDeviceId != null) {
                                    android.util.Log.d("WebSocketTransportClient", "📡 Updating transport status for peer: $peerDeviceId -> LAN")
                                    transportManager.markDeviceConnected(peerDeviceId, com.hypo.clipboard.transport.ActiveTransport.LAN)
                                } else {
                                    android.util.Log.w("WebSocketTransportClient", "⚠️ Could not find device ID for LAN connection to $lastKnownUrl")
                                }
                            }
                        } else {
                            android.util.Log.w("WebSocketTransportClient", "⚠️ TransportManager is null, cannot update connection state")
                        }
                        val started = handshakeStarted
                        if (started != null) {
                            val duration = Duration.between(started, clock.instant())
                            metricsRecorder.recordHandshake(duration, clock.instant())
                        }
                        handshakeStarted = null
                        
                        // Small delay to ensure backend registration is complete
                        delay(500)
                        
                        // Signal that connection is established
                        if (!handshakeSignal.isCompleted) {
                            handshakeSignal.complete(Unit)
                        }
                    }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    touch()
                    // Check if this is a pairing ACK (text message)
                    val isPairingAck = text.contains("\"challenge_id\"") && 
                                      text.contains("\"responder_device_id\"")
                    if (isPairingAck) {
                        android.util.Log.d("WebSocketTransportClient", "📋 Pairing: ACK received (text)")
                        onPairingAck?.invoke(text)
                        return
                    }
                    // Check if this is a pairing challenge (text message)
                    val isPairingChallenge = text.contains("\"initiator_device_id\"") && 
                                           text.contains("\"initiator_pub_key\"")
                    if (isPairingChallenge) {
                        android.util.Log.d("WebSocketTransportClient", "📋 Pairing: Challenge received (text)")
                        scope.launch {
                            val ackJson = onPairingChallenge?.invoke(text)
                            if (ackJson != null) {
                                try {
                                    webSocket.send(ackJson)
                                    android.util.Log.d("WebSocketTransportClient", "📤 Pairing: ACK sent (${ackJson.length} chars)")
                                } catch (e: Exception) {
                                    android.util.Log.e("WebSocketTransportClient", "❌ Pairing: Failed to send ACK - ${e.message}", e)
                                }
                            } else {
                                android.util.Log.w("WebSocketTransportClient", "⚠️ Pairing: Handler returned null ACK")
                            }
                        }
                        return
                    }
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    touch()
                    // Message received - decode and handle below
                    
                    // Decode the binary frame first (handles 4-byte length prefix)
                    // Then check if it's a pairing message or clipboard message
                    // Extract raw JSON first to check for control responses before decoding
                    // (control responses may contain fields not in Payload struct)
                    val frameJson: String? = try {
                        if (bytes.size >= 4) {
                            val length = java.nio.ByteBuffer.wrap(bytes.toByteArray(), 0, 4).order(java.nio.ByteOrder.BIG_ENDIAN).int
                            if (bytes.size >= 4 + length) {
                                String(bytes.toByteArray(), 4, length, Charsets.UTF_8)
                            } else {
                                android.util.Log.e("WebSocketTransportClient", "❌ Frame size mismatch: expected ${4 + length} bytes, got ${bytes.size}")
                                null
                            }
                        } else {
                            android.util.Log.e("WebSocketTransportClient", "❌ Frame too small: ${bytes.size} bytes, expected at least 4")
                            null
                        }
                    } catch (e: Exception) {
                        android.util.Log.e("WebSocketTransportClient", "❌ Failed to extract JSON from frame: ${e.message}", e)
                        null
                    }
                    
                    if (frameJson == null) {
                        return
                    }
                    
                    // Check if this is a control message response (before decoding as SyncEnvelope)
                    // Control responses may contain fields not in Payload struct (e.g., connected_devices)
                    try {
                        val fullJson = org.json.JSONObject(frameJson)
                        val msgType = fullJson.optString("type", "")
                        if (msgType == "control") {
                            val payloadObj = fullJson.optJSONObject("payload")
                            if (payloadObj != null) {
                                val action = payloadObj.optString("action", "")
                                if (action == "query_connected_peers") {
                                    val originalMessageId = payloadObj.optString("original_message_id", "")
                                    if (originalMessageId.isNotEmpty()) {
                                        pendingControlQueries[originalMessageId]?.complete(payloadObj)
                                        pendingControlQueries.remove(originalMessageId)
                                        android.util.Log.d("WebSocketTransportClient", "✅ Received control message response for query $originalMessageId")
                                        return
                                    }
                                }
                            }
                        }
                    } catch (e: Exception) {
                        // Not a control response or parse failed, continue to normal decoding
                    }
                    
                    try {
                        val envelope = frameCodec.decode(bytes.toByteArray())
                        android.util.Log.d("WebSocketTransportClient", "📥 Received: ${envelope.type} (${bytes.size} bytes, id: ${envelope.id.take(8)}...)")
                        
                        // Check if this is a pairing challenge by looking at envelope payload
                        // Re-encode to JSON string to check for pairing message structure
                        val payloadJson: String? = try {
                            // Re-encode the envelope to get JSON string (for pairing check)
                            val tempFrame = frameCodec.encode(envelope)
                            // Extract JSON from frame (skip 4-byte length prefix)
                            if (tempFrame.size >= 4) {
                                val length = java.nio.ByteBuffer.wrap(tempFrame, 0, 4).order(java.nio.ByteOrder.BIG_ENDIAN).int
                                if (tempFrame.size >= 4 + length) {
                                    String(tempFrame, 4, length, Charsets.UTF_8)
                                } else {
                                    android.util.Log.e("WebSocketTransportClient", "❌ Frame size mismatch: expected ${4 + length} bytes, got ${tempFrame.size}")
                                    null
                                }
                            } else {
                                android.util.Log.e("WebSocketTransportClient", "❌ Frame too small: ${tempFrame.size} bytes, expected at least 4")
                                null
                            }
                        } catch (e: Exception) {
                            android.util.Log.e("WebSocketTransportClient", "❌ Failed to extract JSON from frame for pairing check: ${e.message}. Rejecting message.", e)
                            null
                        }
                        
                        // Fail fast if we couldn't extract JSON
                        if (payloadJson == null) {
                            return
                        }
                        
                        val isPairingChallenge = payloadJson.contains("initiator_device_id") && 
                                                payloadJson.contains("initiator_pub_key")
                        
                        if (isPairingChallenge) {
                            android.util.Log.d("WebSocketTransportClient", "📋 Pairing: Challenge received (binary)")
                            scope.launch {
                                try {
                                    val ackJson = onPairingChallenge?.invoke(payloadJson)
                                    if (ackJson != null) {
                                        try {
                                            webSocket.send(ackJson)
                                            android.util.Log.d("WebSocketTransportClient", "📤 Pairing: ACK sent (${ackJson.length} chars)")
                                        } catch (e: Exception) {
                                            android.util.Log.e("WebSocketTransportClient", "❌ Pairing: Failed to send ACK - ${e.message}", e)
                                        }
                                    } else {
                                        android.util.Log.w("WebSocketTransportClient", "⚠️ Pairing: Handler returned null ACK")
                                    }
                                } catch (e: Exception) {
                                    android.util.Log.e("WebSocketTransportClient", "❌ Pairing: Handler error - ${e.message}", e)
                                }
                            }
                            return
                        }
                        
                        // Not a pairing message, handle as clipboard envelope
                        // (Control messages are already handled before decoding)
                        handleIncoming(bytes)
                    } catch (e: Exception) {
                        android.util.Log.e("WebSocketTransportClient", "❌ Failed to decode frame in onMessage: ${e.message}. Rejecting message.", e)
                        // Don't process invalid messages - fail fast
                        // If this is a legacy format, it should be updated to use proper frame encoding
                    }
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    // Use outer scope variables to avoid shadowing
                    val connUrl = if (isCloudConnection) {
                        config.url ?: "unknown"
                    } else {
                        lastKnownUrl ?: "unknown"
                    }
                    
                    // Interpret close code
                    val closeCodeMsg = when (code) {
                        1000 -> "normalClosure (client or server closed normally)"
                        1001 -> "goingAway (server going down or client navigating away)"
                        1002 -> "protocolError (protocol violation)"
                        1003 -> "unsupportedData (data type not supported)"
                        1005 -> "noStatusReceived (no close code received)"
                        1006 -> "abnormalClosure (connection closed abnormally)"
                        1007 -> "invalidFramePayloadData (invalid payload data)"
                        1008 -> "policyViolation (policy violation)"
                        1009 -> "messageTooBig (message too large)"
                        1010 -> "mandatoryExtensionMissing (mandatory extension missing)"
                        1011 -> "internalServerError (server error)"
                        1015 -> "tlsHandshakeFailure (TLS handshake failed)"
                        else -> "unknown($code)"
                    }
                    
                    // Calculate connection duration and last activity
                    val now = clock.instant()
                    val connectionDuration = if (handshakeStarted != null) {
                        Duration.between(handshakeStarted, now).seconds
                    } else {
                        -1L
                    }
                    val idleTime = Duration.between(lastActivity, now).seconds
                    
                    // Enhanced logging for debugging
                    val likelyServerInitiated = code == 1001 || code == 1006 || code == 1011 || code == 1015
                    val closureType = when {
                        likelyServerInitiated -> "SERVER-initiated"
                        code == 1000 -> "Normal"
                        else -> "CLIENT-initiated"
                    }
                    android.util.Log.w("WebSocketTransportClient", 
                        "🔴 WebSocket closed: code=$code ($closeCodeMsg), reason=$reason, type=$closureType, " +
                        "url=$connUrl, cloud=$isCloudConnection, duration=${connectionDuration}s, idle=${idleTime}s, " +
                        "state=[open=${isOpen.get()}, closed=${isClosed.get()}], " +
                        "signals=[closedSignal=${closedSignal.isCompleted}, sendQueue=${sendQueue.isClosedForReceive}]")
                    
                    isOpen.set(false) // Mark as not open
                    isClosed.set(true) // Mark as closed
                    val signalWasCompleted = closedSignal.isCompleted
                    if (!closedSignal.isCompleted) {
                        closedSignal.complete(Unit)
                    }
                    shutdownSocket(webSocket)
                    
                    // Notify TransportManager of connection state change (event-driven)
                    // Only update connection state for cloud connections - LAN connections don't affect global status
                    if (transportManager != null && isCloudConnection) {
                        // Set state to ConnectingCloud immediately (event-driven reconnection)
                        transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.ConnectingCloud)
                    }
                    
                    android.util.Log.w("WebSocketTransportClient", 
                        "📢 onClosed: completed closedSignal (wasCompleted=$signalWasCompleted), " +
                        "updated TransportManager=${transportManager != null && isCloudConnection}, " +
                        "event-driven reconnection will be triggered")
                    
                    // Event-driven: immediately trigger reconnection for both cloud and LAN connections
                    // Unified reconnection logic - same exponential backoff for both
                    if (!sendQueue.isClosedForReceive) {
                        scope.launch {
                            // Cancel connection job to ensure runConnectionLoop() exits quickly
                            // This allows ensureConnection() to start a new connection attempt
                            mutex.withLock {
                                if (connectionJob?.isActive == true) {
                                    android.util.Log.d("WebSocketTransportClient", "🛑 Cancelling connection job to allow reconnection (cloud=$isCloudConnection)")
                                    connectionJob?.cancel()
                                    connectionJob = null
                                }
                            }
                            // Small delay to ensure cleanup completes
                            delay(100)
                            android.util.Log.d("WebSocketTransportClient", "🔄 Event-driven: triggering ensureConnection() after onClosed (cloud=$isCloudConnection)")
                            ensureConnection()
                        }
                    }
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    // Check if socket was already open when failure occurred (connection reset scenario)
                    val wasOpen = isOpen.get()
                    val isSocketClosed = t is java.net.SocketException && t.message?.contains("closed", ignoreCase = true) == true
                    
                    // If socket was open, this is a connection reset (RST packet) rather than a normal close
                    // OkHttp reports connection resets as onFailure even after onOpen
                    // Treat this as a normal close (similar to onClosed) to avoid unnecessary error handling
                    if (wasOpen || isSocketClosed) {
                        // Simplified log for normal connection resets
                        val connUrl = if (isCloudConnection) {
                            config.url ?: "unknown"
                        } else {
                            lastKnownUrl ?: "unknown"
                        }
                        android.util.Log.d("WebSocketTransportClient", "🔌 Connection reset: $connUrl (${t.javaClass.simpleName}) - reconnecting...")
                        
                        // Mark as closed and complete closedSignal so connection loop exits cleanly
                        isOpen.set(false)
                        isClosed.set(true)
                        if (!closedSignal.isCompleted) {
                            closedSignal.complete(Unit)
                        }
                        shutdownSocket(webSocket)
                        handshakeStarted = null
                        
                        // Update TransportManager state (same as onClosed)
                        if (transportManager != null && isCloudConnection) {
                            // Set state to ConnectingCloud immediately (event-driven reconnection)
                            transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.ConnectingCloud)
                        }
                        
                        // Simplified log - reconnection will be triggered automatically
                        
                        // Event-driven: immediately trigger reconnection for cloud connections
                        // Only trigger if not already reconnecting (prevents duplicate calls)
                        if (isCloudConnection && !sendQueue.isClosedForReceive && !isReconnecting) {
                            scope.launch {
                                // Cancel connection job to ensure runConnectionLoop() exits quickly
                                // This allows ensureConnection() to start a new connection attempt
                                mutex.withLock {
                                    if (connectionJob?.isActive == true) {
                                        connectionJob?.cancel()
                                        connectionJob = null
                                    }
                                }
                                delay(200)
                                ensureConnection()
                            }
                        }
                        
                        // Return early - don't execute the rest of onFailure logic
                        return@onFailure
                    }
                    
                    // Actual connection failure (not a normal reset) - log with details
                    val connUrl = if (isCloudConnection) {
                        config.url ?: "unknown"
                    } else {
                        lastKnownUrl ?: "unknown"
                    }
                    // For LAN connections, timeouts are expected when devices aren't on the same network
                    // Log at debug level to reduce noise
                    if (isCloudConnection) {
                        android.util.Log.w("WebSocketTransportClient", "❌ Connection failed: $connUrl - ${t.message} (${t.javaClass.simpleName})")
                    } else {
                        android.util.Log.d("WebSocketTransportClient", "⏱️ LAN connection timeout (expected when not on same network): $connUrl - ${t.javaClass.simpleName}")
                    }
                    
                    // For LAN connections, if connection is refused, clear lastKnownUrl to force re-discovery
                    // This handles cases where the peer's IP has changed but we haven't re-discovered it yet
                    if (!isCloudConnection && t is ConnectException) {
                        val failedUrl = lastKnownUrl
                        android.util.Log.d("WebSocketTransportClient", "🔍 Connection refused to $failedUrl - clearing lastKnownUrl to force re-discovery")
                        // Launch coroutine to use suspending mutex
                        scope.launch {
                            mutex.withLock {
                                lastKnownUrl = null
                                currentConnector = null
                            }
                        }
                    }
                    
                    // Complete connectionSignal with exception so sendRawJson can see the error
                    if (!handshakeSignal.isCompleted) {
                        handshakeSignal.completeExceptionally(t)
                    }
                    if (!closedSignal.isCompleted) {
                        closedSignal.complete(Unit)
                    }
                    shutdownSocket(webSocket)
                    handshakeStarted = null
                    
                    // Notify TransportManager of connection state change (event-driven)
                    if (transportManager != null && isCloudConnection) {
                        transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.ConnectingCloud)
                        consecutiveFailures++
                        android.util.Log.d("WebSocketTransportClient", "📈 Consecutive failures: $consecutiveFailures")
                    }
                    
                    // Event-driven: immediately trigger reconnection for cloud connections
                    // Only trigger if not already reconnecting (prevents duplicate calls)
                    if (isCloudConnection && !sendQueue.isClosedForReceive && !isReconnecting) {
                        scope.launch {
                            mutex.withLock {
                                if (connectionJob?.isActive == true) {
                                    connectionJob?.cancel()
                                    connectionJob = null
                                }
                            }
                            delay(200)
                            ensureConnection()
                        }
                    }
                    
                    // Re-throw to propagate error
                    if (t is SSLPeerUnverifiedException) {
                        val host = config.url?.let { url ->
                            url.toHttpUrlOrNull()?.host
                                ?: runCatching { URI(url).host }.getOrNull()
                        } ?: "unknown"
                        analytics.record(
                            TransportAnalyticsEvent.PinningFailure(
                                environment = config.environment,
                                host = host,
                                message = t.message,
                                occurredAt = clock.instant()
                            )
                        )
                    }
                }
            }

            handshakeStarted = clock.instant()
            // Debug: Log which connector is being used
            android.util.Log.d("WebSocketTransportClient", "🔌 Connecting using connector for URL: $urlToUse (isCloud=$isCloudConnection)")
            val connectorToUse = currentConnector ?: throw IllegalStateException("WebSocket connector not available (LAN connection requires peer discovery)")
            android.util.Log.d("WebSocketTransportClient", "   Creating WebSocket connection, waiting for onOpen callback...")
            android.util.Log.d("WebSocketTransportClient", "   Connection job active: ${connectionJob?.isActive}, isCancelled: ${connectionJob?.isCancelled}")
            val socket = connectorToUse.connect(listener)
            android.util.Log.d("WebSocketTransportClient", "   Socket created, handshake in progress...")
            val connectTimeoutMillis = if (config.roundTripTimeoutMillis > 0) config.roundTripTimeoutMillis else 10_000L
            android.util.Log.d("WebSocketTransportClient", "   Waiting for handshake to complete (timeout: ${connectTimeoutMillis}ms)...")
            val connected = try {
                withTimeout(connectTimeoutMillis) {
                    handshakeSignal.await()
                    android.util.Log.d("WebSocketTransportClient", "   ✅ Handshake signal received, connection established")
                    true
                }
            } catch (t: Throwable) {
                // Check if this is a cancellation (job was cancelled externally)
                val isCancellation = t is kotlinx.coroutines.CancellationException
                val isTimeout = t is kotlinx.coroutines.TimeoutCancellationException
                
                // For LAN connections, timeouts are expected when devices aren't on the same network
                // Log at debug level to reduce noise, but still log cloud connection failures as errors
                if (isCloudConnection) {
                    android.util.Log.e("WebSocketTransportClient", "   ❌ Handshake exception caught")
                    android.util.Log.e("WebSocketTransportClient", "   Exception type: ${t.javaClass.simpleName}")
                    android.util.Log.e("WebSocketTransportClient", "   Exception message: ${t.message}")
                    android.util.Log.e("WebSocketTransportClient", "   Is cancellation: $isCancellation, Is timeout: $isTimeout")
                    android.util.Log.e("WebSocketTransportClient", "   Connection job state: active=${connectionJob?.isActive}, cancelled=${connectionJob?.isCancelled}")
                    android.util.Log.e("WebSocketTransportClient", "   Socket state: isOpen=${isOpen.get()}, isClosed=${isClosed.get()}")
                } else {
                    // LAN connection timeout - expected when devices aren't on same network
                    android.util.Log.d("WebSocketTransportClient", "   ⏱️ LAN handshake timeout (expected when devices not on same network): ${t.javaClass.simpleName} - ${t.message}")
                }
                
                if (isCancellation && !isTimeout) {
                    android.util.Log.w("WebSocketTransportClient", "   ⚠️ Handshake cancelled (connection job was cancelled externally)")
                    // Don't cancel socket here - the cancellation was intentional (e.g., reconnect called)
                    // The socket will be cleaned up by the cancellation handler
                    // But we should still cancel the socket to clean up resources
                    try {
                        socket.cancel()
                    } catch (e: Exception) {
                        android.util.Log.w("WebSocketTransportClient", "   ⚠️ Error cancelling socket during cancellation: ${e.message}")
                    }
                    shutdownSocket(socket)
                    throw t // Re-throw cancellation to exit the loop
                }
                
                // Timeout or other error - cancel socket to clean up
                if (isCloudConnection) {
                    android.util.Log.e("WebSocketTransportClient", "   ❌ Handshake failed (timeout or error), cancelling socket")
                } else {
                    android.util.Log.d("WebSocketTransportClient", "   ⏱️ LAN handshake failed (timeout), cancelling socket")
                }
                try {
                    socket.cancel()
                    android.util.Log.d("WebSocketTransportClient", "   Socket cancelled successfully")
                } catch (e: Exception) {
                    android.util.Log.w("WebSocketTransportClient", "   ⚠️ Error cancelling socket during handshake failure: ${e.message}")
                    // If socket.cancel() fails, it might already be closed
                    // Check if onFailure was called with "Socket closed"
                    if (e.message?.contains("closed", ignoreCase = true) == true) {
                        android.util.Log.w("WebSocketTransportClient", "   Socket already closed - onFailure may have been called")
                    }
                }
                shutdownSocket(socket)
                
                // Event-driven: exit and let onFailure trigger ensureConnection()
                // Increment failure count for exponential backoff (both cloud and LAN)
                consecutiveFailures++
                if (isCloudConnection) {
                    android.util.Log.w("WebSocketTransportClient", "⚠️ Cloud connection failed, consecutive failures: $consecutiveFailures, exiting (event-driven reconnection will handle retry)")
                } else if (lastKnownUrl == null) {
                    // LAN connections without discovered peer: exit and wait for discovery event
                    android.util.Log.w("WebSocketTransportClient", "⚠️ LAN connection failed, no peer discovered, will reconnect on discovery event")
                } else {
                    android.util.Log.w("WebSocketTransportClient", "⚠️ LAN connection failed, exiting (event-driven reconnection will handle retry)")
                }
                return // Exit - event-driven reconnection will handle retry
            }
            if (!connected) {
                // Connection not established - cancel socket (don't close as it may not be fully established)
                try {
                    socket.cancel()
                } catch (e: Exception) {
                    android.util.Log.w("WebSocketTransportClient", "   ⚠️ Error cancelling socket: ${e.message}")
                }
                shutdownSocket(socket)
                
                // Event-driven: exit and let onFailure trigger ensureConnection()
                // Increment failure count for exponential backoff (both cloud and LAN)
                consecutiveFailures++
                if (isCloudConnection) {
                    android.util.Log.w("WebSocketTransportClient", "⚠️ Cloud connection not established, consecutive failures: $consecutiveFailures, exiting (event-driven reconnection will handle retry)")
                } else if (lastKnownUrl == null) {
                    // LAN connections without discovered peer: exit and wait for discovery event
                    android.util.Log.w("WebSocketTransportClient", "⚠️ LAN connection not established, no peer discovered, will reconnect on discovery event")
                } else {
                    android.util.Log.w("WebSocketTransportClient", "⚠️ LAN connection not established, exiting (event-driven reconnection will handle retry)")
                }
                return // Exit - event-driven reconnection will handle retry
            }
            
            // Connection successful - reset failure count and maintain long-lived connection (both cloud and LAN)
            consecutiveFailures = 0  // Reset on successful connection
            isReconnecting = false  // Reset reconnecting flag on successful connection
            if (isCloudConnection) {
                android.util.Log.d("WebSocketTransportClient", "✅ Long-lived CLOUD connection established (cloud relay), reset failure count")
                // Double-check that state was updated to ConnectedCloud
                if (transportManager != null) {
                    val currentState = transportManager.connectionState.value
                    android.util.Log.d("WebSocketTransportClient", "   Current TransportManager state: $currentState")
                    if (currentState != com.hypo.clipboard.transport.ConnectionState.ConnectedCloud) {
                        android.util.Log.w("WebSocketTransportClient", "   ⚠️ State mismatch! Expected ConnectedCloud but got $currentState - updating now")
                        transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.ConnectedCloud)
                    }
                }
                // Start watchdog for cloud connection to send pings
                android.util.Log.d("WebSocketTransportClient", "   Starting watchdog for cloud connection keepalive")
                startWatchdog()
            } else {
                android.util.Log.d("WebSocketTransportClient", "✅ Long-lived LAN connection established, will only reconnect on IP change or disconnect")
            }

            try {
                loop@ while (true) {
                    // Check closedSignal BEFORE waiting - if already completed, break immediately
                    if (closedSignal.isCompleted) {
                        android.util.Log.w("WebSocketTransportClient", "🔌 closedSignal already completed before waitForEvent, breaking inner loop")
                        break@loop
                    }
                    android.util.Log.d("WebSocketTransportClient", "   Waiting for event (closedSignal completed=${closedSignal.isCompleted})")
                    when (val event = waitForEvent(closedSignal)) {
                        LoopEvent.ChannelClosed -> {
                            socket.close(1000, "channel closed")
                            return
                        }
                        LoopEvent.ConnectionClosed -> {
                            android.util.Log.d("WebSocketTransportClient", "🔌 Inner loop breaking due to ConnectionClosed event")
                            break@loop
                        }
                        is LoopEvent.Envelope -> {
                            android.util.Log.d("WebSocketTransportClient", "📦 Processing envelope: type=${event.envelope.type}, id=${event.envelope.id}, target=${event.envelope.payload.target}")
                            val payload = frameCodec.encode(event.envelope)
                            android.util.Log.d("WebSocketTransportClient", "📤 Encoded frame: ${payload.size} bytes")
                            val now = clock.instant()
                            synchronized(pendingLock) {
                                prunePendingLocked(now)
                                pendingRoundTrips[event.envelope.id] = now
                            }
                            try {
                                val sent = socket.send(of(*payload))
                                if (!sent) {
                                    android.util.Log.w("WebSocketTransportClient", "⚠️ WebSocket send failed, closing connection loop")
                                    break@loop
                                }
                                android.util.Log.d("WebSocketTransportClient", "✅ Frame sent successfully: ${payload.size} bytes")
                            } catch (e: Exception) {
                                android.util.Log.e("WebSocketTransportClient", "❌ WebSocket send exception: ${e.message}", e)
                                break@loop
                            }
                            touch()
                        }
                    }
                }
            } finally {
                val cancelled = coroutineContext[Job]?.isCancelled == true
                val socketWasOpen = isOpen.get()
                android.util.Log.d("WebSocketTransportClient", "🔌 finally block: cancelled=$cancelled, socketWasOpen=$socketWasOpen, isClosed=${isClosed.get()}")
                
                // CRITICAL FIX: Don't close socket if it was successfully opened
                // If socket was opened, onClosed will handle the closure properly
                // Closing an open socket here causes "Socket closed" errors
                if (cancelled) {
                    // Job was cancelled - close socket for cleanup
                    android.util.Log.d("WebSocketTransportClient", "   Job cancelled, closing socket for cleanup")
                    try {
                        socket.close(1000, "connection job cancelled")
                    } catch (e: Exception) {
                        android.util.Log.w("WebSocketTransportClient", "⚠️ Error closing socket in finally (cancelled): ${e.message}")
                    }
                } else if (!socketWasOpen) {
                    // Socket was never opened (handshake failed) - safe to close
                    android.util.Log.d("WebSocketTransportClient", "   Socket never opened (handshake failed), closing")
                    try {
                        socket.close(1000, null)
                    } catch (e: Exception) {
                        android.util.Log.w("WebSocketTransportClient", "⚠️ Error closing socket in finally (not open): ${e.message}")
                    }
                } else {
                    // Socket was opened - don't close it here, let onClosed handle it
                    // Closing an open socket here would cause "Socket closed" errors in onFailure
                    android.util.Log.d("WebSocketTransportClient", "   Socket was opened - skipping close (onClosed will handle it)")
                }
                // Only shutdown socket if it matches the current socket (avoid closing new connection's socket)
                mutex.withLock {
                    if (webSocket === socket) {
                        shutdownSocket(socket)
                    } else {
                        android.util.Log.d("WebSocketTransportClient", "   Socket changed (new connection active), skipping shutdown of old socket")
                    }
                }
            }
            
            // Event-driven: inner loop exited (connection closed) - exit runConnectionLoop()
            // onClosed/onFailure callbacks will trigger ensureConnection() immediately
            android.util.Log.d("WebSocketTransportClient", 
                "🔌 Inner connection loop exited: isCloud=$isCloudConnection, " +
                "sendQueueClosed=${sendQueue.isClosedForReceive}, closedSignal=${closedSignal.isCompleted}, " +
                "isOpen=${isOpen.get()}, isClosed=${isClosed.get()}, " +
                "event-driven reconnection will be triggered by onClosed/onFailure")
            
            // Exit - event-driven reconnection (via onClosed/onFailure) will handle retry
            return
    }

    private suspend fun waitForEvent(closedSignal: CompletableDeferred<Unit>): LoopEvent {
        // Check if closedSignal is already completed BEFORE calling select
        // This ensures we don't get stuck waiting on sendQueue when connection is already closed
        if (closedSignal.isCompleted) {
            android.util.Log.d("WebSocketTransportClient", "   closedSignal already completed, returning ConnectionClosed immediately")
            return LoopEvent.ConnectionClosed
        }
        
        return select {
            sendQueue.onReceiveCatching { result ->
                // Double-check closedSignal after receiving from sendQueue
                // If it completed while we were waiting, prioritize that
                if (closedSignal.isCompleted) {
                    android.util.Log.d("WebSocketTransportClient", "   closedSignal completed while waiting on sendQueue, returning ConnectionClosed")
                    LoopEvent.ConnectionClosed
                } else if (result.isClosed) {
                    LoopEvent.ChannelClosed
                } else {
                    val envelope = result.getOrThrow()
                    LoopEvent.Envelope(envelope)
                }
            }
            closedSignal.onAwait {
                android.util.Log.d("WebSocketTransportClient", "   closedSignal.onAwait triggered")
                LoopEvent.ConnectionClosed
            }
        }
    }

    private fun shutdownSocket(expected: WebSocket? = null) {
        watchdogJob?.cancel()
        watchdogJob = null
        scope.launch {
            mutex.withLock {
                if (expected == null || webSocket === expected) {
                    webSocket = null
                    isOpen.set(false)
                }
            }
        }
    }

    private fun touch() {
        lastActivity = clock.instant()
    }

    private fun startWatchdog() {
        watchdogJob?.cancel()
        val observedJob = connectionJob
        
        // For cloud relay connections, send ping/pong keepalive to prevent Fly.io idle timeout
        // Fly.io idle_timeout is configured to 900 seconds (15 minutes, max allowed) in fly.toml
        // We send pings every 14 minutes (840 seconds) to:
        // 1. Keep connection alive (well before 15-minute timeout)
        // 2. Detect dead connections quickly (within 14 minutes)
        val isCloudRelay = config.environment == "cloud"
        
        if (isCloudRelay) {
            android.util.Log.d("WebSocketTransportClient", "⏰ Starting ping/pong keepalive for cloud relay connection")
            android.util.Log.d("WebSocketTransportClient", "   Sending ping every 14 minutes (840s) - Fly.io timeout: 900s (max)")
            watchdogJob = scope.launch {
                while (isActive) {
                    delay(840_000) // Send ping every 14 minutes (840 seconds) to keep connection alive and detect failures
                    if (!isActive) return@launch
                    val socket = mutex.withLock { webSocket }
                    val isOpenState = isOpen.get()
                    val isClosedState = isClosed.get()
                    val idleTime = Duration.between(lastActivity, clock.instant()).seconds
                    
                    if (socket != null && isOpenState && !isClosedState) {
                        try {
                            // Send explicit ping frame to keep connection alive (OkHttp doesn't auto-send pings)
                            val sent = socket.send(okio.ByteString.EMPTY) // Ping frame
                            if (sent) {
                                touch() // Update last activity on successful ping
                                android.util.Log.d("WebSocketTransportClient", "💓 Cloud ping sent successfully (idle=${idleTime}s)")
                            } else {
                                android.util.Log.w("WebSocketTransportClient", "⚠️ Cloud ping send failed, closing socket to trigger retry")
                                try {
                                    socket.close(1006, "Ping failed")
                                } catch (e: Exception) {
                                    android.util.Log.w("WebSocketTransportClient", "⚠️ Error closing socket after ping failure: ${e.message}")
                                }
                            }
                        } catch (e: Exception) {
                            android.util.Log.w("WebSocketTransportClient", "⚠️ Cloud ping exception: ${e.message}, closing socket to trigger retry")
                            try {
                                socket.close(1006, "Ping failed")
                            } catch (closeException: Exception) {
                                android.util.Log.w("WebSocketTransportClient", "⚠️ Error closing socket after ping exception: ${closeException.message}")
                            }
                        }
                    } else {
                        android.util.Log.w("WebSocketTransportClient", 
                            "⚠️ Connection health check failed: socket=${socket != null}, isOpen=$isOpenState, isClosed=$isClosedState, closing socket")
                        if (socket != null && !isClosedState) {
                            try {
                                socket.close(1006, "Connection health check failed")
                            } catch (e: Exception) {
                                android.util.Log.w("WebSocketTransportClient", "⚠️ Error closing socket after health check failure: ${e.message}")
                            }
                        }
                    }
                }
            }
            return
        }
        
        // For LAN connections, use ping/pong keepalive to prevent idle timeout
        // Send ping every 30 minutes (event-driven, can reconnect when disconnected)
        android.util.Log.d("WebSocketTransportClient", "⏰ Starting ping/pong keepalive for LAN connection")
        android.util.Log.d("WebSocketTransportClient", "   Sending ping every 30 minutes (event-driven, will reconnect on disconnect)")
        watchdogJob = scope.launch {
            while (isActive) {
                delay(1_800_000) // 30 minutes (30 * 60 * 1000 ms)
                if (!isActive) return@launch
                val socket = mutex.withLock { webSocket }
                if (socket != null) {
                    try {
                        val sent = socket.send(okio.ByteString.EMPTY) // Ping frame (same as cloud)
                        if (sent) {
                            touch() // Update last activity on successful ping
                            android.util.Log.d("WebSocketTransportClient", "🏓 LAN ping sent successfully")
                        } else {
                            android.util.Log.w("WebSocketTransportClient", "⚠️ LAN ping send failed, connection may be closed")
                            // If ping fails, the connection is likely dead - disconnect and reconnect
                            socket.close(1001, "ping failed")
                            mutex.withLock {
                                if (webSocket === socket) {
                                    webSocket = null
                                    isOpen.set(false)
                                }
                            }
                            observedJob?.cancel()
                            watchdogJob = null
                            return@launch
                        }
                    } catch (e: Exception) {
                        android.util.Log.w("WebSocketTransportClient", "⚠️ LAN ping failed: ${e.message}, connection may be dead")
                        // If ping fails, the connection is likely dead - disconnect and reconnect
                        socket.close(1001, "ping failed")
                        mutex.withLock {
                            if (webSocket === socket) {
                                webSocket = null
                                isOpen.set(false)
                            }
                        }
                        observedJob?.cancel()
                        watchdogJob = null
                        return@launch
                    }
                } else {
                    // Socket is null, stop watchdog
                    watchdogJob = null
                    return@launch
                }
            }
        }
    }

    private fun handleIncoming(bytes: ByteString) {
        val now = clock.instant()
        android.util.Log.d("WebSocketTransportClient", "🔍 handleIncoming: ${bytes.size} bytes, handler=${onIncomingClipboard != null}, transportOrigin=$transportOrigin")
        
        // Early return if no handler registered - don't decode unnecessarily
        if (onIncomingClipboard == null) {
            return
        }
        
        val messageString = bytes.utf8()
        
        // Try to detect if this is a pairing ACK message (JSON with challenge_id and responder_device_id)
        val isPairingAck = messageString.contains("\"challenge_id\"") && 
                          messageString.contains("\"responder_device_id\"")
        if (isPairingAck) {
            // This looks like a pairing ACK, route it to pairing handler
            android.util.Log.d("WebSocketTransportClient", "📋 Detected pairing ACK message (binary)")
            onPairingAck?.invoke(messageString)
            return
        }
        
        // Try to detect if this is a pairing challenge (JSON with initiator_device_id and initiator_pub_key)
        val isPairingChallenge = messageString.contains("\"initiator_device_id\"") && 
                                messageString.contains("\"initiator_pub_key\"")
        if (isPairingChallenge) {
            // This looks like a pairing challenge, route it to pairing challenge handler
            android.util.Log.d("WebSocketTransportClient", "📋 Detected pairing challenge message (binary)")
            scope.launch {
                val ackJson = onPairingChallenge?.invoke(messageString)
                if (ackJson != null) {
                    android.util.Log.d("WebSocketTransportClient", "📤 Sending pairing ACK response (binary)")
                    mutex.withLock {
                        val socket = webSocket
                        if (socket != null) {
                            try {
                                socket.send(okio.ByteString.of(*ackJson.toByteArray(Charsets.UTF_8)))
                            } catch (e: Exception) {
                                android.util.Log.e("WebSocketTransportClient", "❌ Failed to send pairing ACK: ${e.message}", e)
                            }
                        } else {
                            android.util.Log.w("WebSocketTransportClient", "⚠️ WebSocket is null, cannot send pairing ACK")
                        }
                    }
                } else {
                    android.util.Log.w("WebSocketTransportClient", "⚠️ Pairing challenge handler returned null ACK")
                }
            }
            return
        }
        
        // Otherwise, treat as clipboard envelope
        val envelope = try {
            frameCodec.decode(bytes.toByteArray())
        } catch (e: Exception) {
            android.util.Log.e("WebSocketTransportClient", "❌ Failed to decode frame: ${e.message}", e)
            synchronized(pendingLock) { prunePendingLocked(now) }
            return
        }
        android.util.Log.d("WebSocketTransportClient", "✅ Decoded envelope: type=${envelope.type}, id=${envelope.id.take(8)}...")
        
        // No target filtering - process all messages and verify with UUID/key pairs only
        // The message handler will verify decryption using the sender's device ID and stored keys
        
        val started = synchronized(pendingLock) {
            val removed = pendingRoundTrips.remove(envelope.id)
            prunePendingLocked(now)
            removed
        }
        if (started != null) {
            val duration = Duration.between(started, now)
            metricsRecorder.recordRoundTrip(envelope.id, duration)
        }
        
        // Handle incoming clipboard messages
        if (envelope.type == com.hypo.clipboard.sync.MessageType.CLIPBOARD) {
            android.util.Log.d("WebSocketTransportClient", "📋 Invoking onIncomingClipboard handler: origin=$transportOrigin")
            onIncomingClipboard?.invoke(envelope, transportOrigin)
        } else if (envelope.type == com.hypo.clipboard.sync.MessageType.ERROR) {
            // Handle error messages from backend
            val errorCode = envelope.payload.code
            val errorMessage = envelope.payload.message
            val targetDeviceId = envelope.payload.targetDeviceId
            
            android.util.Log.e("WebSocketTransportClient", "❌ Sync error: code=$errorCode, message=$errorMessage, target=$targetDeviceId")
            
            // Invoke error handler with device ID (handler will resolve device name)
            if (!targetDeviceId.isNullOrEmpty() && !errorMessage.isNullOrEmpty()) {
                onSyncError?.invoke(targetDeviceId, errorMessage)
            } else {
                android.util.Log.w("WebSocketTransportClient", "⚠️ Error message missing target_device_id or message")
            }
        } else {
            android.util.Log.w("WebSocketTransportClient", "⚠️ Received non-clipboard message type: ${envelope.type}")
        }
    }

    private fun prunePendingLocked(reference: Instant) {
        if (pendingTtl.isZero || pendingTtl.isNegative) {
            pendingRoundTrips.clear()
            return
        }
        val cutoff = reference.minus(pendingTtl)
        val iterator = pendingRoundTrips.entries.iterator()
        while (iterator.hasNext()) {
            val entry = iterator.next()
            if (entry.value.isBefore(cutoff)) {
                iterator.remove()
            }
        }
    }

}


private fun fingerprintToPin(hex: String): String {
    val normalized = hex.replace(Regex("[^0-9a-fA-F]"), "").lowercase()
    require(normalized.length % 2 == 0) { "hex fingerprint must have even length" }
    val bytes = ByteArray(normalized.length / 2)
    for (index in bytes.indices) {
        val chunk = normalized.substring(index * 2, index * 2 + 2)
        bytes[index] = chunk.toInt(16).toByte()
    }
    return ByteString.of(*bytes).base64()
}
