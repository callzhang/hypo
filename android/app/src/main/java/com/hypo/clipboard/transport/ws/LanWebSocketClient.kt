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
import kotlin.coroutines.coroutineContext
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
        while (!sendQueue.isClosedForReceive) {
            val closedSignal = CompletableDeferred<Unit>()
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
                    if (!closedSignal.isCompleted) {
                        closedSignal.complete(Unit)
                    }
                    shutdownSocket()
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    if (!closedSignal.isCompleted) {
                        closedSignal.complete(Unit)
                    }
                    shutdownSocket()
                    handshakeStarted = null
                }
            }

            handshakeStarted = clock.instant()
            val socket = connector.connect(listener)

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
                            val payload = frameCodec.encode(event.envelope)
                            synchronized(pendingLock) {
                                pendingRoundTrips[event.envelope.id] = clock.instant()
                            }
                            val sent = socket.send(of(*payload))
                            if (!sent) {
                                throw IOException("websocket send failed")
                            }
                            touch()
                        }
                    }
                }
            } finally {
                val cancelled = coroutineContext[Job]?.isCancelled == true
                if (!cancelled) {
                    socket.close(1000, null)
                }
                shutdownSocket()
            }
        }
    }

    private suspend fun waitForEvent(closedSignal: CompletableDeferred<Unit>): LoopEvent {
        return select {
            sendQueue.onReceiveCatching { result ->
                if (result.isClosed) {
                    LoopEvent.ChannelClosed
                } else {
                    LoopEvent.Envelope(result.getOrThrow())
                }
            }
            closedSignal.onAwait {
                LoopEvent.ConnectionClosed
            }
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
            while (isActive) {
                delay(timeout.toMillis())
                val elapsed = Duration.between(lastActivity, clock.instant())
                if (elapsed >= timeout) {
                    val socket = mutex.withLock { webSocket }
                    socket?.close(1001, "idle timeout")
                    mutex.withLock { webSocket = null }
                    connectionJob?.cancel()
                    watchdogJob = null
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
