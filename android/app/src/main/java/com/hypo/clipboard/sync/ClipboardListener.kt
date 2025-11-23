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
    @Volatile
    var isListening: Boolean = false
        private set
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
            var consecutiveBlockedCount = 0
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
                                    consecutiveBlockedCount = 0 // Reset counter on success
                                    process(clip)
                                }
                            }
                        } catch (e: SecurityException) {
                            // Parser may throw SecurityException when accessing clipboard content
                            consecutiveBlockedCount++
                            if (consecutiveBlockedCount % 10 == 0) {
                                // Log warning every 20 seconds (10 attempts * 2 seconds) when blocked
                                Log.w(TAG, "🔒 Clipboard access blocked repeatedly (${consecutiveBlockedCount} times). User needs to enable \"Allow clipboard access\" in Settings → Apps → Hypo → Permissions")
                            } else {
                                Log.d(TAG, "🔒 Parser: Clipboard access blocked: ${e.message}")
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Parser error during polling: ${e.message}", e)
                        }
                    }
                } catch (e: SecurityException) {
                    // Android 10+ may block clipboard access in background
                    // This is expected behavior, just log and continue
                    consecutiveBlockedCount++
                    if (consecutiveBlockedCount % 10 == 0) {
                        // Log warning every 20 seconds when blocked
                        Log.w(TAG, "🔒 Clipboard access blocked repeatedly (${consecutiveBlockedCount} times). Background clipboard access requires user permission in system settings.")
                    } else {
                        Log.d(TAG, "🔒 Clipboard access blocked (background restriction): ${e.message}")
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "⚠️ Error during clipboard polling: ${e.message}", e)
                }
            }
            Log.i(TAG, "🛑 Clipboard polling stopped")
        }
    }

    override fun onPrimaryClipChanged() {
        // CRITICAL: This is called synchronously on the main thread when setPrimaryClip is called.
        // We must return immediately and do all processing in a coroutine to avoid blocking the UI.
        // Launch processing in a coroutine immediately to avoid blocking the main thread
        scope.launch(Dispatchers.Default) {
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
    }

    @Volatile
    private var processingSignature: String? = null
    
    private fun process(clip: ClipData) {
        try {
            val event = parser.parse(clip)
            if (event == null) {
                return
            }
            val signature = event.signature()
            
            // Check for duplicate - use synchronized block to prevent race conditions
            synchronized(this) {
                if (lastSignature == signature || processingSignature == signature) {
                    return
                }
                // Mark as processing BEFORE launching coroutine to prevent race condition
                processingSignature = signature
            }

            job?.cancel()
            val exceptionHandler = kotlinx.coroutines.CoroutineExceptionHandler { _, throwable ->
                Log.e(TAG, "❌ Uncaught exception in clipboard callback: ${throwable.message}", throwable)
                // Clear processing signature on error
                synchronized(this) {
                    if (processingSignature == signature) {
                        processingSignature = null
                    }
                }
            }
            job = scope.launch(dispatcher + exceptionHandler) {
                try {
                    onClipboardChanged(event)
                    // Update lastSignature and clear processingSignature AFTER callback completes
                    synchronized(this@ClipboardListener) {
                        lastSignature = signature
                        if (processingSignature == signature) {
                            processingSignature = null
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Error in onClipboardChanged callback: ${e.message}", e)
                    // Clear processing signature on error
                    synchronized(this@ClipboardListener) {
                        if (processingSignature == signature) {
                            processingSignature = null
                        }
                    }
                }
            }
        } catch (e: SecurityException) {
            // Android 10+ may block clipboard access
            Log.d(TAG, "🔒 process: Clipboard access blocked: ${e.message}")
            // Clear processing signature on error
            synchronized(this) {
                processingSignature = null
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error processing clipboard clip: ${e.message}", e)
            // Clear processing signature on error
            synchronized(this) {
                processingSignature = null
            }
        }
    }

    companion object {
        private const val TAG = "ClipboardListener"
    }
}
