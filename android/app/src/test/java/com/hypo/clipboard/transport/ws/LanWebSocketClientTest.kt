package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.sync.EncryptionMetadata
import com.hypo.clipboard.sync.MessageType
import com.hypo.clipboard.sync.Payload
import com.hypo.clipboard.sync.SyncEnvelope
import com.hypo.clipboard.transport.TransportMetricsRecorder
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
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

            assertEquals(1, connector.socket.sent.size)
            val frame = connector.socket.sent.first()
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
        val socket = FakeWebSocket()
        lateinit var listener: WebSocketListener

        override fun connect(listener: WebSocketListener): WebSocket {
            this.listener = listener
            return socket
        }

        fun open() {
            val request = socket.request()
            val response = Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(101)
                .message("Switching Protocols")
                .build()
            listener.onOpen(socket, response)
        }

        fun deliver(bytes: ByteString) {
            listener.onMessage(socket, bytes)
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
}
