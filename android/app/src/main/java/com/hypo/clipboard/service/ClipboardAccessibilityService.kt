package com.hypo.clipboard.service

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import com.hypo.clipboard.sync.ClipboardEvent
import com.hypo.clipboard.sync.ClipboardParser
import com.hypo.clipboard.sync.signature
import dagger.hilt.android.EntryPointAccessors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.launch

/**
 * Accessibility Service for clipboard monitoring on Android 10+.
 * 
 * This service can access clipboard in the background, bypassing Android 10+ restrictions.
 * Users must explicitly enable this service in Settings → Accessibility.
 * 
 * Note: This is a legitimate use case for accessibility services as it helps users
 * with clipboard synchronization across devices.
 */
class ClipboardAccessibilityService : AccessibilityService() {

    private lateinit var clipboardParser: ClipboardParser
    private var syncCoordinator: com.hypo.clipboard.sync.SyncCoordinator? = null
    
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var lastSignature: String? = null
    private var lastClipboardCheck: Long = 0
    private val clipboardCheckInterval = 500L // Check clipboard every 500ms

    override fun onServiceConnected() {
        super.onServiceConnected()
        
        // Store instance reference for static access
        ClipboardAccessibilityService.instance = this
        
        // Initialize dependencies
        clipboardParser = ClipboardParser(contentResolver)
        
        // Get SyncCoordinator through Hilt EntryPoint
        try {
            val entryPoint = EntryPointAccessors.fromApplication(
                application,
                com.hypo.clipboard.di.ServiceEntryPoint::class.java
            )
            syncCoordinator = entryPoint.syncCoordinator()
            Log.i(TAG, "✅ ClipboardAccessibilityService CONNECTED - can now access clipboard in background!")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to get SyncCoordinator: ${e.message}", e)
            Log.w(TAG, "⚠️ Accessibility service will monitor clipboard but cannot sync (SyncCoordinator unavailable)")
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // Use accessibility events as a trigger to check clipboard
        // This allows us to monitor clipboard even when app is in background
        val now = System.currentTimeMillis()
        if (now - lastClipboardCheck < clipboardCheckInterval) {
            return // Throttle clipboard checks
        }
        lastClipboardCheck = now
        
        try {
            val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            val clip = clipboardManager?.primaryClip ?: return
            
            // Parse clipboard content
            val event = clipboardParser.parse(clip) ?: return
            val signature = event.signature()
            
            // Skip if duplicate
            if (signature == lastSignature) {
                return
            }
            lastSignature = signature
            
            Log.i(TAG, "📋 Accessibility service detected clipboard change: ${event.type}, preview: ${event.preview.take(50)}")
            
            // Forward to sync coordinator if available
            val coordinator = syncCoordinator
            if (coordinator != null) {
                scope.launch {
                    try {
                        coordinator.onClipboardEvent(event)
                        Log.i(TAG, "✅ Clipboard event forwarded to SyncCoordinator")
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Failed to forward clipboard event: ${e.message}", e)
                    }
                }
            } else {
                Log.w(TAG, "⚠️ SyncCoordinator not available, clipboard event not synced")
            }
        } catch (e: SecurityException) {
            // Should not happen with accessibility service, but handle gracefully
            Log.w(TAG, "⚠️ SecurityException in accessibility service: ${e.message}")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error processing clipboard in accessibility service: ${e.message}", e)
        }
    }

    override fun onInterrupt() {
        Log.w(TAG, "⚠️ ClipboardAccessibilityService interrupted")
    }

    override fun onDestroy() {
        super.onDestroy()
        ClipboardAccessibilityService.instance = null
        scope.coroutineContext.cancelChildren()
        Log.i(TAG, "🛑 ClipboardAccessibilityService destroyed")
    }
    
    /**
     * Update system clipboard from Accessibility Service context.
     * This bypasses Android 10+ background clipboard restrictions.
     * 
     * @param item The clipboard item to set
     * @return true if clipboard was updated successfully, false otherwise
     */
    private fun updateClipboard(item: com.hypo.clipboard.domain.model.ClipboardItem): Boolean {
        return try {
            val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                ?: return false
            
            val clip = when (item.type) {
                com.hypo.clipboard.domain.model.ClipboardType.TEXT,
                com.hypo.clipboard.domain.model.ClipboardType.LINK -> {
                    // Use special label to prevent ClipboardListener from processing this update
                    // Same label as regular context update for consistency
                    ClipData.newPlainText("Hypo Remote", item.content)
                }
                com.hypo.clipboard.domain.model.ClipboardType.IMAGE -> {
                    // Images: decode base64, save to temp file, create URI
                    val imageBytes = android.util.Base64.decode(item.content, android.util.Base64.DEFAULT)
                    val format = item.metadata?.get("format") ?: "png"
                    val mimeType = when (format.lowercase()) {
                        "png" -> "image/png"
                        "jpeg", "jpg" -> "image/jpeg"
                        "webp" -> "image/webp"
                        "gif" -> "image/gif"
                        else -> "image/png"
                    }
                    val tempFile = java.io.File.createTempFile("hypo_image", ".$format", cacheDir)
                    java.io.FileOutputStream(tempFile).use { it.write(imageBytes) }
                    tempFile.setReadable(true, false)
                    val uri = androidx.core.content.FileProvider.getUriForFile(
                        this,
                        "${packageName}.fileprovider",
                        tempFile
                    )
                    ClipData.newUri(contentResolver, mimeType, uri)
                }
                com.hypo.clipboard.domain.model.ClipboardType.FILE -> {
                    // Files: decode base64, save to temp file, create URI
                    val fileBytes = android.util.Base64.decode(item.content, android.util.Base64.DEFAULT)
                    val filename = item.metadata?.get("file_name") ?: "file"
                    val mimeType = item.metadata?.get("mime_type") ?: "application/octet-stream"
                    val extension = filename.substringAfterLast('.', "").lowercase()
                    val tempFile = java.io.File.createTempFile("hypo_file", if (extension.isNotEmpty()) ".$extension" else "", cacheDir)
                    java.io.FileOutputStream(tempFile).use { it.write(fileBytes) }
                    tempFile.setReadable(true, false)
                    val uri = androidx.core.content.FileProvider.getUriForFile(
                        this,
                        "${packageName}.fileprovider",
                        tempFile
                    )
                    ClipData.newUri(contentResolver, mimeType, uri)
                }
            }
            
            clipboardManager.setPrimaryClip(clip)
            Log.i(TAG, "✅ Updated clipboard via Accessibility Service: type=${item.type}, preview=${item.preview.take(50)}")
            true
        } catch (e: Exception) {
            Log.w(TAG, "⚠️ Failed to update clipboard via Accessibility Service: ${e.message}", e)
            false
        }
    }

    companion object {
        private const val TAG = "ClipboardAccessibilityService"
        
        // Static reference to the service instance for updating clipboard from other components
        @Volatile
        private var instance: ClipboardAccessibilityService? = null
        
        /**
         * Update system clipboard using Accessibility Service context.
         * This bypasses Android 10+ background clipboard restrictions.
         * 
         * @param item The clipboard item to set
         * @return true if clipboard was updated successfully, false if service is not available
         */
        fun updateClipboard(item: com.hypo.clipboard.domain.model.ClipboardItem): Boolean {
            val service = instance
            return if (service != null) {
                service.updateClipboard(item)
            } else {
                Log.w(TAG, "⚠️ Accessibility Service not available, cannot update clipboard")
                false
            }
        }
    }
}

