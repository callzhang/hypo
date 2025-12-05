package com.hypo.clipboard.util

import android.content.ClipboardManager
import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File

/**
 * Clipboard change listener for temp file cleanup
 */
private class ClipboardChangeListener(
    private val onClipboardChanged: () -> Unit
) : ClipboardManager.OnPrimaryClipChangedListener {
    override fun onPrimaryClipChanged() {
        onClipboardChanged()
    }
}

/**
 * Manages temporary files created for clipboard operations.
 * 
 * Features:
 * - Automatic cleanup after a delay (30 seconds)
 * - Cleanup when clipboard changes
 * - Periodic cleanup of old temp files
 * - Prevents disk space accumulation
 */
class TempFileManager(
    private val context: Context,
    private val scope: CoroutineScope,
    private val clipboardManager: ClipboardManager? = null
) {
    private val tempFiles = mutableSetOf<File>()
    private val cleanupJobs = mutableMapOf<File, Job>()
    private var periodicCleanupJob: Job? = null
    private var clipboardListener: ClipboardChangeListener? = null
    
    companion object {
        private const val TAG = "TempFileManager"
        private const val CLEANUP_DELAY_MS = 300_000L // 5 minutes - increased to ensure clipboard can access files
        private const val PERIODIC_CLEANUP_INTERVAL_MS = 60_000L // 1 minute
        private const val MAX_TEMP_FILE_AGE_MS = 600_000L // 10 minutes - increased to prevent premature cleanup
    }
    
    init {
        // Start periodic cleanup
        startPeriodicCleanup()
        
        // Listen to clipboard changes if clipboardManager is provided
        // Note: We don't immediately clean up on clipboard change because the clipboard
        // system needs to access the file via ContentResolver. Files are cleaned up
        // after CLEANUP_DELAY_MS (30 seconds) or during periodic cleanup.
        clipboardManager?.let { manager ->
            clipboardListener = ClipboardChangeListener {
                // Don't clean up immediately - the clipboard system needs to access the file
                // Files will be cleaned up after CLEANUP_DELAY_MS or during periodic cleanup
                Log.d(TAG, "📋 Clipboard changed, but not cleaning up temp files immediately (they may still be in use)")
            }
            manager.addPrimaryClipChangedListener(clipboardListener)
        }
    }
    
    /**
     * Register a temporary file for automatic cleanup.
     * The file will be deleted after CLEANUP_DELAY_MS or when clipboard changes.
     */
    fun registerTempFile(file: File) {
        synchronized(tempFiles) {
            tempFiles.add(file)
            Log.d(TAG, "📁 Registered temp file: ${file.name} (${tempFiles.size} total)")
            
            // Schedule cleanup after delay
            val cleanupJob = scope.launch(Dispatchers.IO) {
                delay(CLEANUP_DELAY_MS)
                if (isActive && tempFiles.contains(file)) {
                    cleanupFile(file)
                }
            }
            cleanupJobs[file] = cleanupJob
        }
    }
    
    /**
     * Immediately cleanup a specific file.
     */
    fun cleanupFile(file: File) {
        synchronized(tempFiles) {
            try {
                if (!file.exists()) {
                    return@synchronized
                }
                if (file.delete()) {
                    tempFiles.remove(file)
                    cleanupJobs.remove(file)?.cancel()
                    Log.d(TAG, "🗑️ Cleaned up temp file: ${file.name}")
                } else {
                    Log.w(TAG, "⚠️ Failed to delete temp file ${file.name}")
                }
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Failed to cleanup temp file ${file.name}: ${e.message}")
            }
        }
    }
    
    /**
     * Cleanup all registered temp files.
     */
    fun cleanupAll() {
        synchronized(tempFiles) {
            val filesToCleanup = tempFiles.toList()
            Log.d(TAG, "🧹 Cleaning up ${filesToCleanup.size} temp files")
            filesToCleanup.forEach { cleanupFile(it) }
        }
    }
    
    /**
     * Start periodic cleanup of old temp files in cache directory.
     */
    private fun startPeriodicCleanup() {
        periodicCleanupJob?.cancel()
        periodicCleanupJob = scope.launch(Dispatchers.IO) {
            while (isActive) {
                delay(PERIODIC_CLEANUP_INTERVAL_MS)
                cleanupOldTempFiles()
            }
        }
    }
    
    /**
     * Cleanup old temp files in the cache directory that match our pattern.
     */
    private fun cleanupOldTempFiles() {
        try {
            val cacheDir = context.cacheDir
            val now = System.currentTimeMillis()
            var cleanedCount = 0
            
            cacheDir.listFiles()?.forEach { file ->
                // Check if it's a temp file we created (starts with hypo_)
                if (file.name.startsWith("hypo_") && file.isFile) {
                    val age = now - file.lastModified()
                    if (age > MAX_TEMP_FILE_AGE_MS) {
                        try {
                            if (file.delete()) {
                                cleanedCount++
                                synchronized(tempFiles) {
                                    tempFiles.remove(file)
                                    cleanupJobs.remove(file)?.cancel()
                                }
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Failed to delete old temp file ${file.name}: ${e.message}")
                        }
                    }
                }
            }
            
            if (cleanedCount > 0) {
                Log.d(TAG, "🧹 Periodic cleanup: removed $cleanedCount old temp files")
            }
        } catch (e: Exception) {
            Log.w(TAG, "⚠️ Error during periodic cleanup: ${e.message}")
        }
    }
    
    /**
     * Cleanup on app lifecycle events (call from Activity/Service onDestroy).
     * Note: OnPrimaryClipChangedListener doesn't have a remove method in older Android APIs.
     * The listener will be automatically removed when the ClipboardManager is destroyed.
     */
    fun onDestroy() {
        periodicCleanupJob?.cancel()
        // Note: removePrimaryClipChangedListener is not available in all Android versions
        // The listener will be automatically cleaned up when the ClipboardManager is destroyed
        clipboardListener = null
        cleanupAll()
    }
}

