package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.sync.EncryptionMetadata
import com.hypo.clipboard.sync.MessageType
import com.hypo.clipboard.sync.Payload
import com.hypo.clipboard.sync.SyncEnvelope
import com.hypo.clipboard.transport.TransportAnalytics
import com.hypo.clipboard.transport.TransportAnalyticsEvent
import com.hypo.clipboard.transport.TransportMetricsRecorder
import io.mockk.every
import android.util.Log
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue
import javax.net.ssl.SSLPeerUnverifiedException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.of
import io.mockk.mockkStatic
import io.mockk.unmockkStatic

@OptIn(ExperimentalCoroutinesApi::class)
class WebSocketTransportClientTest {
    @BeforeTest
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.v(any(), any()) } returns 0
        every { Log.v(any(), any(), any()) } returns 0
        every { Log.d(any(), any()) } returns 0
        every { Log.d(any(), any(), any()) } returns 0
        every { Log.i(any(), any()) } returns 0
        every { Log.i(any(), any(), any()) } returns 0
        every { Log.w(any(), any<String>()) } returns 0
        every { Log.w(any(), any<Throwable>()) } returns 0
        every { Log.w(any(), any(), any()) } returns 0
        every { Log.e(any(), any()) } returns 0
        every { Log.e(any(), any(), any()) } returns 0
    }

    @AfterTest
    fun tearDown() {
        unmockkStatic(Log::class)
    }
    @Test
    fun `send enqueues framed payload`() = runTest {
        val scope = this
        val connector = FakeConnector()
        val config = TlsWebSocketConfig(url = "wss://example.com/ws", fingerprintSha256 = null, environment = "cloud")
        val client = WebSocketTransportClient(config, connector, TransportFrameCodec(), scope, FakeClock(Instant.now()))
        client.forceConnectOnce()

        try {
            val envelope = sampleEnvelope()
            client.send(envelope)

            waitForConnection(scope, connector)
            connector.open()
            testScheduler.advanceTimeBy(500)
            scope.runCurrent()
            runCurrent()

            scope.runCurrent()
            runCurrent()

            assertEquals(1, connector.latestSocket().sent.size)
            val frame = connector.latestSocket().sent.first()
            val decoded = TransportFrameCodec().decode(frame.toByteArray())
            assertEquals("mac-device", decoded.payload.deviceId)
        } finally {
            client.close()
            scope.runCurrent()
            runCurrent()
        }
    }

    @Test
    fun `hex fingerprint converts to okhttp pin`() {
        val pin = OkHttpWebSocketConnector.hexToPin("AA:BB:CC:DD")
        assertEquals("qrvM3Q==", pin)
    }

    @Test
    fun `records handshake and round trip metrics`() = runTest {
        val scope = this
        val connector = FakeConnector()
        val clock = FakeClock(Instant.parse("2025-10-07T00:00:00Z"))
        val metrics = RecordingMetricsRecorder()
        val codec = TransportFrameCodec()
        val config = TlsWebSocketConfig(url = "wss://example.com/ws", fingerprintSha256 = null, environment = "cloud")
        val client = WebSocketTransportClient(config, connector, codec, scope, clock, metrics)
        client.forceConnectOnce()

        try {
            val envelope = sampleEnvelope()
            client.send(envelope)
            waitForConnection(scope, connector)

            clock.advanceMillis(42)
            connector.open()
            testScheduler.advanceTimeBy(500)
            scope.runCurrent()
            runCurrent()

            clock.advanceMillis(15)
            val frame = codec.encode(envelope)
            connector.deliver(of(*frame))
            scope.runCurrent()
            runCurrent()

            scope.runCurrent()
            runCurrent()

            assertTrue(metrics.handshakeDurations.size <= 1)
            assertTrue(metrics.roundTripDurations.size <= 1)
        } finally {
            client.close()
            scope.runCurrent()
            runCurrent()
        }
    }

    @Test
    fun `reconnects after idle timeout`() = runTest {
        val scope = this
        val connector = FakeConnector()
        val clock = FakeClock(Instant.parse("2025-10-07T00:00:00Z"))
        val config = TlsWebSocketConfig(
            url = "wss://example.com/ws",
            fingerprintSha256 = null,
            idleTimeoutMillis = 10,
            environment = "cloud"
        )
        val client = WebSocketTransportClient(config, connector, TransportFrameCodec(), scope, clock)
        client.forceConnectOnce()

        val firstEnvelope = sampleEnvelope()
        client.send(firstEnvelope)
        waitForConnection(scope, connector, 0)
        connector.open(0)
        testScheduler.advanceTimeBy(500)
        scope.runCurrent()
        runCurrent()

        connector.fail(RuntimeException("idle timeout"), 0)
        scope.runCurrent()
        runCurrent()

        val secondEnvelope = sampleEnvelope()
        client.send(secondEnvelope)
        scope.runCurrent()
        runCurrent()
        waitForConnection(scope, connector, 1)
        connector.open(1)
        testScheduler.advanceTimeBy(500)
        scope.runCurrent()
        runCurrent()
        scope.runCurrent()
        runCurrent()

        try {
            assertEquals(1, connector.socket(1).sent.size)
            assertEquals(2, connector.connectionCount)
        } finally {
            client.close()
            scope.runCurrent()
            runCurrent()
        }
    }

    @Test
    fun `records pinning failure analytics`() = runTest {
        val scope = this
        val connector = FakeConnector()
        val clock = FakeClock(Instant.parse("2025-10-07T00:00:00Z"))
        val analytics = RecordingAnalytics()
        val config = TlsWebSocketConfig(
            url = "wss://relay.example/ws",
            fingerprintSha256 = "abcd",
            environment = "cloud"
        )
        val client = WebSocketTransportClient(
            config,
            connector,
            TransportFrameCodec(),
            scope,
            clock,
            RecordingMetricsRecorder(),
            analytics
        )
        client.forceConnectOnce()

        val job = scope.launch { runCatching { client.send(sampleEnvelope()) }.getOrNull() }
        waitForConnection(scope, connector)

        connector.fail(SSLPeerUnverifiedException("pin mismatch"))
        scope.runCurrent()
        runCurrent()

        job.cancel()
        try {
            val event = analytics.recorded.single() as TransportAnalyticsEvent.PinningFailure
            assertEquals("cloud", event.environment)
            assertEquals("relay.example", event.host)
            assertEquals("pin mismatch", event.message)
            assertEquals(clock.instant(), event.occurredAt)
        } finally {
            client.close()
            scope.runCurrent()
            runCurrent()
        }
    }

    @Test
    fun `stale shutdown does not clear new socket`() = runTest {
        val scope = this
        val connector = FakeConnector()
        val clock = FakeClock(Instant.parse("2025-10-07T00:00:00Z"))
        val config = TlsWebSocketConfig(url = "wss://example.com/ws", fingerprintSha256 = null, environment = "cloud")
        val client = WebSocketTransportClient(config, connector, TransportFrameCodec(), scope, clock)
        client.forceConnectOnce()

        val firstEnvelope = sampleEnvelope()
        client.send(firstEnvelope)
        waitForConnection(scope, connector, 0)
        connector.open(0)
        testScheduler.advanceTimeBy(500)
        scope.runCurrent()
        runCurrent()

        val firstSocket = connector.socket(0)
        connector.fail(RuntimeException("boom"), 0)

        val secondEnvelope = sampleEnvelope()
        client.send(secondEnvelope)
        waitForConnection(scope, connector, 1)
        connector.open(1)
        testScheduler.advanceTimeBy(500)
        scope.runCurrent()
        runCurrent()
        scope.runCurrent()
        runCurrent()

        val webSocketField = WebSocketTransportClient::class.java.getDeclaredField("webSocket").apply {
            isAccessible = true
        }
        val shutdownMethod = WebSocketTransportClient::class.java.getDeclaredMethod(
            "shutdownSocket",
            WebSocket::class.java
        ).apply {
            isAccessible = true
        }

        val activeSocket = webSocketField.get(client) as WebSocket
        assertSame(connector.socket(1), activeSocket)

        shutdownMethod.invoke(client, firstSocket)
        scope.runCurrent()
        runCurrent()

        val afterShutdownSocket = webSocketField.get(client) as WebSocket
        assertSame(connector.socket(1), afterShutdownSocket)

        val thirdEnvelope = sampleEnvelope()
        client.send(thirdEnvelope)
        scope.runCurrent()
        runCurrent()
        scope.runCurrent()
        runCurrent()
        scope.runCurrent()
        runCurrent()

        try {
            assertEquals(2, connector.socket(1).sent.size)
        } finally {
            client.close()
            scope.runCurrent()
            runCurrent()
        }
    }

    private fun sampleEnvelope(): SyncEnvelope = SyncEnvelope(
        type = MessageType.CLIPBOARD,
        payload = Payload(
            contentType = ClipboardType.TEXT,
            ciphertext = "3q2+7w==",
            deviceId = "mac-device",
            target = "android",
            encryption = EncryptionMetadata(nonce = "qrvM", tag = "EBES")
        )
    )

    private class FakeConnector : WebSocketConnector {
        private val listeners = mutableListOf<WebSocketListener>()
        private val sockets = mutableListOf<FakeWebSocket>()

        val connectionCount: Int
            get() = sockets.size

        override fun connect(listener: WebSocketListener): WebSocket {
            listeners += listener
            val socket = FakeWebSocket()
            sockets += socket
            return socket
        }

        fun open(index: Int = listeners.lastIndex) {
            val socket = sockets[index]
            val listener = listeners[index]
            val request = socket.request()
            val response = Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(101)
                .message("Switching Protocols")
                .build()
            listener.onOpen(socket, response)
        }

        fun deliver(bytes: ByteString, index: Int = listeners.lastIndex) {
            listeners[index].onMessage(sockets[index], bytes)
        }

        fun latestSocket(): FakeWebSocket = sockets.last()

        fun socket(index: Int): FakeWebSocket = sockets[index]

        fun fail(exception: Throwable, index: Int = listeners.lastIndex) {
            listeners[index].onFailure(sockets[index], exception, null)
        }
    }

    private class FakeWebSocket : WebSocket {
        val sent = mutableListOf<ByteString>()
        var closedCode: Int? = null
        var closedReason: String? = null
        private val request = Request.Builder().url("https://example.com/ws").build()

        override fun request(): Request = request

        override fun queueSize(): Long = 0

        override fun send(text: String): Boolean = true

        override fun send(bytes: ByteString): Boolean {
            sent += bytes
            return true
        }

        override fun close(code: Int, reason: String?): Boolean {
            closedCode = code
            closedReason = reason
            return true
        }

        override fun cancel() {}
    }

    private class FakeClock(initial: Instant) : Clock() {
        private var current = initial

        override fun getZone(): ZoneId = ZoneId.systemDefault()

        override fun withZone(zone: ZoneId?): Clock = this

        override fun instant(): Instant = current

        fun advanceMillis(delta: Long) {
            current = current.plusMillis(delta)
        }
    }

    private class RecordingMetricsRecorder : TransportMetricsRecorder {
        val handshakeDurations = mutableListOf<Duration>()
        val roundTripDurations = mutableListOf<Duration>()

        override fun recordHandshake(duration: Duration, timestamp: Instant) {
            handshakeDurations += duration
        }

        override fun recordRoundTrip(envelopeId: String, duration: Duration) {
            roundTripDurations += duration
        }
    }

    private class RecordingAnalytics : TransportAnalytics {
        private val _events = mutableListOf<TransportAnalyticsEvent>()
        val recorded: List<TransportAnalyticsEvent>
            get() = _events

        override val events = MutableSharedFlow<TransportAnalyticsEvent>()

        override fun record(event: TransportAnalyticsEvent) {
            _events += event
        }
    }

    private suspend fun waitForConnection(scope: TestScope, connector: FakeConnector, index: Int = 0) {
        repeat(5) {
            scope.runCurrent()
            scope.testScheduler.advanceTimeBy(1_000)
            scope.runCurrent()
            if (connector.connectionCount > index) {
                return
            }
        }
        assertTrue(connector.connectionCount > index, "Expected connection attempt before opening socket")
    }
}
