package com.hypo.clipboard.transport

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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.advanceUntilIdle
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
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            scope = this,
            clock = clock
        )

        val initialConfig = defaultConfig()
        manager.start(initialConfig)
        advanceUntilIdle()

        assertTrue(registration.started)
        assertEquals(initialConfig, registration.lastConfig)
        assertTrue(manager.isAdvertising.value)

        val peer = peer("peer-1", clock.instant())
        discovery.emit(LanDiscoveryEvent.Added(peer))
        advanceUntilIdle()

        assertEquals(listOf(peer), manager.currentPeers())
        assertEquals(peer.lastSeen, manager.lastSeen(peer.serviceName))

        discovery.emit(LanDiscoveryEvent.Removed(peer.serviceName))
        advanceUntilIdle()

        assertTrue(manager.currentPeers().isEmpty())
        assertNull(manager.lastSeen(peer.serviceName))

        manager.stop()
    }

    @Test
    fun pruneStaleRemovesOldEntries() = runTest {
        val discovery = FakeDiscoverySource()
        val registration = FakeRegistrationController()
        val clock = MutableClock()
        val manager = TransportManager(discovery, registration, this, clock)

        manager.start(defaultConfig())
        advanceUntilIdle()

        val stalePeer = peer("stale", clock.instant())
        discovery.emit(LanDiscoveryEvent.Added(stalePeer))
        advanceUntilIdle()

        clock.advance(Duration.ofMinutes(3))
        val freshPeer = peer("fresh", clock.instant())
        discovery.emit(LanDiscoveryEvent.Added(freshPeer))
        advanceUntilIdle()

        clock.advance(Duration.ofMinutes(4))

        val removed = manager.pruneStale(Duration.ofMinutes(5))
        assertEquals(listOf(stalePeer), removed)
        assertEquals(listOf(freshPeer), manager.currentPeers())

        manager.stop()
    }

    @Test
    fun stopClearsStateAndUnregisters() = runTest {
        val discovery = FakeDiscoverySource()
        val registration = FakeRegistrationController()
        val clock = MutableClock()
        val manager = TransportManager(discovery, registration, this, clock)

        manager.start(defaultConfig())
        advanceUntilIdle()

        discovery.emit(LanDiscoveryEvent.Added(peer("peer", clock.instant())))
        advanceUntilIdle()
        assertFalse(manager.currentPeers().isEmpty())

        manager.stop()

        assertTrue(manager.currentPeers().isEmpty())
        assertFalse(manager.isAdvertising.value)
        assertTrue(registration.stopped)
    }

    @Test
    fun updateAdvertisementRestartsRegistration() = runTest {
        val discovery = FakeDiscoverySource()
        val registration = FakeRegistrationController()
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            scope = this,
            clock = MutableClock()
        )

        manager.start(defaultConfig())
        advanceUntilIdle()

        manager.updateAdvertisement(port = 9000, fingerprint = "updated")

        assertEquals(2, registration.startCount)
        val config = registration.lastConfig!!
        assertEquals(9000, config.port)
        assertEquals("updated", config.fingerprint)

        manager.stop()
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
        private val events = MutableSharedFlow<LanDiscoveryEvent>()

        override fun discover(serviceType: String): Flow<LanDiscoveryEvent> = events

        suspend fun emit(event: LanDiscoveryEvent) {
            events.emit(event)
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
}
