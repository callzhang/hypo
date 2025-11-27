package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.sync.SyncEnvelope
import com.hypo.clipboard.sync.SyncTransport
import com.hypo.clipboard.transport.NoopTransportAnalytics
import com.hypo.clipboard.transport.NoopTransportMetricsRecorder
import com.hypo.clipboard.transport.TransportAnalytics
import com.hypo.clipboard.transport.TransportAnalyticsEvent
import com.hypo.clipboard.transport.TransportMetricsRecorder
import java.io.IOException
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
        val normalizedUrl = normalizeWebSocketUrl(config.url)
        val url = normalizedUrl.toHttpUrl()
        val builder = baseClient.newBuilder()
        // Only apply certificate pinning for secure connections (wss:// -> https://)
        // Skip pinning for non-secure connections (ws:// -> http://)
        val isSecure = config.url.startsWith("wss://", ignoreCase = true)
        if (isSecure && config.fingerprintSha256?.takeIf { it.isNotBlank() } != null) {
            val hex = config.fingerprintSha256!!
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

    override fun connect(listener: WebSocketListener): WebSocket {
        return client.newWebSocket(request, listener)
    }

    companion object {
        fun hexToPin(hex: String): String = fingerprintToPin(hex)

        private fun normalizeWebSocketUrl(rawUrl: String): String {
            val trimmed = rawUrl.trim()
            return when {
                trimmed.startsWith("wss://", ignoreCase = true) -> "https://" + trimmed.substring(6)
                trimmed.startsWith("ws://", ignoreCase = true) -> "http://" + trimmed.substring(5)
                else -> trimmed
            }
        }
    }
}

