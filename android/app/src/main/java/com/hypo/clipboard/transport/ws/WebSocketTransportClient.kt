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
    @Volatile private var connectionSignal = CompletableDeferred<Unit>()
    @Volatile private var currentConnector: WebSocketConnector? = connector // Nullable for LAN (created after discovery)
    @Volatile private var lastKnownUrl: String? = null  // Use only lastKnownUrl - updated when peer is discovered
    private var allowedDeviceIdsProvider: (() -> Set<String>)? = null
    
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
        // Resolve target device's IP address from discovered peers
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
                    "ws://${peer.host}:${peer.port}"
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
                // Peer IP changed - update lastKnownUrl and trigger reconnection
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
                // Peer URL matches lastKnownUrl - ensure it's set
                lastKnownUrl = peerUrl
            } else {
                android.util.Log.w("WebSocketTransportClient", "⚠️ Target device $targetDeviceId not found in discovered peers, using lastKnownUrl: $lastKnownUrl")
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
     * Send raw JSON data (for pairing messages that need to be detected by macOS)
     */
    suspend fun sendRawJson(jsonData: ByteArray) {
        ensureConnection()
        
        // Wait for connection to be established (with timeout) - let timeout propagate
        withTimeout(10_000) { // 10 second timeout
            connectionSignal.await()
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
     */
    suspend fun cancelConnectionJob() {
        mutex.withLock {
            android.util.Log.d("WebSocketTransportClient", "🛑 Cancelling connection job (handshake may be in progress)")
            connectionJob?.cancel()
            connectionJob = null
            handshakeStarted = null
            // Don't close socket or set isClosed - let the connection job cleanup handle it
        }
    }

    suspend fun close() {
        if (isClosed.compareAndSet(false, true)) {
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
            sendQueue.close()
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
     */
    private suspend fun ensureConnection() {
        mutex.withLock {
            val isCloudConnection = config.environment == "cloud"
            val urlToUse = if (isCloudConnection) {
                config.url ?: throw IllegalStateException("Cloud connection config URL cannot be null")
            } else {
                lastKnownUrl
            }
            
            if (connectionJob == null || connectionJob?.isActive != true) {
                android.util.Log.d("WebSocketTransportClient", "🔌 ensureConnection() starting new connection job (isCloud=$isCloudConnection, url=${urlToUse ?: "null"})")
                // Reset connection signal for new connection attempt
                if (connectionSignal.isCompleted) {
                    connectionSignal = CompletableDeferred()
                }
                val job = scope.launch {
                    try {
                        android.util.Log.d("WebSocketTransportClient", "🔌 Connection job started, calling runConnectionLoop()")
                        runConnectionLoop()
                    } catch (e: Exception) {
                        android.util.Log.e("WebSocketTransportClient", "❌ Error in connection loop: ${e.message}", e)
                    } finally {
                        val current = coroutineContext[Job]
                        mutex.withLock {
                            if (connectionJob === current) {
                                connectionJob = null
                                android.util.Log.d("WebSocketTransportClient", "🔌 Connection job completed and cleared")
                            }
                        }
                    }
                }
                connectionJob = job
                android.util.Log.d("WebSocketTransportClient", "🔌 Starting long-lived connection for receiving messages (event-driven, no polling)")
            } else {
                android.util.Log.d("WebSocketTransportClient", "⏸️ ensureConnection() skipped - connection job already active (isCloud=$isCloudConnection)")
            }
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
                            if (wasOpen) {
                                android.util.Log.d("WebSocketTransportClient", "🔌 Closing existing connection to $previousUrl before switching to $peerUrl")
                                webSocket?.close(1000, "Peer IP changed")
                            } else {
                                android.util.Log.d("WebSocketTransportClient", "⏸️ No active connection to close, updating connector for new peer")
                            }
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
            
            // For LAN connections, only connect if we have a discovered peer URL
            // For cloud connections, use config.url
            val urlToUse = if (isCloudConnection) {
                config.url ?: throw IllegalStateException("Cloud connection config URL cannot be null")
            } else {
                lastKnownUrl
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
        
        // For LAN connections, only connect if we have a discovered peer URL
        // For cloud connections, use config.url
        val urlToUse = if (isCloudConnection) {
            config.url ?: throw IllegalStateException("Cloud connection config URL cannot be null")
        } else {
            lastKnownUrl
        }
        
        // For LAN connections, never use the default config.url - only connect when we have a discovered peer URL
        // The config.url is only for DI initialization and will never be used for actual connections
        if (!isCloudConnection && (urlToUse == null || urlToUse.isBlank() || (config.url != null && urlToUse == config.url))) {
            android.util.Log.d("WebSocketTransportClient", "⏸️ No peer URL available, waiting for discovery event (urlToUse=$urlToUse, config.url=${config.url})")
            return
        }
        
        if (isCloudConnection && (urlToUse == null || urlToUse.isBlank())) {
            android.util.Log.e("WebSocketTransportClient", "❌ Cloud connection config URL is empty!")
            return
        }
        
        var retryCount = 0
        val maxRetryDelay = 128_000L // 128 seconds max delay (after exponential backoff)
        val baseRetryDelay = 1_000L // 1 second base delay
        
        while (!sendQueue.isClosedForReceive) {
            android.util.Log.d("WebSocketTransportClient", "🚀 Connecting to: $urlToUse${if (isCloudConnection) " (cloud, attempt ${retryCount + 1})" else ""}")
            
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
                            if (isCloudConnection) {
                                android.util.Log.d("WebSocketTransportClient", "☁️ Updating TransportManager state to ConnectedCloud")
                                transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.ConnectedCloud)
                            } else {
                                android.util.Log.d("WebSocketTransportClient", "📡 Updating TransportManager state to ConnectedLan")
                                transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.ConnectedLan)
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
                    // Use outer scope variables to avoid shadowing
                    val connUrl = if (isCloudConnection) {
                        config.url ?: "unknown"
                    } else {
                        lastKnownUrl ?: "unknown"
                    }
                    touch()
                    // Message received - decode and handle below
                    
                    // Decode the binary frame first (handles 4-byte length prefix)
                    // Then check if it's a pairing message or clipboard message
                    try {
                        val envelope = frameCodec.decode(bytes.toByteArray())
                        android.util.Log.d("WebSocketTransportClient", "📥 Received: ${envelope.type} (${bytes.size} bytes, id: ${envelope.id.take(8)}...)")
                        
                        // Check if this is a pairing challenge by looking at envelope payload
                        // Re-encode to JSON string to check for pairing message structure
                        val payloadJson = try {
                            // Re-encode the envelope to get JSON string (for pairing check)
                            val tempFrame = frameCodec.encode(envelope)
                            // Extract JSON from frame (skip 4-byte length prefix)
                            if (tempFrame.size >= 4) {
                                val length = java.nio.ByteBuffer.wrap(tempFrame, 0, 4).order(java.nio.ByteOrder.BIG_ENDIAN).int
                                if (tempFrame.size >= 4 + length) {
                                    String(tempFrame, 4, length, Charsets.UTF_8)
                                } else {
                                    envelope.payload.toString() // Fallback
                                }
                            } else {
                                envelope.payload.toString() // Fallback
                            }
                        } catch (e: Exception) {
                            envelope.payload.toString() // Fallback
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
                        handleIncoming(bytes)
                    } catch (e: Exception) {
                        android.util.Log.e("WebSocketTransportClient", "❌ Failed to decode frame in onMessage: ${e.message}", e)
                        // Fallback: try to handle as raw bytes (might be legacy format)
                    handleIncoming(bytes)
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
                    android.util.Log.w("WebSocketTransportClient", "🔴 WebSocket closed:")
                    android.util.Log.w("WebSocketTransportClient", "   Close code: $code ($closeCodeMsg)")
                    android.util.Log.w("WebSocketTransportClient", "   Reason: $reason")
                    android.util.Log.w("WebSocketTransportClient", "   URL: $connUrl")
                    android.util.Log.w("WebSocketTransportClient", "   Is cloud: $isCloudConnection")
                    android.util.Log.w("WebSocketTransportClient", "   Connection duration: ${connectionDuration}s")
                    android.util.Log.w("WebSocketTransportClient", "   Last activity: ${idleTime}s ago")
                    android.util.Log.w("WebSocketTransportClient", "   Is open state: ${isOpen.get()}")
                    android.util.Log.w("WebSocketTransportClient", "   Is closed state: ${isClosed.get()}")
                    
                    // Determine if this was likely server-initiated or client-initiated
                    val likelyServerInitiated = code == 1001 || code == 1006 || code == 1011 || code == 1015
                    if (likelyServerInitiated) {
                        android.util.Log.w("WebSocketTransportClient", "   ⚠️ Likely SERVER-initiated closure (code $code)")
                    } else if (code == 1000) {
                        android.util.Log.w("WebSocketTransportClient", "   ℹ️ Normal closure (could be client or server)")
                    } else {
                        android.util.Log.w("WebSocketTransportClient", "   ℹ️ Likely CLIENT-initiated closure (code $code)")
                    }
                    
                    isOpen.set(false) // Mark as not open
                    isClosed.set(true) // Mark as closed
                    if (!closedSignal.isCompleted) {
                        closedSignal.complete(Unit)
                    }
                    shutdownSocket(webSocket)
                    
                    // Notify TransportManager of connection state change (event-driven)
                    // Only update connection state for cloud connections - LAN connections don't affect global status
                    if (transportManager != null && isCloudConnection) {
                        transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.Idle)
                    }
                    
                    // Trigger reconnection - event-driven, only if we have a URL
                    if (lastKnownUrl != null || isCloudConnection) {
                        scope.launch {
                            delay(100)
                            ensureConnection()
                        }
                    }
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    // Detailed error logging - use outer scope variables to avoid shadowing
                    val connUrl = if (isCloudConnection) {
                        config.url ?: "unknown"
                    } else {
                        lastKnownUrl ?: "unknown"
                    }
                    val errorMsg = buildString {
                        append("❌ Connection failed to $connUrl: ${t.message}")
                        append(" (${t.javaClass.simpleName})")
                        if (response != null) {
                            append(" - HTTP ${response.code} ${response.message}")
                            try {
                                val body = response.body?.string()
                                if (body != null && body.length < 200) {
                                    append(" - $body")
                                }
                            } catch (e: Exception) {
                                // Ignore body read errors
                            }
                        }
                    }
                    android.util.Log.e("WebSocketTransportClient", errorMsg, t)
                    
                    // Check if socket was already open when failure occurred
                    val wasOpen = isOpen.get()
                    android.util.Log.e("WebSocketTransportClient", "   Socket state: isOpen=$wasOpen, isClosed=${isClosed.get()}")
                    android.util.Log.e("WebSocketTransportClient", "   Handshake state: handshakeStarted=${handshakeStarted != null}")
                    
                    // If socket was open, this is a connection reset (RST packet) rather than a normal close
                    // OkHttp reports connection resets as onFailure even after onOpen
                    // Treat this as a normal close (similar to onClosed) to avoid unnecessary error handling
                    if (wasOpen) {
                        android.util.Log.w("WebSocketTransportClient", "   ⚠️ Connection reset by server (RST packet) - treating as normal close")
                        android.util.Log.w("WebSocketTransportClient", "   This is normal when server closes connection abruptly (e.g., macOS connection.cancel())")
                        
                        // Mark as closed and complete closedSignal so connection loop exits cleanly
                        isOpen.set(false)
                        isClosed.set(true)
                        if (!closedSignal.isCompleted) {
                            closedSignal.complete(Unit)
                        }
                        
                        // Don't trigger reconnection immediately - let the normal reconnection logic handle it
                        // Just update state and let shutdownSocket handle cleanup
                        shutdownSocket(webSocket)
                        handshakeStarted = null
                        
                        // Update TransportManager state (same as onClosed)
                        if (transportManager != null && isCloudConnection) {
                            transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.Idle)
                        }
                        
                        // Trigger reconnection after a delay (same as onClosed)
                        if (lastKnownUrl != null || isCloudConnection) {
                            scope.launch {
                                delay(100)
                                ensureConnection()
                            }
                        }
                        
                        // Return early - don't execute the rest of onFailure logic
                        return@onFailure
                    }
                    
                    // For LAN connections, if connection is refused, clear lastKnownUrl to force re-discovery
                    // This handles cases where the peer's IP has changed but we haven't re-discovered it yet
                    if (!isCloudConnection && t is ConnectException) {
                        val failedUrl = lastKnownUrl
                        android.util.Log.w("WebSocketTransportClient", "🔍 Connection refused to $failedUrl - clearing lastKnownUrl to force re-discovery")
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
                    // isCloudConnection already declared above
                    if (transportManager != null) {
                        // Only update to Idle if this was the cloud connection
                        // LAN connections might still have other peers available
                        if (isCloudConnection) {
                            transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.Idle)
                        }
                    }
                    
                    // Trigger reconnection on failure - event-driven, only if we have a URL
                    // For LAN, if lastKnownUrl was cleared, wait for next discovery event
                    if (lastKnownUrl != null || isCloudConnection) {
                        scope.launch {
                            delay(100)
                            ensureConnection()
                        }
                    } else {
                        android.util.Log.d("WebSocketTransportClient", "⏸️ Waiting for peer discovery before retrying LAN connection")
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
            val socket = connectorToUse.connect(listener)
            val connectTimeoutMillis = if (config.roundTripTimeoutMillis > 0) config.roundTripTimeoutMillis else 10_000L
            android.util.Log.d("WebSocketTransportClient", "   Waiting for handshake to complete (timeout: ${connectTimeoutMillis}ms)...")
            val connected = try {
                withTimeout(connectTimeoutMillis) {
                    handshakeSignal.await()
                    android.util.Log.d("WebSocketTransportClient", "   ✅ Handshake signal received, connection established")
                    true
                }
            } catch (t: Throwable) {
                android.util.Log.e("WebSocketTransportClient", "   ❌ Handshake timeout or error: ${t.message}", t)
                // Connection failed - cancel socket (don't close as it may not be fully established)
                // socket.cancel() is safer than socket.close() during handshake
                try {
                    socket.cancel()
                } catch (e: Exception) {
                    android.util.Log.w("WebSocketTransportClient", "   ⚠️ Error cancelling socket during handshake failure: ${e.message}")
                }
                shutdownSocket(socket)
                
                if (isCloudConnection) {
                    // Cloud connections: retry with exponential backoff
                    retryCount++
                    val retryDelay = if (retryCount <= 8) {
                        baseRetryDelay * (1 shl (retryCount - 1))
                    } else {
                        maxRetryDelay // Keep retrying every 128s indefinitely
                    }
                    android.util.Log.w("WebSocketTransportClient", "⚠️ Cloud connection failed, retrying in ${retryDelay}ms (attempt $retryCount)")
                    delay(retryDelay)
                    continue
                } else if (lastKnownUrl != null) {
                    // LAN connections with discovered peer: retry with exponential backoff (shorter max delay)
                    retryCount++
                    val maxLanRetryDelay = 32_000L // 32 seconds max for LAN (shorter than cloud)
                    val retryDelay = if (retryCount <= 6) {
                        baseRetryDelay * (1 shl (retryCount - 1))
                    } else {
                        maxLanRetryDelay // Keep retrying every 32s for LAN
                    }
                    android.util.Log.w("WebSocketTransportClient", "⚠️ LAN connection failed to discovered peer, retrying in ${retryDelay}ms (attempt $retryCount)")
                    delay(retryDelay)
                    continue
                } else {
                    // LAN connections without discovered peer: exit and wait for discovery event
                    android.util.Log.w("WebSocketTransportClient", "⚠️ LAN connection failed, no peer discovered, will reconnect on discovery event")
                    return // Exit loop - will reconnect when peer is discovered
                }
            }
            if (!connected) {
                // Connection not established - cancel socket (don't close as it may not be fully established)
                try {
                    socket.cancel()
                } catch (e: Exception) {
                    android.util.Log.w("WebSocketTransportClient", "   ⚠️ Error cancelling socket: ${e.message}")
                }
                shutdownSocket(socket)
                
                if (isCloudConnection) {
                    // Cloud connections: retry with exponential backoff
                    retryCount++
                    val retryDelay = if (retryCount <= 8) {
                        baseRetryDelay * (1 shl (retryCount - 1))
                    } else {
                        maxRetryDelay
                    }
                    android.util.Log.w("WebSocketTransportClient", "⚠️ Cloud connection not established, retrying in ${retryDelay}ms (attempt $retryCount)")
                    delay(retryDelay)
                    continue
                } else if (lastKnownUrl != null) {
                    // LAN connections with discovered peer: retry with exponential backoff (shorter max delay)
                    retryCount++
                    val maxLanRetryDelay = 32_000L // 32 seconds max for LAN (shorter than cloud)
                    val retryDelay = if (retryCount <= 6) {
                        baseRetryDelay * (1 shl (retryCount - 1))
                    } else {
                        maxLanRetryDelay
                    }
                    android.util.Log.w("WebSocketTransportClient", "⚠️ LAN connection not established to discovered peer, retrying in ${retryDelay}ms (attempt $retryCount)")
                    delay(retryDelay)
                    continue
                } else {
                    // LAN connections without discovered peer: exit and wait for discovery event
                    android.util.Log.w("WebSocketTransportClient", "⚠️ LAN connection not established, no peer discovered, will reconnect on discovery event")
                    return // Exit loop - will reconnect when peer is discovered
                }
            }
            
            // Connection successful - reset retry count and maintain long-lived connection
            retryCount = 0
            if (isCloudConnection) {
                android.util.Log.d("WebSocketTransportClient", "✅ Long-lived CLOUD connection established (cloud relay)")
                // Double-check that state was updated to ConnectedCloud
                if (transportManager != null) {
                    val currentState = transportManager.connectionState.value
                    android.util.Log.d("WebSocketTransportClient", "   Current TransportManager state: $currentState")
                    if (currentState != com.hypo.clipboard.transport.ConnectionState.ConnectedCloud) {
                        android.util.Log.w("WebSocketTransportClient", "   ⚠️ State mismatch! Expected ConnectedCloud but got $currentState - updating now")
                        transportManager.updateConnectionState(com.hypo.clipboard.transport.ConnectionState.ConnectedCloud)
                    }
                }
            } else {
                android.util.Log.d("WebSocketTransportClient", "✅ Long-lived LAN connection established, will only reconnect on IP change or disconnect")
            }

            try {
                loop@ while (true) {
                    when (val event = waitForEvent(closedSignal)) {
                        LoopEvent.ChannelClosed -> {
                            socket.close(1000, "channel closed")
                            return
                        }
                        LoopEvent.ConnectionClosed -> {
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
                            val sent = socket.send(of(*payload))
                            if (!sent) {
                                android.util.Log.w("WebSocketTransportClient", "⚠️ WebSocket send failed, closing connection loop")
                                break@loop
                            }
                            android.util.Log.d("WebSocketTransportClient", "✅ Frame sent successfully: ${payload.size} bytes")
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
                shutdownSocket(socket)
            }
        }
    }

    private suspend fun waitForEvent(closedSignal: CompletableDeferred<Unit>): LoopEvent {
        return select {
            sendQueue.onReceiveCatching { result ->
                if (result.isClosed) {
                    LoopEvent.ChannelClosed
                } else {
                    val envelope = result.getOrThrow()
                    LoopEvent.Envelope(envelope)
                }
            }
            closedSignal.onAwait {
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
        
        // For cloud relay connections, use ping/pong keepalive instead of idle timeout
        val isCloudRelay = config.environment == "cloud"
        
        if (isCloudRelay) {
            android.util.Log.d("WebSocketTransportClient", "⏰ Starting keepalive watchdog for cloud relay connection")
            android.util.Log.d("WebSocketTransportClient", "   Note: OkHttp handles ping/pong automatically at protocol level")
            android.util.Log.d("WebSocketTransportClient", "   Watchdog will monitor connection health and log activity")
            watchdogJob = scope.launch {
                while (isActive) {
                    delay(30_000) // Check every 30 seconds (OkHttp handles ping/pong automatically)
                    if (!isActive) return@launch
                    val socket = mutex.withLock { webSocket }
                    val isOpenState = isOpen.get()
                    val isClosedState = isClosed.get()
                    val idleTime = Duration.between(lastActivity, clock.instant()).seconds
                    
                    if (socket != null && isOpenState && !isClosedState) {
                        android.util.Log.d("WebSocketTransportClient", "💓 Connection health check: socket exists, isOpen=$isOpenState, idle=${idleTime}s")
                        // OkHttp handles ping/pong automatically - we just monitor connection health
                        // If connection is still open, update last activity to reflect we're monitoring
                        touch()
                    } else {
                        android.util.Log.w("WebSocketTransportClient", "⚠️ Connection health check failed: socket=${socket != null}, isOpen=$isOpenState, isClosed=$isClosedState")
                    }
                }
            }
            return
        }
        
        // For LAN connections, use ping/pong keepalive (same as cloud) to prevent idle timeout
        // Send ping every 20 seconds to keep connection alive
        android.util.Log.d("WebSocketTransportClient", "⏰ Starting ping/pong keepalive for LAN connection")
        watchdogJob = scope.launch {
            while (isActive) {
                delay(20_000) // 20 seconds, same as cloud
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

private sealed interface LoopEvent {
    data object ChannelClosed : LoopEvent
    data object ConnectionClosed : LoopEvent
    data class Envelope(val envelope: SyncEnvelope) : LoopEvent
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
