package com.hypo.clipboard.service

import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

object ClipboardServiceStarter {
    private const val TAG = "ClipboardServiceStarter"
    const val EXTRA_START_REASON = "com.hypo.clipboard.extra.START_REASON"

    fun start(
        context: Context,
        reason: ClipboardServiceStartReason,
        action: String? = null,
        scheduleRecoveryOnFailure: Boolean = true,
        configure: Intent.() -> Unit = {}
    ): Boolean {
        val appContext = context.applicationContext ?: context
        val intent = Intent(appContext, ClipboardSyncService::class.java).apply {
            if (action != null) {
                this.action = action
            }
            putExtra(EXTRA_START_REASON, reason.name)
            configure()
        }

        return try {
            when (ClipboardServiceStartPolicy.resolveStartMode(Build.VERSION.SDK_INT, reason)) {
                ClipboardServiceStartMode.START_FOREGROUND_SERVICE -> appContext.startForegroundService(intent)
                ClipboardServiceStartMode.START_SERVICE -> appContext.startService(intent)
            }
            Log.d(TAG, "Started ClipboardSyncService: reason=$reason, action=$action")
            true
        } catch (e: Exception) {
            Log.w(TAG, "Failed to start ClipboardSyncService: reason=$reason, action=$action, error=${e.message}", e)
            if (scheduleRecoveryOnFailure && isBackgroundForegroundServiceBlock(e)) {
                ClipboardKeepAliveScheduler.enqueueOneTime(appContext, "fgs_blocked_${reason.name.lowercase()}")
            }
            false
        }
    }

    private fun isBackgroundForegroundServiceBlock(error: Exception): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            error.javaClass.name == "android.app.ForegroundServiceStartNotAllowedException"
    }
}
