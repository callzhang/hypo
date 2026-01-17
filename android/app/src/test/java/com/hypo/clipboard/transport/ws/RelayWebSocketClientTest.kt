package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.domain.model.ClipboardType
import com.hypo.clipboard.sync.EncryptionMetadata
import com.hypo.clipboard.sync.MessageType
import com.hypo.clipboard.sync.Payload
import com.hypo.clipboard.sync.SyncEnvelope
import com.hypo.clipboard.transport.TransportAnalytics
import com.hypo.clipboard.transport.TransportAnalyticsEvent
import android.util.Log
import java.time.Clock
import java.time.Instant
import java.time.ZoneId
import javax.net.ssl.SSLPeerUnverifiedException
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import okhttp3.Request
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.junit.Assert.assertEquals
import org.junit.Test
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class RelayWebSocketClientTest {
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
    fun `records pinning failures with cloud environment`() = runTest {
        val dispatcher = UnconfinedTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val connector = FakeConnector()
        val analytics = RecordingAnalytics()
        val clock = FrozenClock(Instant.parse("2025-10-08T12:00:00Z"))
        val transportManager = mockk<com.hypo.clipboard.transport.TransportManager>(relaxed = true)
        val deviceIdentity = mockk<com.hypo.clipboard.sync.DeviceIdentity>(relaxed = true) {
            every { deviceId } returns "android-device"
        }
        val relayClient = mockk<com.hypo.clipboard.pairing.PairingRelayClient>(relaxed = true)
        val client = RelayWebSocketClient(
            config = TlsWebSocketConfig(
                url = "wss://hypo.fly.dev/ws",
                fingerprintSha256 = "abcd",
                environment = "cloud"
            ),
            connector = connector,
            frameCodec = TransportFrameCodec(),
            analytics = analytics,
            transportManager = transportManager,
            relayClient = relayClient,
            deviceIdentity = deviceIdentity,
            scope = scope,
            clock = clock
        )
        client.startReceiving()

        val job = scope.launch { runCatching { client.send(sampleEnvelope()) } }
        waitForConnection(scope, connector)
        connector.fail(SSLPeerUnverifiedException("pin mismatch"))
        scope.runCurrent()
        job.cancel()

        val event = analytics.recorded.single() as TransportAnalyticsEvent.PinningFailure
        assertEquals("cloud", event.environment)
        assertEquals("hypo.fly.dev", event.host)
        assertEquals("pin mismatch", event.message)
        assertEquals(clock.instant(), event.occurredAt)
    }

    private fun sampleEnvelope(): SyncEnvelope = SyncEnvelope(
        type = MessageType.CLIPBOARD,
        payload = Payload(
            contentType = ClipboardType.TEXT,
            ciphertext = "AQ==",
            deviceId = "mac",
            target = "android",
            encryption = EncryptionMetadata(nonce = "Ag==", tag = "Aw==")
        )
    )

    private class FakeConnector : WebSocketConnector {
        private val listeners = mutableListOf<WebSocketListener>()
        private val sockets = mutableListOf<FakeWebSocket>()

        override fun connect(listener: WebSocketListener): WebSocket {
            val socket = FakeWebSocket()
            listeners += listener
            sockets += socket
            return socket
        }

        fun listenersCount(): Int = listeners.size

        fun fail(error: Throwable, index: Int = listeners.lastIndex) {
            listeners[index].onFailure(sockets[index], error, null)
        }
    }

    private class FakeWebSocket : WebSocket {
        private val request = Request.Builder()
            .url("https://hypo.fly.dev/ws")
            .build()

        override fun request(): Request = request
        override fun queueSize(): Long = 0
        override fun send(text: String): Boolean = true
        override fun send(bytes: ByteString): Boolean = true
        override fun close(code: Int, reason: String?): Boolean = true
        override fun cancel() {}
    }

    private class RecordingAnalytics : TransportAnalytics {
        private val _events = mutableListOf<TransportAnalyticsEvent>()
        val recorded: List<TransportAnalyticsEvent>
            get() = _events

        override val events = kotlinx.coroutines.flow.MutableSharedFlow<TransportAnalyticsEvent>()

        override fun record(event: TransportAnalyticsEvent) {
            _events += event
        }
    }

    private class FrozenClock(private val instant: Instant) : Clock() {
        override fun getZone(): ZoneId = ZoneId.systemDefault()
        override fun withZone(zone: ZoneId?): Clock = this
        override fun instant(): Instant = instant
    }

    private suspend fun waitForConnection(scope: TestScope, connector: FakeConnector, index: Int = 0) {
        repeat(5) {
            scope.runCurrent()
            scope.advanceUntilIdle()
            if (connector.listenersCount() > index) {
                return
            }
        }
        assertTrue(connector.listenersCount() > index)
    }
}
