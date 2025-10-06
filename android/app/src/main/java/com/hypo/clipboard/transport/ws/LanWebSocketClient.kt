package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.sync.SyncEnvelope
import com.hypo.clipboard.sync.SyncTransport
import com.hypo.clipboard.transport.NoopTransportMetricsRecorder
import com.hypo.clipboard.transport.TransportMetricsRecorder
import java.io.IOException
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.CertificatePinner
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.of

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
        val url = config.url.toHttpUrl()
        val builder = baseClient.newBuilder()
        config.fingerprintSha256?.let { hex ->
            val pin = hexToPin(hex)
            val pinner = CertificatePinner.Builder()
                .add(url.host, "sha256/$pin")
                .build()
            builder.certificatePinner(pinner)
        }
        client = builder.build()
        val requestBuilder = Request.Builder().url(url)
        config.headers.forEach { (key, value) ->
            requestBuilder.addHeader(key, value)
        }
        request = requestBuilder.build()
    }

    override fun connect(listener: WebSocketListener): WebSocket {
        return client.newWebSocket(request, listener)
    }

    companion object {
        fun hexToPin(hex: String): String = fingerprintToPin(hex)
    }
}

class LanWebSocketClient @Inject constructor(
    private val config: TlsWebSocketConfig,
    private val connector: WebSocketConnector,
    private val frameCodec: TransportFrameCodec = TransportFrameCodec(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val clock: Clock = Clock.systemUTC(),
    private val metricsRecorder: TransportMetricsRecorder = NoopTransportMetricsRecorder
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

    override suspend fun send(envelope: SyncEnvelope) {
        ensureConnection()
        sendQueue.send(envelope)
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
                connectionJob = scope.launch {
                    runConnectionLoop()
                }
            }
        }
    }

    private suspend fun runConnectionLoop() {
        val listener = object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
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
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                touch()
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                touch()
                handleIncoming(bytes)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                shutdownSocket()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                shutdownSocket()
                handshakeStarted = null
            }
        }

        handshakeStarted = clock.instant()
        val socket = connector.connect(listener)
        try {
            while (true) {
                val envelope = sendQueue.receive()
                val payload = frameCodec.encode(envelope)
                synchronized(pendingLock) { pendingRoundTrips[envelope.id] = clock.instant() }
                val sent = socket.send(of(*payload))
                if (!sent) {
                    throw IOException("websocket send failed")
                }
                touch()
            }
        } catch (closed: ClosedReceiveChannelException) {
            socket.close(1000, "channel closed")
        } catch (ex: Exception) {
            socket.close(1011, ex.message ?: "send failure")
            throw ex
        } finally {
            shutdownSocket()
        }
    }

    private fun shutdownSocket() {
        watchdogJob?.cancel()
        watchdogJob = null
        scope.launch {
            mutex.withLock {
                webSocket = null
            }
        }
    }

    private fun touch() {
        lastActivity = clock.instant()
    }

    private fun startWatchdog() {
        watchdogJob?.cancel()
        watchdogJob = scope.launch {
            val timeout = Duration.ofMillis(config.idleTimeoutMillis)
            while (true) {
                delay(timeout.toMillis())
                val elapsed = Duration.between(lastActivity, clock.instant())
                if (elapsed >= timeout) {
                    mutex.withLock {
                        webSocket?.close(1001, "idle timeout")
                        webSocket = null
                    }
                    sendQueue.close()
                    return@launch
                }
            }
        }
    }

    private fun handleIncoming(bytes: ByteString) {
        val envelope = try {
            frameCodec.decode(bytes.toByteArray())
        } catch (_: Exception) {
            return
        }
        val started = synchronized(pendingLock) { pendingRoundTrips.remove(envelope.id) }
        if (started != null) {
            val duration = Duration.between(started, clock.instant())
            metricsRecorder.recordRoundTrip(envelope.id, duration)
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
