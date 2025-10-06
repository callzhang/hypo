package com.hypo.clipboard.transport.lan

import android.content.Context
import android.net.nsd.NsdManager
import android.net.wifi.WifiManager
import io.mockk.every
import io.mockk.mockk
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
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

@OptIn(ExperimentalCoroutinesApi::class)
class LanDiscoveryRepositoryTest {
    private val context: Context = mockk(relaxed = true)
    private val nsdManager: NsdManager = mockk(relaxed = true)
    private val wifiManager: WifiManager = mockk(relaxed = true)
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
        repository = LanDiscoveryRepository(
            context = context,
            nsdManager = nsdManager,
            wifiManager = wifiManager,
            dispatcher = dispatcher,
            clock = clock,
            networkEvents = networkEvents,
            multicastLockFactory = { multicastLock }
        )
    }

    @Test
    fun restartsDiscoveryWhenNetworkChanges() = runTest(dispatcher) {
        var discoverCount = 0
        every {
            nsdManager.discoverServices(any(), any(), any())
        } answers {
            discoverCount += 1
        }

        val job = launch { repository.discover().collect { /* keep active */ } }
        advanceUntilIdle()
        assertEquals(1, discoverCount)
        assertTrue(multicastLock.isHeld)

        networkEvents.emit(Unit)
        advanceUntilIdle()
        assertEquals(2, discoverCount)

        job.cancelAndJoin()
        advanceUntilIdle()
        assertEquals(1, multicastLock.releaseCount)
    }
}

private class FakeMulticastLock : LanDiscoveryRepository.MulticastLockHandle {
    private var held = false
    var acquireCount: Int = 0
        private set
    var releaseCount: Int = 0
        private set

    override val isHeld: Boolean
        get() = held

    override fun acquire() {
        acquireCount += 1
        held = true
    }

    override fun release() {
        releaseCount += 1
        held = false
    }
}
