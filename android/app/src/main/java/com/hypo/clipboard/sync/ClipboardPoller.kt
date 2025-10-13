package com.hypo.clipboard.sync

import android.content.ClipboardManager
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Polls clipboard for changes when listener doesn't work (e.g., MIUI devices)
 */
class ClipboardPoller(
    private val clipboardManager: ClipboardManager,
    private val parser: ClipboardParser,
    private val onClipboardChanged: suspend (ClipboardEvent) -> Unit,
    private val scope: CoroutineScope,
    private val pollIntervalMs: Long = 1000L
) {
    private var pollingJob: Job? = null
    private var lastSignature: String? = null
    private var isPolling: Boolean = false

    fun start() {
        if (isPolling) return
        isPolling = true
        Log.i(TAG, "🔄 ClipboardPoller STARTING (poll interval: ${pollIntervalMs}ms)")
        
        pollingJob = scope.launch {
            while (isActive && isPolling) {
                try {
                    checkClipboard()
                } catch (e: Exception) {
                    Log.w(TAG, "Error checking clipboard: ${e.message}")
                }
                delay(pollIntervalMs)
            }
        }
        Log.i(TAG, "✅ ClipboardPoller is now ACTIVE")
    }

    fun stop() {
        if (!isPolling) return
        isPolling = false
        pollingJob?.cancel()
        pollingJob = null
        Log.i(TAG, "⏹️  ClipboardPoller STOPPED")
    }

    private suspend fun checkClipboard() {
        val clip = clipboardManager.primaryClip ?: return
        
        val event = parser.parse(clip) ?: return
        val signature = event.signature()
        
        if (lastSignature == signature) {
            return // No change
        }
        
        lastSignature = signature
        Log.i(TAG, "✅ NEW clipboard detected via polling! Type: ${event.type}, preview: ${event.preview.take(50)}")
        onClipboardChanged(event)
    }

    companion object {
        private const val TAG = "ClipboardPoller"
    }
}

