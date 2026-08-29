package com.hypo.clipboard

import android.content.Intent
import android.content.pm.PackageManager
import android.service.quicksettings.TileService
import androidx.test.core.app.ApplicationProvider
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.robolectric.RobolectricTestRunner
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class QuickSettingsTileManifestTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()

    @Test
    fun `quick settings tile is registered for the background sync service`() {
        val tileService = context.packageManager
            .queryIntentServices(
                Intent(TileService.ACTION_QS_TILE),
                PackageManager.MATCH_ALL
            )
            .firstOrNull { it.serviceInfo.name == "com.hypo.clipboard.QuickSettingsTileService" }
            ?.serviceInfo

        assertNotNull(tileService, "Hypo must expose a Quick Settings tile service")
        assertEquals(
            "android.permission.BIND_QUICK_SETTINGS_TILE",
            tileService.permission
        )
        assertTrue(tileService.exported, "Quick Settings must be able to bind the tile")
    }

    @Test
    fun `quick settings tile uses a dedicated monochrome icon`() {
        val tileService = context.packageManager
            .queryIntentServices(
                Intent(TileService.ACTION_QS_TILE),
                PackageManager.MATCH_ALL
            )
            .first { it.serviceInfo.name == "com.hypo.clipboard.QuickSettingsTileService" }
            .serviceInfo

        assertEquals(R.drawable.ic_quick_settings, tileService.icon)
    }
}
