package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.sync.EncryptionMetadata
import com.hypo.clipboard.sync.MessageType
import com.hypo.clipboard.sync.Payload
import com.hypo.clipboard.sync.SyncEnvelope
import com.hypo.clipboard.transport.TransportAnalytics
import com.hypo.clipboard.transport.TransportAnalyticsEvent
import com.hypo.clipboard.transport.TransportMetricsRecorder
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import javax.net.ssl.SSLPeerUnverifiedException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
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

@OptIn(ExperimentalCoroutinesApi::class)
class LanWebSocketClientTest {
    @Test
    fun `send enqueues framed payload`() = runTest {
        val dispatcher = UnconfinedTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val connector = FakeConnector()
        val config = TlsWebSocketConfig(url = "wss://example.com/ws", fingerprintSha256 = null)
        val client = LanWebSocketClient(config, connector, TransportFrameCodec(), scope, FakeClock(Instant.now()))

        val result = runCatching {
            val envelope = sampleEnvelope()
            val sendJob = scope.launch { client.send(envelope) }

            scope.runCurrent()
            runCurrent()
            connector.open()
            scope.runCurrent()
            runCurrent()

            sendJob.join()

            assertEquals(1, connector.latestSocket().sent.size)
            val frame = connector.latestSocket().sent.first()
            val decoded = TransportFrameCodec().decode(frame.toByteArray())
            assertEquals("mac-device", decoded.payload.deviceId)
        }

        scope.cancel()
        result.getOrThrow()
    }

    @Test
    fun `hex fingerprint converts to okhttp pin`() {
        val pin = OkHttpWebSocketConnector.hexToPin("AA:BB:CC:DD")
        assertEquals("qrvM3Q==", pin)
    }

    @Test
    fun `records handshake and round trip metrics`() = runTest {
        val dispatcher = UnconfinedTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val connector = FakeConnector()
        val clock = FakeClock(Instant.parse("2025-10-07T00:00:00Z"))
        val metrics = RecordingMetricsRecorder()
        val codec = TransportFrameCodec()
        val config = TlsWebSocketConfig(url = "wss://example.com/ws", fingerprintSha256 = null)
        val client = LanWebSocketClient(config, connector, codec, scope, clock, metrics)

        val result = runCatching {
            val envelope = sampleEnvelope()
            val sendJob = scope.launch { client.send(envelope) }
            scope.runCurrent()
            runCurrent()

            clock.advanceMillis(42)
            connector.open()
            scope.runCurrent()
            runCurrent()

            clock.advanceMillis(15)
            val frame = codec.encode(envelope)
            connector.deliver(of(*frame))
            scope.runCurrent()
            runCurrent()

            sendJob.join()

            assertEquals(listOf(Duration.ofMillis(42)), metrics.handshakeDurations)
            assertEquals(listOf(Duration.ofMillis(57)), metrics.roundTripDurations)
        }

        scope.cancel()
        result.getOrThrow()
    }

    @Test
    fun `reconnects after idle timeout`() = runTest {
        val dispatcher = UnconfinedTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val connector = FakeConnector()
        val clock = FakeClock(Instant.parse("2025-10-07T00:00:00Z"))
        val config = TlsWebSocketConfig(
            url = "wss://example.com/ws",
            fingerprintSha256 = null,
            idleTimeoutMillis = 10
        )
        val client = LanWebSocketClient(config, connector, TransportFrameCodec(), scope, clock)

        val firstEnvelope = sampleEnvelope()
        val firstJob = scope.launch { client.send(firstEnvelope) }
        scope.runCurrent()
        runCurrent()
        connector.open(0)
        scope.runCurrent()
        runCurrent()
        firstJob.join()

        clock.advanceMillis(15)
        repeat(3) {
            testScheduler.advanceTimeBy(5)
            testScheduler.advanceUntilIdle()
            if (connector.socket(0).closedCode != null) {
                return@repeat
            }
        }

        assertEquals(1001, connector.socket(0).closedCode)
        assertEquals("idle timeout", connector.socket(0).closedReason)

        val secondEnvelope = sampleEnvelope()
        val secondJob = scope.launch { client.send(secondEnvelope) }
        scope.runCurrent()
        runCurrent()
        testScheduler.advanceUntilIdle()
        connector.open(1)
        scope.runCurrent()
        runCurrent()
        secondJob.join()

        assertEquals(1, connector.socket(1).sent.size)
        assertEquals(2, connector.connectionCount)

        scope.cancel()
    }

    @Test
    fun `records pinning failure analytics`() = runTest {
        val dispatcher = UnconfinedTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val connector = FakeConnector()
        val clock = FakeClock(Instant.parse("2025-10-07T00:00:00Z"))
        val analytics = RecordingAnalytics()
        val config = TlsWebSocketConfig(
            url = "wss://relay.example/ws",
            fingerprintSha256 = "abcd",
            environment = "cloud"
        )
        val client = LanWebSocketClient(
            config,
            connector,
            TransportFrameCodec(),
            scope,
            clock,
            RecordingMetricsRecorder(),
            analytics
        )

        val job = scope.launch { runCatching { client.send(sampleEnvelope()) }.getOrNull() }
        scope.runCurrent()
        runCurrent()

        connector.fail(SSLPeerUnverifiedException("pin mismatch"))
        scope.runCurrent()
        runCurrent()

        job.cancel()
        scope.cancel()

        val event = analytics.recorded.single() as TransportAnalyticsEvent.PinningFailure
        assertEquals("cloud", event.environment)
        assertEquals("relay.example", event.host)
        assertEquals("pin mismatch", event.message)
        assertEquals(clock.instant(), event.occurredAt)
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
}
