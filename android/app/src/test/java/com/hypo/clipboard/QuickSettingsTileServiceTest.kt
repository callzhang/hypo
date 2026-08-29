package com.hypo.clipboard

import kotlin.test.Test
import kotlin.test.assertEquals
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class QuickSettingsTileServiceTest {
    @Test
    fun `tile state toggles between active and inactive`() {
        assertEquals(
            android.service.quicksettings.Tile.STATE_ACTIVE,
            QuickSettingsTileService.nextTileState(android.service.quicksettings.Tile.STATE_INACTIVE)
        )
        assertEquals(
            android.service.quicksettings.Tile.STATE_INACTIVE,
            QuickSettingsTileService.nextTileState(android.service.quicksettings.Tile.STATE_ACTIVE)
        )
    }
}
