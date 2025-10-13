package com.hypo.clipboard.sync

import android.content.ClipData
import android.content.ClipboardManager
import android.util.Log
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

class ClipboardListener(
    private val clipboardManager: ClipboardManager,
    private val parser: ClipboardParser,
    private val onClipboardChanged: suspend (ClipboardEvent) -> Unit,
    private val scope: CoroutineScope,
    private val dispatcher: CoroutineDispatcher = Dispatchers.Default
) : ClipboardManager.OnPrimaryClipChangedListener {

    private var lastSignature: String? = null
    private var job: Job? = null
    private var isListening: Boolean = false

    fun start() {
        if (isListening) return
        Log.i(TAG, "📋 ClipboardListener STARTING - registering listener")
        clipboardManager.addPrimaryClipChangedListener(this)
        clipboardManager.primaryClip?.let { clip ->
            Log.i(TAG, "📋 Processing initial clip on start")
            process(clip)
        }
        isListening = true
        Log.i(TAG, "✅ ClipboardListener is now ACTIVE")
    }

    fun stop() {
        if (!isListening) return
        clipboardManager.removePrimaryClipChangedListener(this)
        job?.cancel()
        job = null
        isListening = false

    }

    override fun onPrimaryClipChanged() {
        Log.i(TAG, "🔔 onPrimaryClipChanged TRIGGERED!")
        clipboardManager.primaryClip?.let { clip ->
            Log.i(TAG, "📋 Clipboard has content, processing...")
            process(clip)
        } ?: Log.w(TAG, "⚠️  Clipboard clip is null!")
    }

    private fun process(clip: ClipData) {
        Log.i(TAG, "🔍 Processing clip with ${clip.itemCount} items")
        val event = parser.parse(clip)
        if (event == null) {
            Log.w(TAG, "⚠️  Parser returned null event")
            return
        }
        val signature = event.signature()
        Log.i(TAG, "✏️  Event signature: $signature (last: $lastSignature)")
        if (lastSignature == signature) {
            Log.i(TAG, "⏭️  Duplicate detected, skipping")
            return
        }
        lastSignature = signature

        Log.i(TAG, "✅ NEW clipboard event! Type: ${event.type}, preview: ${event.preview.take(50)}")
        job?.cancel()
        job = scope.launch(dispatcher) {
            Log.i(TAG, "🚀 Calling onClipboardChanged callback...")
            onClipboardChanged(event)
            Log.i(TAG, "✅ onClipboardChanged callback completed")
        }
    }

    companion object {
        private const val TAG = "ClipboardListener"
    }
}
