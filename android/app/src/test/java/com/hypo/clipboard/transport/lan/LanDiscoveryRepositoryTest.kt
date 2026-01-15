package com.hypo.clipboard.transport.lan

import android.content.Context
import android.net.nsd.NsdManager
import android.net.wifi.WifiManager
import com.hypo.clipboard.sync.DeviceIdentity
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.net.InetAddress
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class LanDiscoveryRepositoryTest {
    private val context: Context = mockk(relaxed = true)
    private val nsdManager: NsdManager = mockk(relaxed = true)
    private val wifiManager: WifiManager = mockk(relaxed = true)
    private val deviceIdentity: DeviceIdentity = mockk(relaxed = true)
    private val dispatcher = UnconfinedTestDispatcher()
    private val clock = Clock.fixed(Instant.EPOCH, ZoneOffset.UTC)
    private val networkEvents = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    private val multicastLock = FakeMulticastLock()
    private lateinit var repository: LanDiscoveryRepository

    @Before
    fun setUp() {
        every { context.applicationContext } returns context
        every { nsdManager.stopServiceDiscovery(any()) } returns Unit
        every { nsdManager.resolveService(any(), any()) } answers {}
        every { deviceIdentity.deviceId } returns "test-device-id"
        repository = LanDiscoveryRepository(
            context = context,
            nsdManager = nsdManager,
            wifiManager = wifiManager,
            deviceIdentity = deviceIdentity,
            dispatcher = dispatcher,
            clock = clock,
            networkEvents = networkEvents,
            multicastLockFactory = { multicastLock }
        )
    }

    @Test
    fun restartsDiscoveryWhenNetworkChanges() = runTest(dispatcher) {
        var discoverCount = 0
        var stopCount = 0
        val listeners = mutableListOf<NsdManager.DiscoveryListener>()
        val stoppedListeners = mutableListOf<NsdManager.DiscoveryListener>()
        every {
            nsdManager.discoverServices(any(), any(), any())
        } answers {
            val listener = thirdArg<NsdManager.DiscoveryListener>()
            listeners.add(listener)
            discoverCount += 1
        }
        every { nsdManager.stopServiceDiscovery(any()) } answers {
            stopCount += 1
            stoppedListeners.add(firstArg())
        }

        val job = launch { repository.discover().collect { /* keep active */ } }
        advanceUntilIdle()
        assertEquals(1, discoverCount)
        assertTrue(multicastLock.isHeld)

        networkEvents.emit(Unit)
        advanceUntilIdle()
        assertEquals(2, discoverCount)
        assertEquals(1, stopCount)
        assertTrue(stoppedListeners.isNotEmpty())
        assertTrue(stoppedListeners.all { it === listeners.first() })

        job.cancelAndJoin()
        advanceUntilIdle()
        assertEquals(2, stopCount)
        assertEquals(1, multicastLock.releaseCount)
        assertTrue(stoppedListeners.all { it === listeners.first() })
    }

    @Test
    fun releasesResourcesWhenScopeFinishes() = runTest(dispatcher) {
        val listeners = mutableListOf<NsdManager.DiscoveryListener>()
        val stoppedListeners = mutableListOf<NsdManager.DiscoveryListener>()
        every {
            nsdManager.discoverServices(any(), any(), any())
        } answers {
            val listener = thirdArg<NsdManager.DiscoveryListener>()
            listeners.add(listener)
            listener.onServiceFound(mockk(relaxed = true))
        }

        var stopCalls = 0
        every { nsdManager.stopServiceDiscovery(any()) } answers {
            stopCalls += 1
            stoppedListeners.add(firstArg())
        }

        every { nsdManager.resolveService(any(), any()) } answers {
            val resolveListener = secondArg<NsdManager.ResolveListener>()
            val serviceInfo = mockk<android.net.nsd.NsdServiceInfo>()
            every { serviceInfo.serviceName } returns "peer"
            every { serviceInfo.host } returns InetAddress.getByName("192.168.1.10")
            every { serviceInfo.port } returns 9000
            every { serviceInfo.attributes } returns mapOf(
                "fingerprint_sha256" to "fingerprint".toByteArray()
            )
            resolveListener.onServiceResolved(serviceInfo)
        }

        val events = mutableListOf<LanDiscoveryEvent>()
        val job = launch {
            repository.discover().collect { events += it }
        }

        advanceUntilIdle()
        job.cancelAndJoin()
        advanceUntilIdle()

        assertTrue(events.isNotEmpty())
        assertEquals(1, multicastLock.releaseCount)
        assertEquals(1, stopCalls)
        assertTrue(stoppedListeners.isNotEmpty())
        assertTrue(stoppedListeners.all { it === listeners.first() })
        verify(exactly = 1) { nsdManager.resolveService(any(), any()) }
    }
}
