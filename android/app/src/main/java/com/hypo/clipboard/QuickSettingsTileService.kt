package com.hypo.clipboard

import android.content.Context
import android.graphics.drawable.Icon
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.hypo.clipboard.service.ClipboardServiceStartReason
import com.hypo.clipboard.service.ClipboardServiceStarter
import com.hypo.clipboard.service.ClipboardSyncService

/** Quick Settings toggle for the Hypo background clipboard sync service. */
class QuickSettingsTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        qsTile?.apply {
            label = getString(R.string.quick_settings_tile_label)
            icon = Icon.createWithResource(this@QuickSettingsTileService, R.drawable.ic_quick_settings)
            state = if (QuickSettingsTileState.isEnabled(this@QuickSettingsTileService)) {
                Tile.STATE_ACTIVE
            } else {
                Tile.STATE_INACTIVE
            }
            updateTile()
        }
    }

    override fun onClick() {
        super.onClick()

        val currentlyEnabled = QuickSettingsTileState.isEnabled(this)
        if (currentlyEnabled) {
            ClipboardServiceStarter.start(
                context = this,
                reason = ClipboardServiceStartReason.QUICK_SETTINGS,
                action = ClipboardSyncService.ACTION_STOP,
                scheduleRecoveryOnFailure = false
            )
            QuickSettingsTileState.setEnabled(this, false)
        } else {
            val started = ClipboardServiceStarter.start(
                context = this,
                reason = ClipboardServiceStartReason.QUICK_SETTINGS,
                scheduleRecoveryOnFailure = false
            )
            if (started) {
                QuickSettingsTileState.setEnabled(this, true)
            }
        }

        qsTile?.state = if (QuickSettingsTileState.isEnabled(this)) {
            Tile.STATE_ACTIVE
        } else {
            Tile.STATE_INACTIVE
        }
        qsTile?.updateTile()
    }

    internal companion object {
        fun nextTileState(currentState: Int): Int =
            if (currentState == Tile.STATE_ACTIVE) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
    }
}

internal object QuickSettingsTileState {
    private const val PREFS_NAME = "quick_settings_tile"
    private const val KEY_SERVICE_ENABLED = "service_enabled"

    fun isEnabled(context: Context): Boolean = context
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        .getBoolean(KEY_SERVICE_ENABLED, false)

    fun setEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_SERVICE_ENABLED, enabled)
            .apply()
    }
}
