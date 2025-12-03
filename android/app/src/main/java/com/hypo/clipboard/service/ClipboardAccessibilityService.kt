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
            val clipboardEvent = clipboardParser.parse(clip) ?: return
            val signature = clipboardEvent.signature()
            
            // Skip if duplicate
            if (signature == lastSignature) {
                return
            }
            lastSignature = signature
            
            Log.i(TAG, "📋 Accessibility service detected clipboard change: ${clipboardEvent.type}, preview: ${clipboardEvent.content.take(50)}")
            
            // Forward to sync coordinator if available
            val coordinator = syncCoordinator
            if (coordinator != null) {
                scope.launch {
                    try {
                        coordinator.onClipboardEvent(clipboardEvent)
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
        scope.coroutineContext.cancelChildren()
        Log.i(TAG, "🛑 ClipboardAccessibilityService destroyed")
    }

    companion object {
        private const val TAG = "ClipboardAccessibilityService"
    }
}

