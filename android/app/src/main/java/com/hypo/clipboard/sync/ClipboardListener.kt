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
    @Volatile
    var isListening: Boolean = false
        private set
    // Track last clipboard description to avoid parsing when clipboard hasn't changed
    private var lastClipDescription: String? = null

    fun start() {
        if (isListening) return
        try {
            clipboardManager.addPrimaryClipChangedListener(this)
            
            // Initialize lastSignature from current clipboard to prevent re-sending old content on restart
            // This ensures we only sync actual clipboard changes, not whatever happens to be in clipboard on startup
            // IMPORTANT: We do NOT process the initial clipboard here - we only initialize lastSignature
            // to mark it as "already seen" so it won't be processed if the clipboard hasn't actually changed
            try {
                clipboardManager.primaryClip?.let { clip ->
                    val event = parser.parse(clip)
                    if (event != null) {
                        lastSignature = event.signature()
                    }
                }
            } catch (e: SecurityException) {
                // Silently handle - expected on Android 10+
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Error accessing initial clip: ${e.message}", e)
            }
            
            // EVENT-DRIVEN: Rely only on onPrimaryClipChanged() events
            // Note: On Android 10+, onPrimaryClipChanged() may not fire in background,
            // but if AccessibilityService is enabled, it will handle clipboard events.
            // Polling is removed - everything is now event-driven.
            
            isListening = true
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
        isListening = false
        Log.i(TAG, "🛑 ClipboardListener STOPPED")
    }

    override fun onPrimaryClipChanged() {
        // CRITICAL: This is called synchronously on the main thread when setPrimaryClip is called.
        // We must return immediately and do all processing in a coroutine to avoid blocking the UI.
        // Launch processing in a coroutine immediately to avoid blocking the main thread
        scope.launch(dispatcher) {
            try {
                try {
                    val clip = clipboardManager.primaryClip
                    if (clip != null) {
                        val description = clip.description
                        val label = description.label
                        val isUserCopyFromHistory = label == "Hypo Clipboard"
                        
                        // Quick check: compare clipboard description to avoid parsing if unchanged
                        // BUT: Always process "Hypo Clipboard" label even if description matches
                        // This ensures user-initiated copies from history always sync, even on second click
                        val descriptionKey = "${description.label}|${description.getMimeType(0)}|${clip.itemCount}"
                        if (!isUserCopyFromHistory && descriptionKey == lastClipDescription) {
                            // Clipboard description hasn't changed, skip parsing (unless it's a user copy from history)
                            return@launch
                        }
                        
                        // For "Hypo Clipboard" label, always process even if description matches
                        // This ensures second clicks on the same item still trigger sync
                        if (isUserCopyFromHistory) {
                            // Clear lastClipDescription to force processing
                            lastClipDescription = null
                        } else {
                            lastClipDescription = descriptionKey
                        }
                        
                        process(clip)
                    } else {
                        lastClipDescription = null
                    }
                } catch (e: SecurityException) {
                    // Android 10+ may block clipboard access in background
                    // Silently handle - this is expected behavior
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Error accessing primaryClip in onPrimaryClipChanged: ${e.message}", e)
                }
            } catch (e: SecurityException) {
                // Android 10+ may block clipboard access in background
                // Silently handle - this is expected behavior
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error in onPrimaryClipChanged: ${e.message}", e)
            }
        }
    }

    @Volatile
    private var processingSignature: String? = null
    
    private fun process(clip: ClipData) {
        try {
            // Skip processing if this is a remote clipboard update (from other devices)
            // Remote updates use "Hypo Remote" label to prevent loops
            val description = clip.description
            val label = description.label
            if (label == "Hypo Remote") {
                return
            }
            
            // "Hypo Clipboard" label indicates user explicitly copied from history
            // This should sync to other devices even if it's a duplicate
            val isUserCopyFromHistory = label == "Hypo Clipboard"
            
            // If user copied from history, clear parser's URI/hash tracking AND seen hashes to allow re-parsing
            if (isUserCopyFromHistory) {
                synchronized(ClipboardParser.hashLock) {
                    ClipboardParser.lastImageUri = null
                    ClipboardParser.lastImageHash = null
                    // Also clear the seen hashes set to allow re-parsing even if hash matches
                    ClipboardParser.seenImageHashes.clear()
                }
            }
            
            val event = parser.parse(clip)
            if (event == null) {
                return
            }
            val signature = event.signature()
            
            // Check for duplicate - but allow "Hypo Clipboard" (user copy from history) to sync
            synchronized(this) {
                if (!isUserCopyFromHistory && (lastSignature == signature || processingSignature == signature)) {
                    return
                }
                // If user copied from history, clear lastSignature to allow sync
                if (isUserCopyFromHistory) {
                    lastSignature = null // Clear to force sync
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

    /**
     * Force process the current clipboard content.
     * This is useful when clipboard is set from a context where onPrimaryClipChanged
     * might not fire reliably (e.g., ProcessTextActivity on Android 10+).
     * 
     * This will process the clipboard even if the listener is not started.
     */
    fun forceProcessCurrentClipboard() {
        scope.launch(dispatcher) {
            try {
                val clip = clipboardManager.primaryClip
                if (clip != null) {
                    if (!isListening) {
                        Log.d(TAG, "🔄 Force processing clipboard (listener not started, but processing anyway)")
                    } else {
                        Log.d(TAG, "🔄 Force processing current clipboard content")
                    }
                    process(clip)
                } else {
                    Log.w(TAG, "⚠️ Cannot force process: clipboard is null")
                }
            } catch (e: SecurityException) {
                Log.d(TAG, "🔒 Force process: Clipboard access blocked: ${e.message}")
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error force processing clipboard: ${e.message}", e)
            }
        }
    }

    companion object {
        private const val TAG = "ClipboardListener"
    }
}
