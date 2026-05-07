package com.hypo.clipboard.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class ClipboardServiceRestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        val reason = when (action) {
            Intent.ACTION_BOOT_COMPLETED -> ClipboardServiceStartReason.BOOT_COMPLETED
            Intent.ACTION_MY_PACKAGE_REPLACED -> ClipboardServiceStartReason.PACKAGE_REPLACED
            else -> {
                Log.d(TAG, "Ignoring restart receiver action: $action")
                return
            }
        }

        Log.d(TAG, "Received restart signal: action=$action, reason=$reason")
        ClipboardKeepAliveScheduler.schedulePeriodic(context)
        ClipboardServiceStarter.start(context, reason)
    }

    companion object {
        private const val TAG = "ClipboardRestartReceiver"
    }
}
