package com.hypo.clipboard.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Monitors screen state changes to optimize battery usage.
 * When screen turns off, the service can idle WebSocket connections.
 * When screen turns on, connections are resumed.
 */
class ScreenStateReceiver(
    private val onScreenOff: () -> Unit,
    private val onScreenOn: () -> Unit
) : BroadcastReceiver() {

    override fun onReceive(context: Context?, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_SCREEN_OFF -> {
                Log.d(TAG, "Screen OFF - entering battery save mode")
                onScreenOff()
            }
            Intent.ACTION_SCREEN_ON -> {
                Log.d(TAG, "Screen ON - resuming normal operation")
                onScreenOn()
            }
        }
    }

    companion object {
        private const val TAG = "ScreenStateReceiver"
    }
}

