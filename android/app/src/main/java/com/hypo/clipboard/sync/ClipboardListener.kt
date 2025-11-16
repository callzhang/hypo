package com.hypo.clipboard.sync

import android.content.ClipData
import android.content.ClipboardManager
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
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
    private var pollingJob: Job? = null
    private var isListening: Boolean = false
    private var lastPolledSignature: String? = null

    fun start() {
        if (isListening) return
        try {
            Log.i(TAG, "📋 ClipboardListener STARTING - registering listener")
            clipboardManager.addPrimaryClipChangedListener(this)
            
            // Try to process initial clip, but don't fail if access is blocked
            try {
                clipboardManager.primaryClip?.let { clip ->
                    Log.i(TAG, "📋 Processing initial clip on start")
                    process(clip)
                }
            } catch (e: SecurityException) {
                Log.d(TAG, "🔒 Initial clip access blocked: ${e.message}")
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Error accessing initial clip: ${e.message}", e)
            }
            
            // On Android 10+, onPrimaryClipChanged() doesn't fire in background
            // Add polling fallback to detect manual clipboard changes
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startPolling()
            }
            
            isListening = true
            Log.i(TAG, "✅ ClipboardListener is now ACTIVE (listener + ${if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) "polling" else "no polling"})")
        } catch (e: SecurityException) {
            Log.e(TAG, "❌ SecurityException in start(): ${e.message}", e)
            // Don't set isListening = true if we can't register the listener
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error in start(): ${e.message}", e)
            // Don't set isListening = true if we can't register the listener
        }
    }

    fun stop() {
        if (!isListening) return
        clipboardManager.removePrimaryClipChangedListener(this)
        job?.cancel()
        job = null
        pollingJob?.cancel()
        pollingJob = null
        isListening = false
        Log.i(TAG, "🛑 ClipboardListener STOPPED")
    }
    
    /**
     * Poll clipboard periodically as fallback for Android 10+ where
     * onPrimaryClipChanged() doesn't fire when app is in background.
     * This is a workaround for system restrictions.
     */
    private fun startPolling() {
        pollingJob?.cancel()
        pollingJob = scope.launch(dispatcher) {
            Log.i(TAG, "🔄 Starting clipboard polling (Android 10+ workaround)")
            while (isActive) {
                delay(2_000) // Poll every 2 seconds
                try {
                    // On Android 10+, accessing clipboard in background may throw SecurityException
                    val clip = clipboardManager.primaryClip
                    if (clip != null) {
                        try {
                            val event = parser.parse(clip)
                            if (event != null) {
                                val signature = event.signature()
                                // Only process if it's different from what we last polled
                                // (onPrimaryClipChanged might have already processed it)
                                if (signature != lastPolledSignature && signature != lastSignature) {
                                    Log.i(TAG, "🔍 Polling detected new clipboard content (manual paste detected)")
                                    lastPolledSignature = signature
                                    process(clip)
                                }
                            }
                        } catch (e: SecurityException) {
                            // Parser may throw SecurityException when accessing clipboard content
                            Log.d(TAG, "🔒 Parser: Clipboard access blocked: ${e.message}")
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Parser error during polling: ${e.message}", e)
                        }
                    }
                } catch (e: SecurityException) {
                    // Android 10+ may block clipboard access in background
                    // This is expected behavior, just log and continue
                    Log.d(TAG, "🔒 Clipboard access blocked (background restriction): ${e.message}")
                } catch (e: Exception) {
                    Log.w(TAG, "⚠️ Error during clipboard polling: ${e.message}", e)
                }
            }
            Log.i(TAG, "🛑 Clipboard polling stopped")
        }
    }

    override fun onPrimaryClipChanged() {
        try {
            Log.i(TAG, "🔔 onPrimaryClipChanged TRIGGERED!")
            try {
                val clip = clipboardManager.primaryClip
                if (clip != null) {
                    Log.i(TAG, "📋 Clipboard has content, processing...")
                    process(clip)
                } else {
                    Log.w(TAG, "⚠️  Clipboard clip is null!")
                }
            } catch (e: SecurityException) {
                // Android 10+ may block clipboard access in background
                Log.d(TAG, "🔒 onPrimaryClipChanged: primaryClip access blocked: ${e.message}")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error accessing primaryClip in onPrimaryClipChanged: ${e.message}", e)
            }
        } catch (e: SecurityException) {
            // Android 10+ may block clipboard access in background
            Log.d(TAG, "🔒 onPrimaryClipChanged: Clipboard access blocked (background restriction): ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error in onPrimaryClipChanged: ${e.message}", e)
        }
    }

    private fun process(clip: ClipData) {
        try {
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
            val exceptionHandler = kotlinx.coroutines.CoroutineExceptionHandler { _, throwable ->
                Log.e(TAG, "❌ Uncaught exception in clipboard callback coroutine: ${throwable.message}", throwable)
            }
            job = scope.launch(dispatcher + exceptionHandler) {
                try {
                    Log.i(TAG, "🚀 Calling onClipboardChanged callback...")
                    onClipboardChanged(event)
                    Log.i(TAG, "✅ onClipboardChanged callback completed")
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Error in onClipboardChanged callback: ${e.message}", e)
                }
            }
        } catch (e: SecurityException) {
            // Android 10+ may block clipboard access
            Log.d(TAG, "🔒 process: Clipboard access blocked: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error processing clipboard clip: ${e.message}", e)
        }
    }

    companion object {
        private const val TAG = "ClipboardListener"
    }
}
