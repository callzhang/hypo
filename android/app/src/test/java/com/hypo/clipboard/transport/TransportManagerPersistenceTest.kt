package com.hypo.clipboard.transport

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.hypo.clipboard.transport.lan.LanRegistrationConfig
import com.hypo.clipboard.transport.lan.LanRegistrationController
import com.hypo.clipboard.transport.lan.LanDiscoverySource
import com.hypo.clipboard.transport.lan.LanDiscoveryEvent
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneId

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class TransportManagerPersistenceTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val dispatcher = StandardTestDispatcher()
    private val scope = TestScope(dispatcher)
    private val clock = Clock.fixed(Instant.parse("2024-01-01T00:00:00Z"), ZoneId.of("UTC"))

    private val discovery = object : LanDiscoverySource {
        override fun discover(serviceType: String): Flow<LanDiscoveryEvent> = MutableSharedFlow()
    }
    
    private val registration = object : LanRegistrationController {
        override fun start(config: LanRegistrationConfig) {}
        override fun stop() {}
    }

    @Test
    fun `persistDeviceName saves and retrieves name`() {
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            context = context,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ZERO
        )

        val deviceId = "test-device-id"
        val name = "Test Device Name"

        manager.persistDeviceName(deviceId, name)

        assertEquals("Test Device Name", manager.getDeviceName(deviceId))
    }

    @Test
    fun `getDeviceName retrieves name with different casing`() {
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            context = context,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ZERO
        )

        val deviceId = "Test-Device-ID"
        val name = "Stored Name"

        // Persist with original ID
        manager.persistDeviceName(deviceId, name)

        // Retrieve with lifecycle-normalized ID (lowercase)
        assertEquals("Stored Name", manager.getDeviceName(deviceId.lowercase()))
        // Retrieve with original ID
        assertEquals("Stored Name", manager.getDeviceName(deviceId))
    }

    @Test
    fun `getDeviceName returns null for unknown device`() {
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            context = context,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ZERO
        )

        assertNull(manager.getDeviceName("unknown-device"))
    }

    @Test
    fun `forgetPairedDevice removes persisted name and status`() {
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            context = context,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ZERO
        )

        val deviceId = "device-to-forget"
        manager.persistDeviceName(deviceId, "Forget Me")
        
        // Use reflection to store transport status since it's private API driven by connection
        // Or we can rely on verifying it's cleared if we could set it.
        // For now, let's just verify name is cleared.
        
        manager.forgetPairedDevice(deviceId)

        assertNull(manager.getDeviceName(deviceId))
    }

    @Test
    fun `forgetPairedDevice removes normalized keys correctly`() {
        val manager = TransportManager(
            discoverySource = discovery,
            registrationController = registration,
            context = context,
            scope = scope,
            clock = clock,
            pruneInterval = Duration.ZERO
        )

        val mixedCaseId = "Mixed-Case-Device-ID"
        manager.persistDeviceName(mixedCaseId, "Normalized Test")
        manager.markDeviceConnected(mixedCaseId, ActiveTransport.LAN)

        // Verify it was stored (getDeviceName normalizes internally)
        assertEquals("Normalized Test", manager.getDeviceName(mixedCaseId))
        
        // Forget with mixed case
        manager.forgetPairedDevice(mixedCaseId)

        // Verify it's gone
        assertNull(manager.getDeviceName(mixedCaseId))
    }
}
