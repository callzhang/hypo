package com.hypo.clipboard.sync

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Renaming this device.
 *
 * The default is the make and model, which is what the OS knows and rarely what
 * its owner would call it, and it is the name every peer shows.
 */
@RunWith(RobolectricTestRunner::class)
class DeviceRenameTest {

    private fun identity(): DeviceIdentity =
        DeviceIdentity(ApplicationProvider.getApplicationContext<Context>())

    @Test
    fun `the new name sticks`() {
        val identity = identity()

        identity.rename("Derek's Phone")

        assertEquals("Derek's Phone", identity.deviceName)
    }

    @Test
    fun `it survives a restart`() {
        identity().rename("Renamed")

        assertEquals("Renamed", identity().deviceName)
    }

    @Test
    fun `blank input is refused`() {
        val identity = identity()
        val before = identity.deviceName

        val kept = identity.rename("   ")

        // A device with no name is worse than one named after the hardware.
        assertEquals(before, kept)
        assertEquals(before, identity.deviceName)
    }

    @Test
    fun `renaming does not change the device id`() {
        val identity = identity()
        val before = identity.deviceId

        identity.rename("Something Else")

        // Peers key their stored keys off the id; changing it would unpair.
        assertEquals(before, identity.deviceId)
    }

    @Test
    fun `the default name is the hardware name`() {
        // Not asserting the exact string: it is whatever the device reports.
        assertNotEquals("", identity().deviceName)
    }
}
