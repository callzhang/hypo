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
    @Volatile private var handshakeStarted: Instant? = null
    private val pendingLock = Any()
    private val pendingRoundTrips = mutableMapOf<String, Instant>()
    private val pendingTtl = Duration.ofMillis(max(0L, config.roundTripTimeoutMillis))
    private var onIncomingClipboard: ((SyncEnvelope, com.hypo.clipboard.domain.model.TransportOrigin) -> Unit)? = null
    private var onPairingAck: ((String) -> Unit)? = null  // ACK as JSON string
    @Volatile private var connectionSignal = CompletableDeferred<Unit>()
    @Volatile private var currentConnector: WebSocketConnector = connector
    @Volatile private var currentUrl: String = config.url
    
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
    
    /**
     * Check if the WebSocket is currently connected.
     * This is used to determine connection status in the UI.
     */
    fun isConnected(): Boolean {
        return mutex.tryLock().let { locked ->
            try {
                webSocket != null && !isClosed.get()
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
            }
        }
    }

    private suspend fun runConnectionLoop() {
        var retryCount = 0
        val maxRetryDelay = 30_000L // 30 seconds max delay
        val baseRetryDelay = 1_000L // 1 second base delay
        
        while (!sendQueue.isClosedForReceive) {
            val closedSignal = CompletableDeferred<Unit>()
            val handshakeSignal = mutex.withLock {
                if (connectionSignal.isCompleted) {
                    connectionSignal = CompletableDeferred()
                }
                connectionSignal
            }
            val listener = object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    android.util.Log.d("LanWebSocketClient", "✅ WebSocket connection opened: $currentUrl")
                    scope.launch {
                        mutex.withLock {
                            this@LanWebSocketClient.webSocket = webSocket
                            touch()
                            startWatchdog()
                        }
                        val started = handshakeStarted
                        if (started != null) {
                            val duration = Duration.between(started, clock.instant())
                            metricsRecorder.recordHandshake(duration, clock.instant())
                        }
                        handshakeStarted = null
                        
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
                    if (text.contains("\"challenge_id\"") && text.contains("\"mac_device_id\"")) {
                        onPairingAck?.invoke(text)
                        return
                    }
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    touch()
                    handleIncoming(bytes)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
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
                val retryDelay = minOf(baseRetryDelay * (1 shl min(retryCount - 1, 5)), maxRetryDelay)
                delay(retryDelay)
                continue
            }
            if (!connected) {
                android.util.Log.w("LanWebSocketClient", "⚠️ Connection not established, retrying...")
                socket.cancel()
                shutdownSocket(socket)
                retryCount++
                val retryDelay = minOf(baseRetryDelay * (1 shl min(retryCount - 1, 5)), maxRetryDelay)
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
        
        // Try to detect if this is a pairing ACK message (JSON with challenge_id and mac_device_id)
        val messageString = bytes.utf8()
        if (messageString.contains("\"challenge_id\"") && messageString.contains("\"mac_device_id\"")) {
            // This looks like a pairing ACK, route it to pairing handler
            onPairingAck?.invoke(messageString)
            return
        }
        
        // Otherwise, treat as clipboard envelope
        val envelope = try {
            frameCodec.decode(bytes.toByteArray())
        } catch (_: Exception) {
            synchronized(pendingLock) { prunePendingLocked(now) }
            return
        }
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
            onIncomingClipboard?.invoke(envelope, transportOrigin)
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
