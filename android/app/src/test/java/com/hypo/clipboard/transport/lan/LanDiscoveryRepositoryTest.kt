package com.hypo.clipboard.transport.lan

import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.wifi.WifiManager
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implements
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Resetter
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
@Config(shadows = [TrackingShadowNsdManager::class])
class LanDiscoveryRepositoryTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val nsdManager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifiManager = context.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val dispatcher = UnconfinedTestDispatcher()
    private val clock = Clock.fixed(Instant.EPOCH, ZoneOffset.UTC)
    private lateinit var repository: LanDiscoveryRepository

    @Before
    fun setUp() {
        TrackingShadowNsdManager.reset()
        repository = LanDiscoveryRepository(context, nsdManager, wifiManager, dispatcher, clock)
    }

    @After
    fun tearDown() {
        TrackingShadowNsdManager.reset()
    }

    @Test
    fun restartsDiscoveryWhenNetworkChanges() = runTest(dispatcher) {
        val job = launch { repository.discover().collect { /* keep active */ } }
        advanceUntilIdle()
        assertEquals(1, TrackingShadowNsdManager.discoverCount)

        context.sendBroadcast(Intent(WifiManager.NETWORK_STATE_CHANGED_ACTION))
        advanceUntilIdle()
        assertEquals(2, TrackingShadowNsdManager.discoverCount)

        job.cancelAndJoin()
    }
}

@Implements(value = NsdManager::class, inheritImplementationMethods = true)
class TrackingShadowNsdManager : org.robolectric.shadows.ShadowNsdManager() {
    companion object {
        var discoverCount: Int = 0
            private set

        @JvmStatic
        @Resetter
        fun reset() {
            discoverCount = 0
        }
    }

    @Implementation
    protected fun discoverServices(
        serviceType: String?,
        protocolType: Int,
        listener: NsdManager.DiscoveryListener?
    ) {
        discoverCount += 1
    }

    @Implementation
    protected fun stopServiceDiscovery(listener: NsdManager.DiscoveryListener?) {
        // no-op for tests
    }
}