class LanWebSocketClient @Inject constructor(
    private val config: TlsWebSocketConfig,
    private val connector: WebSocketConnector,
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
    @Volatile private var currentConnector: WebSocketConnector = connector
    @Volatile private var currentUrl: String = config.url
    @Volatile private var lastKnownUrl: String? = null  // Cache last known URL for paired devices when discovery fails
    private var allowedDeviceIdsProvider: (() -> Set<String>)? = null
    
    // Determine transport origin based on URL (cloud relay URLs contain "fly.dev" or are wss://)
    private val transportOrigin: com.hypo.clipboard.domain.model.TransportOrigin = 
        if (config.url.contains("fly.dev", ignoreCase = true) || config.url.startsWith("wss://", ignoreCase = true)) {
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
                // For cloud connections, also verify we're connected to the cloud URL
                // (not a LAN connection that was switched)
                val isCloudConnection = config.url.contains("fly.dev", ignoreCase = true) || config.url.startsWith("wss://", ignoreCase = true)
                if (isCloudConnection) {
                    // For cloud, verify current URL matches config URL (cloud URL)
                    val isCloudUrl = currentUrl.contains("fly.dev", ignoreCase = true) || currentUrl.startsWith("wss://", ignoreCase = true)
                    if (!isCloudUrl) {
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
            
            if (peerUrl != null && peerUrl != currentUrl) {
                // Create new connector with peer's URL
                // For LAN connections (ws://), skip certificate pinning (no TLS)
                // Only use certificate pinning for secure connections (wss://)
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
                    webSocket?.close(1000, "Switching to peer IP")
                    webSocket = null
                    isOpen.set(false)
                    connectionJob?.cancel()
                    connectionJob = null
                    currentConnector = newConnector
                    currentUrl = peerUrl
                }
            } else if (peerUrl == null) {
                android.util.Log.w("LanWebSocketClient", "⚠️ Target device $targetDeviceId not found in discovered peers, using default config URL")
            }
        }
        
        android.util.Log.d("LanWebSocketClient", "📤 send() called: type=${envelope.type}, target=${envelope.payload.target}, id=${envelope.id}")
        ensureConnection()
        try {
            sendQueue.send(envelope)
            android.util.Log.d("LanWebSocketClient", "✅ Envelope queued: ${envelope.id}")
        } catch (e: Exception) {
            android.util.Log.e("LanWebSocketClient", "❌ send(): Failed to send envelope to queue: ${e.message}", e)
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
                android.util.Log.w("LanWebSocketClient", "⚠️ WebSocket send failed in sendRawJson (connection may be closed)")
                throw IOException("websocket send failed")
            }
            touch()
        }
    }

    suspend fun close() {
        if (isClosed.compareAndSet(false, true)) {
            mutex.withLock {
                webSocket?.close(1000, "client shutdown")
                webSocket = null
                isOpen.set(false)
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
            if (connectionJob == null || connectionJob?.isActive != true) {
                // Reset connection signal for new connection attempt
                if (connectionSignal.isCompleted) {
                    connectionSignal = CompletableDeferred()
                }
                val job = scope.launch {
                    try {
                        runConnectionLoop()
                    } finally {
                        val current = coroutineContext[Job]
                        mutex.withLock {
                            if (connectionJob === current) {
                                connectionJob = null
                            }
                        }
                    }
                }
                connectionJob = job
                android.util.Log.d("LanWebSocketClient", "🔌 Started connection loop for receiving messages")
            }
        }
    }
    
    /**
     * Start maintaining a persistent connection to receive incoming messages.
     * This should be called when a peer is discovered to ensure we can receive messages.
     * If transportManager is available, it will discover peers and connect to the first discovered peer.
     */
    fun startReceiving() {
        android.util.Log.d("LanWebSocketClient", "👂 Starting to receive messages...")
        android.util.Log.d("LanWebSocketClient", "   Config URL: ${config.url}")
        android.util.Log.d("LanWebSocketClient", "   Current URL: $currentUrl")
        android.util.Log.d("LanWebSocketClient", "   Transport origin: $transportOrigin")
        android.util.Log.d("LanWebSocketClient", "   Has transportManager: ${transportManager != null}")
        
        scope.launch {
            // Check if this is a cloud relay connection - never switch URLs for cloud connections
            val isCloudConnection = config.url.contains("fly.dev", ignoreCase = true) || config.url.startsWith("wss://", ignoreCase = true)
            
            // If we have a transport manager AND this is NOT a cloud connection, try to discover peers
            if (transportManager != null && !isCloudConnection) {
                val peers = transportManager.currentPeers()
                android.util.Log.d("LanWebSocketClient", "   Discovered peers: ${peers.size}")
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
                    val peerUrl = when {
                        peer.host != "unknown" && peer.host != "127.0.0.1" -> {
                            "ws://${peer.host}:${peer.port}"
                        }
                        peer.host == "127.0.0.1" -> {
                            // Emulator case: replace localhost with host IP
                            val emulatorHost = "10.0.2.2"
                            "ws://$emulatorHost:${peer.port}"
                        }
                        else -> {
                            android.util.Log.w("LanWebSocketClient", "⚠️ Peer has invalid host: ${peer.host}, using default URL")
                            currentUrl
                        }
                    }
                    
                    if (peerUrl != currentUrl && peerUrl.startsWith("ws://", ignoreCase = true)) {
                        android.util.Log.d("LanWebSocketClient", "   Updating URL to discovered peer: $peerUrl")
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
                            webSocket?.close(1000, "Switching to discovered peer")
                            webSocket = null
                            isOpen.set(false)
                            connectionJob?.cancel()
                            connectionJob = null
                            currentConnector = newConnector
                            currentUrl = peerUrl
                        }
                    }
                } else {
                    android.util.Log.w("LanWebSocketClient", "⚠️ No peers discovered, using default URL: $currentUrl")
                    // Even if no peers are discovered, still try to maintain connection
                    // The connection loop will retry and reconnect when peers are discovered
                    android.util.Log.d("LanWebSocketClient", "   Will maintain connection loop to reconnect when peers are discovered")
                }
            } else if (isCloudConnection) {
                // For cloud connections, ensure we're using the config URL (never switch to LAN)
                android.util.Log.d("LanWebSocketClient", "   Cloud connection detected - using config URL: ${config.url}")
                mutex.withLock {
                    if (currentUrl != config.url) {
                        android.util.Log.w("LanWebSocketClient", "   ⚠️ URL mismatch! Resetting to config URL: ${config.url}")
                        currentUrl = config.url
                        currentConnector = connector
                    }
                }
            }
            
            android.util.Log.d("LanWebSocketClient", "🔌 Calling ensureConnection() for URL: $currentUrl")
            ensureConnection()
        }
    }
    
    /**
     * Force an immediate connection attempt (for debugging/testing).
     * Useful for verifying connectivity from ADB or UI.
     */
    fun forceConnectOnce() {
        scope.launch {
            android.util.Log.d("LanWebSocketClient", "🔌 forceConnectOnce() @${System.currentTimeMillis()} url=$currentUrl")
            ensureConnection()
        }
    }

    private suspend fun runConnectionLoop() {
        var retryCount = 0
        val maxRetryDelay = 128_000L // 128 seconds max delay (after exponential backoff)
        val baseRetryDelay = 1_000L // 1 second base delay
        
        while (!sendQueue.isClosedForReceive) {
            // Before each connection attempt, check if we should update URL based on discovered peers
            if (transportManager != null) {
                val isCloudConnection = config.url.contains("fly.dev", ignoreCase = true) || config.url.startsWith("wss://", ignoreCase = true)
                if (!isCloudConnection) {
                    val peers = transportManager.currentPeers()
                    val allowedIds = allowedDeviceIdsProvider?.invoke() ?: emptySet()
                    val filteredPeers = if (allowedIds.isNotEmpty()) {
                        peers.filter { peer ->
                            val id = peer.attributes["device_id"] ?: peer.serviceName
                            allowedIds.any { it.equals(id, ignoreCase = true) }
                        }
                    } else peers
                    
                    val peerList = if (filteredPeers.isNotEmpty()) filteredPeers else peers
                    
                    if (peerList.isNotEmpty()) {
                        val peer = peerList.first()
                        val peerUrl = when {
                            peer.host != "unknown" && peer.host != "127.0.0.1" -> {
                                "ws://${peer.host}:${peer.port}"
                            }
                            peer.host == "127.0.0.1" -> {
                                val emulatorHost = "10.0.2.2"
                                "ws://$emulatorHost:${peer.port}"
                            }
                            else -> null
                        }
                        
                        if (peerUrl != null && peerUrl != currentUrl) {
                            android.util.Log.d("LanWebSocketClient", "🔄 Updating URL to discovered peer: $peerUrl (was: $currentUrl)")
                            // Cache the successful peer URL for future use when discovery fails
                            lastKnownUrl = peerUrl
                            val peerConfig = TlsWebSocketConfig(
                                url = peerUrl,
                                fingerprintSha256 = null,
                                headers = config.headers,
                                environment = "lan",
                                idleTimeoutMillis = config.idleTimeoutMillis,
                                roundTripTimeoutMillis = config.roundTripTimeoutMillis
                            )
                            val newConnector = OkHttpWebSocketConnector(peerConfig)
                            
                            mutex.withLock {
                                webSocket?.close(1000, "Switching to discovered peer")
                                webSocket = null
                                isOpen.set(false)
                                currentConnector = newConnector
                                currentUrl = peerUrl
                            }
                        }
                    } else {
                        // No peers discovered - use last known URL if available and we have paired devices
                        val allowedIds = allowedDeviceIdsProvider?.invoke() ?: emptySet()
                        if (allowedIds.isNotEmpty() && lastKnownUrl != null && lastKnownUrl != currentUrl && lastKnownUrl != config.url) {
                            android.util.Log.d("LanWebSocketClient", "🔄 No peers discovered, but ${allowedIds.size} paired device(s) exist - using last known URL: $lastKnownUrl")
                            val peerConfig = TlsWebSocketConfig(
                                url = lastKnownUrl!!,
                                fingerprintSha256 = null,
                                headers = config.headers,
                                environment = "lan",
                                idleTimeoutMillis = config.idleTimeoutMillis,
                                roundTripTimeoutMillis = config.roundTripTimeoutMillis
                            )
                            val newConnector = OkHttpWebSocketConnector(peerConfig)
                            
                            mutex.withLock {
                                webSocket?.close(1000, "Switching to last known peer URL")
                                webSocket = null
                                isOpen.set(false)
                                currentConnector = newConnector
                                currentUrl = lastKnownUrl!!
                            }
                        }
                    }
                }
            }
            
            android.util.Log.d("LanWebSocketClient", "🚀 connection attempt #${retryCount + 1} url=$currentUrl")
            
            val closedSignal = CompletableDeferred<Unit>()
            val handshakeSignal = mutex.withLock {
                if (connectionSignal.isCompleted) {
                    connectionSignal = CompletableDeferred()
                }
                connectionSignal
            }
            val listener = object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    android.util.Log.i("LanWebSocketClient", "✅ WebSocket connection opened: $currentUrl")
                    android.util.Log.i("LanWebSocketClient", "   Device ID registered with backend: ${config.headers["X-Device-Id"]}")
                    android.util.Log.d("LanWebSocketClient", "   Response headers: ${response.headers}")
                    android.util.Log.d("LanWebSocketClient", "   Config URL: ${config.url}")
                    android.util.Log.d("LanWebSocketClient", "   WebSocket instance: ${webSocket.hashCode()}")
                    android.util.Log.d("LanWebSocketClient", "   Response code: ${response.code}")
                    android.util.Log.d("LanWebSocketClient", "   Response message: ${response.message}")
                    scope.launch {
                        mutex.withLock {
                            this@LanWebSocketClient.webSocket = webSocket
                            isOpen.set(true) // Mark as open
                            isClosed.set(false) // Clear closed flag
                            touch()
                            startWatchdog()
                        }
                        val started = handshakeStarted
                        if (started != null) {
                            val duration = Duration.between(started, clock.instant())
                            metricsRecorder.recordHandshake(duration, clock.instant())
                        }
                        handshakeStarted = null
                        
                        // Small delay to ensure backend registration is complete
                        // This helps avoid race conditions where messages are sent
                        // before the backend has fully registered the connection
                        delay(500) // 500ms delay
                        android.util.Log.d("LanWebSocketClient", "   Backend registration should be complete, connection ready")
                        
                        // Signal that connection is established
                        if (!handshakeSignal.isCompleted) {
                            handshakeSignal.complete(Unit)
                        } else {
                            android.util.Log.w("LanWebSocketClient", "onOpen: connectionSignal already completed")
                        }
                    }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    touch()
                    // Check if this is a pairing ACK (text message)
                    val isPairingAck = text.contains("\"challenge_id\"") && 
                                      text.contains("\"responder_device_id\"")
                    if (isPairingAck) {
                        android.util.Log.d("LanWebSocketClient", "📋 Detected pairing ACK message (text)")
                        onPairingAck?.invoke(text)
                        return
                    }
                    // Check if this is a pairing challenge (text message)
                    val isPairingChallenge = text.contains("\"initiator_device_id\"") && 
                                           text.contains("\"initiator_pub_key\"")
                    if (isPairingChallenge) {
                        android.util.Log.d("LanWebSocketClient", "📋 Detected pairing challenge message (text)")
                        scope.launch {
                            val ackJson = onPairingChallenge?.invoke(text)
                            if (ackJson != null) {
                                android.util.Log.d("LanWebSocketClient", "📤 Sending pairing ACK response (text)")
                                try {
                                    webSocket.send(ackJson)
                                } catch (e: Exception) {
                                    android.util.Log.e("LanWebSocketClient", "❌ Failed to send pairing ACK: ${e.message}", e)
                                }
                            } else {
                                android.util.Log.w("LanWebSocketClient", "⚠️ Pairing challenge handler returned null ACK")
                            }
                        }
                        return
                    }
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    android.util.Log.e("LanWebSocketClient", "🔥🔥🔥 onMessage() CALLED! ${bytes.size} bytes from $currentUrl")
                    touch()
                    android.util.Log.i("LanWebSocketClient", "📥 Received binary message: ${bytes.size} bytes from URL: $currentUrl")
                    
                    // Decode the binary frame first (handles 4-byte length prefix)
                    // Then check if it's a pairing message or clipboard message
                    try {
                        val envelope = frameCodec.decode(bytes.toByteArray())
                        android.util.Log.d("LanWebSocketClient", "✅ Decoded envelope: type=${envelope.type}, id=${envelope.id.take(8)}...")
                        
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
                        android.util.Log.d("LanWebSocketClient", "   Pairing challenge check: isPairingChallenge=$isPairingChallenge")
                        
                        if (isPairingChallenge) {
                            android.util.Log.d("LanWebSocketClient", "📋 Detected pairing challenge message (binary in onMessage)")
                            scope.launch {
                                try {
                                    android.util.Log.d("LanWebSocketClient", "   Calling onPairingChallenge handler...")
                                    val ackJson = onPairingChallenge?.invoke(payloadJson)
                                    android.util.Log.d("LanWebSocketClient", "   Handler returned: ackJson=${if (ackJson != null) "${ackJson.length} chars" else "null"}")
                                    if (ackJson != null) {
                                        android.util.Log.d("LanWebSocketClient", "📤 Sending pairing ACK response (binary in onMessage)")
                                        android.util.Log.d("LanWebSocketClient", "   ACK JSON: $ackJson")
                                        try {
                                            val sent = webSocket.send(ackJson)
                                            android.util.Log.d("LanWebSocketClient", "   ACK send result: $sent")
                                        } catch (e: Exception) {
                                            android.util.Log.e("LanWebSocketClient", "❌ Failed to send pairing ACK: ${e.message}", e)
                                        }
                                    } else {
                                        android.util.Log.w("LanWebSocketClient", "⚠️ Pairing challenge handler returned null ACK")
                                    }
                                } catch (e: Exception) {
                                    android.util.Log.e("LanWebSocketClient", "❌ Error in pairing challenge handler: ${e.message}", e)
                                }
                            }
                            return
                        }
                        
                        // Not a pairing message, handle as clipboard envelope
                        handleIncoming(bytes)
                    } catch (e: Exception) {
                        android.util.Log.e("LanWebSocketClient", "❌ Failed to decode frame in onMessage: ${e.message}", e)
                        // Fallback: try to handle as raw bytes (might be legacy format)
                        handleIncoming(bytes)
                    }
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    android.util.Log.w("LanWebSocketClient", "🔴 WebSocket closed: code=$code, reason=$reason, url=$currentUrl")
                    isOpen.set(false) // Mark as not open
                    isClosed.set(true) // Mark as closed
                    if (!closedSignal.isCompleted) {
                        closedSignal.complete(Unit)
                    }
                    shutdownSocket(webSocket)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    // Detailed error logging
                    val errorMsg = buildString {
                        append("❌ Connection failed to $currentUrl: ${t.message}")
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
                    android.util.Log.e("LanWebSocketClient", errorMsg, t)
                    
                    // Complete connectionSignal with exception so sendRawJson can see the error
                    if (!handshakeSignal.isCompleted) {
                        handshakeSignal.completeExceptionally(t)
                    }
                    if (!closedSignal.isCompleted) {
                        closedSignal.complete(Unit)
                    }
                    shutdownSocket(webSocket)
                    handshakeStarted = null
                    // Re-throw to propagate error
                    if (t is SSLPeerUnverifiedException) {
                        val host = config.url.toHttpUrlOrNull()?.host
                            ?: runCatching { URI(config.url).host }.getOrNull()
                            ?: "unknown"
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
            android.util.Log.d("LanWebSocketClient", "🔌 Connecting using connector for URL: $currentUrl")
            val socket = currentConnector.connect(listener)
            val connectTimeoutMillis = if (config.roundTripTimeoutMillis > 0) config.roundTripTimeoutMillis else 10_000L
            val connected = try {
                withTimeout(connectTimeoutMillis) {
                    handshakeSignal.await()
                    true
                }
            } catch (t: Throwable) {
                // Error already logged in onFailure, just cancel and retry with backoff
                socket.cancel()
                shutdownSocket(socket)
                retryCount++
                // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, 64s, 128s, then keep at 128s
                val retryDelay = if (retryCount <= 8) {
                    baseRetryDelay * (1 shl (retryCount - 1))
                } else {
                    maxRetryDelay // Keep retrying every 128s indefinitely
                }
                android.util.Log.w("LanWebSocketClient", "⚠️ Connection failed, retrying in ${retryDelay}ms (attempt $retryCount)")
                delay(retryDelay)
                continue
            }
            if (!connected) {
                android.util.Log.w("LanWebSocketClient", "⚠️ Connection not established, retrying...")
                socket.cancel()
                shutdownSocket(socket)
                retryCount++
                // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 32s, 64s, 128s, then keep at 128s
                val retryDelay = if (retryCount <= 8) {
                    baseRetryDelay * (1 shl (retryCount - 1))
                } else {
                    maxRetryDelay // Keep retrying every 128s indefinitely
                }
                android.util.Log.w("LanWebSocketClient", "⚠️ Connection not established, retrying in ${retryDelay}ms (attempt $retryCount)")
                delay(retryDelay)
                continue
            }
            
            // Connection successful, reset retry count
            retryCount = 0

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
                            android.util.Log.d("LanWebSocketClient", "📦 Processing envelope: type=${event.envelope.type}, id=${event.envelope.id}, target=${event.envelope.payload.target}")
                            val payload = frameCodec.encode(event.envelope)
                            android.util.Log.d("LanWebSocketClient", "📤 Encoded frame: ${payload.size} bytes")
                            val now = clock.instant()
                            synchronized(pendingLock) {
                                prunePendingLocked(now)
                                pendingRoundTrips[event.envelope.id] = now
                            }
                            val sent = socket.send(of(*payload))
                            if (!sent) {
                                android.util.Log.w("LanWebSocketClient", "⚠️ WebSocket send failed, closing connection loop")
                                break@loop
                            }
                            android.util.Log.d("LanWebSocketClient", "✅ Frame sent successfully: ${payload.size} bytes")
                            touch()
                        }
                    }
                }
            } finally {
                val cancelled = coroutineContext[Job]?.isCancelled == true
                if (!cancelled) {
                    socket.close(1000, null)
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
        val isCloudRelay = config.url.contains("fly.dev", ignoreCase = true) || config.url.startsWith("wss://", ignoreCase = true)
        
        if (isCloudRelay) {
            android.util.Log.d("LanWebSocketClient", "⏰ Starting ping/pong keepalive for cloud relay connection")
            watchdogJob = scope.launch {
                while (isActive) {
                    delay(20_000) // 20 seconds, same as macOS
                    if (!isActive) return@launch
                    val socket = mutex.withLock { webSocket }
                    if (socket != null) {
                        try {
                            val sent = socket.send(okio.ByteString.EMPTY) // Ping frame
                            if (sent) {
                                android.util.Log.d("LanWebSocketClient", "🏓 Ping sent to keep connection alive")
                                touch()
                            } else {
                                android.util.Log.w("LanWebSocketClient", "⚠️ Ping send failed, connection may be closed")
                            }
                        } catch (e: Exception) {
                            android.util.Log.w("LanWebSocketClient", "⚠️ Ping failed: ${e.message}, connection may be dead")
                        }
                    }
                }
            }
            return
        }
        
        // For LAN connections, use idle timeout
        watchdogJob = scope.launch {
            val timeout = Duration.ofMillis(config.idleTimeoutMillis)
            while (isActive) {
                delay(timeout.toMillis())
                val elapsed = Duration.between(lastActivity, clock.instant())
                if (elapsed >= timeout) {
                    val socket = mutex.withLock { webSocket }
                    socket?.close(1001, "idle timeout")
                    if (socket != null) {
                        mutex.withLock {
                            if (webSocket === socket) {
                                webSocket = null
                                isOpen.set(false)
                            }
                        }
                    }
                    observedJob?.cancel()
                    watchdogJob = null
                    return@launch
                }
            }
        }
    }

    private fun handleIncoming(bytes: ByteString) {
        val now = clock.instant()
        android.util.Log.i("LanWebSocketClient", "🔍 handleIncoming: ${bytes.size} bytes, handler=${onIncomingClipboard != null}, transportOrigin=$transportOrigin")
        
        val messageString = bytes.utf8()
        
        // Try to detect if this is a pairing ACK message (JSON with challenge_id and responder_device_id)
        val isPairingAck = messageString.contains("\"challenge_id\"") && 
                          messageString.contains("\"responder_device_id\"")
        if (isPairingAck) {
            // This looks like a pairing ACK, route it to pairing handler
            android.util.Log.d("LanWebSocketClient", "📋 Detected pairing ACK message (binary)")
            onPairingAck?.invoke(messageString)
            return
        }
        
        // Try to detect if this is a pairing challenge (JSON with initiator_device_id and initiator_pub_key)
        val isPairingChallenge = messageString.contains("\"initiator_device_id\"") && 
                                messageString.contains("\"initiator_pub_key\"")
        if (isPairingChallenge) {
            // This looks like a pairing challenge, route it to pairing challenge handler
            android.util.Log.d("LanWebSocketClient", "📋 Detected pairing challenge message (binary)")
            scope.launch {
                val ackJson = onPairingChallenge?.invoke(messageString)
                if (ackJson != null) {
                    android.util.Log.d("LanWebSocketClient", "📤 Sending pairing ACK response (binary)")
                    mutex.withLock {
                        val socket = webSocket
                        if (socket != null) {
                            try {
                                socket.send(okio.ByteString.of(*ackJson.toByteArray(Charsets.UTF_8)))
                            } catch (e: Exception) {
                                android.util.Log.e("LanWebSocketClient", "❌ Failed to send pairing ACK: ${e.message}", e)
                            }
                        } else {
                            android.util.Log.w("LanWebSocketClient", "⚠️ WebSocket is null, cannot send pairing ACK")
                        }
                    }
                } else {
                    android.util.Log.w("LanWebSocketClient", "⚠️ Pairing challenge handler returned null ACK")
                }
            }
            return
        }
        
        // Otherwise, treat as clipboard envelope
        val envelope = try {
            frameCodec.decode(bytes.toByteArray())
        } catch (e: Exception) {
            android.util.Log.e("LanWebSocketClient", "❌ Failed to decode frame: ${e.message}", e)
            synchronized(pendingLock) { prunePendingLocked(now) }
            return
        }
        android.util.Log.d("LanWebSocketClient", "✅ Decoded envelope: type=${envelope.type}, id=${envelope.id.take(8)}...")
        
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
            android.util.Log.d("LanWebSocketClient", "📋 Invoking onIncomingClipboard handler: origin=$transportOrigin")
            onIncomingClipboard?.invoke(envelope, transportOrigin)
        } else {
            android.util.Log.w("LanWebSocketClient", "⚠️ Received non-clipboard message type: ${envelope.type}")
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
