package com.hypo.clipboard.transport

import com.hypo.clipboard.transport.TransportAnalyticsEvent
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import com.hypo.clipboard.transport.lan.LanDiscoveryEvent
import com.hypo.clipboard.transport.lan.LanDiscoverySource
import com.hypo.clipboard.transport.lan.LanRegistrationConfig
import com.hypo.clipboard.transport.lan.LanRegistrationController
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TransportManagerTest {

    @Test
    fun startRegistersServiceAndCollectsPeers() = runTest {
        val discovery = FakeDiscoverySource()
        val registration = FakeRegistrationController()
        val clock = MutableClock()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ZERO
        )

        val initialConfig = defaultConfig()
        manager.start(initialConfig)
        scope.runCurrent()

        assertTrue(registration.started)
        assertEquals(initialConfig, registration.lastConfig)
        assertTrue(manager.isAdvertising.value)

        val peer = peer("peer-1", clock.instant())
        discovery.emit(LanDiscoveryEvent.Added(peer))
        scope.runCurrent()

        assertEquals(listOf(peer), manager.currentPeers())
        assertEquals(peer.lastSeen, manager.lastSeen(peer.serviceName))

        discovery.emit(LanDiscoveryEvent.Removed(peer.serviceName))
        scope.runCurrent()

        assertTrue(manager.currentPeers().isEmpty())
        assertNull(manager.lastSeen(peer.serviceName))

        manager.stop()
        scope.runCurrent()
        scope.cancel()
    }

    @Test
    fun pruneStaleRemovesOldEntries() = runTest {
        val discovery = FakeDiscoverySource()
        val registration = FakeRegistrationController()
        val clock = MutableClock()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ZERO
        )

        manager.start(defaultConfig())
        scope.runCurrent()

        val stalePeer = peer("stale", clock.instant())
        discovery.emit(LanDiscoveryEvent.Added(stalePeer))
        scope.runCurrent()

        clock.advance(Duration.ofMinutes(3))
        val freshPeer = peer("fresh", clock.instant())
        discovery.emit(LanDiscoveryEvent.Added(freshPeer))
        scope.runCurrent()

        clock.advance(Duration.ofMinutes(4))

        val removed = manager.pruneStale(Duration.ofMinutes(5))
        assertEquals(listOf(stalePeer), removed)
        assertEquals(listOf(freshPeer), manager.currentPeers())

        manager.stop()
        scope.runCurrent()
        scope.cancel()
    }

    @Test
    fun automaticPruneRemovesPeersAfterInterval() = runTest {
        val discovery = FakeDiscoverySource()
        val registration = FakeRegistrationController()
        val clock = MutableClock()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ofSeconds(30),
            staleThreshold = Duration.ofSeconds(60)
        )

        manager.start(defaultConfig())
        scope.runCurrent()

        val peer = peer("peer-auto", clock.instant())
        discovery.emit(LanDiscoveryEvent.Added(peer))
        scope.runCurrent()

        assertEquals(listOf(peer), manager.currentPeers())

        clock.advance(Duration.ofSeconds(61))
        scope.advanceTimeBy(Duration.ofSeconds(30).toMillis())
        scope.runCurrent()

        assertTrue(manager.currentPeers().isEmpty())

        manager.stop()
        scope.runCurrent()
        scope.cancel()
    }

    @Test
    fun stopClearsStateAndUnregisters() = runTest {
        val discovery = FakeDiscoverySource()
        val registration = FakeRegistrationController()
        val clock = MutableClock()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ZERO
        )

        manager.start(defaultConfig())
        scope.runCurrent()

        discovery.emit(LanDiscoveryEvent.Added(peer("peer", clock.instant())))
        scope.runCurrent()
        assertFalse(manager.currentPeers().isEmpty())

        manager.stop()

        assertTrue(manager.currentPeers().isEmpty())
        assertFalse(manager.isAdvertising.value)
        assertTrue(registration.stopped)

        scope.runCurrent()
        scope.cancel()
    }

    @Test
    fun updateAdvertisementRestartsRegistration() = runTest {
        val discovery = FakeDiscoverySource()
        val registration = FakeRegistrationController()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            scope = scope,
            clock = MutableClock(),
            pruneInterval = Duration.ZERO
        )

        manager.start(defaultConfig())
        scope.runCurrent()

        manager.updateAdvertisement(port = 9000, fingerprint = "updated")

        assertEquals(2, registration.startCount)
        val config = registration.lastConfig!!
        assertEquals(9000, config.port)
        assertEquals("updated", config.fingerprint)

        manager.stop()
        scope.runCurrent()
        scope.cancel()
    }

    @Test
    fun connectPrefersLanWhenSuccessful() = runTest {
        val discovery = FakeDiscoverySource()
        val registration = FakeRegistrationController()
        val clock = MutableClock()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val analytics = RecordingAnalytics()
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ZERO,
            analytics = analytics
        )

        val state = manager.connect(
            lanDialer = { LanDialResult.Success },
            cloudDialer = { error("cloud should not be called") }
        )

        assertEquals(ConnectionState.ConnectedLan, state)
        assertTrue(analytics.recorded.isEmpty())
    }

    @Test
    fun connectFallsBackAfterTimeout() = runTest {
        val discovery = FakeDiscoverySource()
        val registration = FakeRegistrationController()
        val clock = MutableClock()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val analytics = RecordingAnalytics()
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ZERO,
            analytics = analytics
        )

        var cloudAttempts = 0
        val result = async {
            manager.connect(
                lanDialer = {
                    delay(Duration.ofSeconds(5).toMillis())
                    LanDialResult.Success
                },
                cloudDialer = {
                    cloudAttempts += 1
                    true
                },
                fallbackTimeout = Duration.ofSeconds(3)
            )
        }

        advanceTimeBy(Duration.ofSeconds(5).toMillis())
        runCurrent()

        assertEquals(ConnectionState.ConnectedCloud, result.await())
        val event = analytics.recorded.single() as TransportAnalyticsEvent.Fallback
        assertEquals(FallbackReason.LanTimeout, event.reason)
        assertEquals(1, cloudAttempts)
    }

    @Test
    fun connectRecordsLanFailureReason() = runTest {
        val discovery = FakeDiscoverySource()
        val registration = FakeRegistrationController()
        val clock = MutableClock()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val analytics = RecordingAnalytics()
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ZERO,
            analytics = analytics
        )

        val state = manager.connect(
            lanDialer = {
                LanDialResult.Failure(FallbackReason.LanRejected, IllegalStateException("bad handshake"))
            },
            cloudDialer = { true }
        )

        assertEquals(ConnectionState.ConnectedCloud, state)
        val event = analytics.recorded.single() as TransportAnalyticsEvent.Fallback
        assertEquals(FallbackReason.LanRejected, event.reason)
        assertEquals("bad handshake", event.metadata["error"])
    }

    @Test
    fun connectReturnsErrorWhenCloudFails() = runTest {
        val discovery = FakeDiscoverySource()
        val registration = FakeRegistrationController()
        val clock = MutableClock()
        val dispatcher = StandardTestDispatcher(testScheduler)
        val scope = TestScope(dispatcher)
        val analytics = RecordingAnalytics()
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ZERO,
            analytics = analytics
        )

        val state = manager.connect(
            lanDialer = { LanDialResult.Failure(FallbackReason.LanNotSupported, null) },
            cloudDialer = { false }
        )

        assertEquals(ConnectionState.Error, state)
        val event = analytics.recorded.single() as TransportAnalyticsEvent.Fallback
        assertEquals(FallbackReason.LanNotSupported, event.reason)
    }

    private fun defaultConfig() = LanRegistrationConfig(
        serviceName = "android-device",
        port = 7010,
        fingerprint = "uninitialized",
        version = "1.0.0",
        protocols = listOf("ws+tls")
    )

    private fun peer(serviceName: String, instant: Instant) = DiscoveredPeer(
        serviceName = serviceName,
        host = "192.168.1.10",
        port = 7010,
        fingerprint = "fingerprint",
        attributes = emptyMap(),
        lastSeen = instant
    )

    private class FakeDiscoverySource : LanDiscoverySource {
        private val events = MutableSharedFlow<LanDiscoveryEvent>(replay = 0, extraBufferCapacity = Int.MAX_VALUE)

        override fun discover(serviceType: String): Flow<LanDiscoveryEvent> = events

        suspend fun emit(event: LanDiscoveryEvent) {
            if (!events.tryEmit(event)) {
                events.emit(event)
            }
        }
    }

    private class FakeRegistrationController : LanRegistrationController {
        var started = false
        var stopped = false
        var startCount = 0
        var lastConfig: LanRegistrationConfig? = null

        override fun start(config: LanRegistrationConfig) {
            started = true
            stopped = false
            startCount += 1
            lastConfig = config
        }

        override fun stop() {
            stopped = true
        }
    }

    private class MutableClock : Clock() {
        private var current: Instant = Instant.parse("2024-10-01T10:15:30Z")

        override fun getZone(): ZoneId = ZoneOffset.UTC

        override fun withZone(zone: ZoneId): Clock = this

        override fun instant(): Instant = current

        fun advance(duration: Duration) {
            current = current.plus(duration)
        }
    }

    private class RecordingAnalytics : TransportAnalytics {
        private val _recorded = mutableListOf<TransportAnalyticsEvent>()
        val recorded: List<TransportAnalyticsEvent>
            get() = _recorded

        override val events: MutableSharedFlow<TransportAnalyticsEvent> = MutableSharedFlow()

        override fun record(event: TransportAnalyticsEvent) {
            _recorded += event
        }
    }
}
