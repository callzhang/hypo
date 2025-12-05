package com.hypo.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.appcompat.app.AppCompatActivity

/**
 * Activity that handles ACTION_PROCESS_TEXT intent.
 * 
 * This allows Hypo to appear as a menu item in the text selection context menu
 * (the toolbar that appears when text is selected) across all apps.
 * 
 * When users select text and tap "Hypo" in the context menu, this activity
 * receives the selected text and copies it to the clipboard, which triggers
 * the clipboard sync mechanism.
 * 
 * The activity finishes immediately after copying to provide a seamless UX.
 */
class ProcessTextActivity : AppCompatActivity() {
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Get the selected text from the intent
        val selectedText = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)
        val isReadOnly = intent.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, false)
        
        if (selectedText.isNullOrBlank()) {
            Log.w(TAG, "⚠️ No text provided in PROCESS_TEXT intent")
            finish()
            return
        }
        
        Log.d(TAG, "📝 Received selected text via PROCESS_TEXT: ${selectedText.take(50)}... (readOnly: $isReadOnly)")
        
        // Copy the selected text to clipboard
        // This will trigger the clipboard listener, which will sync it to other devices
        try {
            val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = ClipData.newPlainText("Selected text", selectedText)
            clipboardManager.setPrimaryClip(clip)
            Log.i(TAG, "✅ Selected text copied to clipboard (${selectedText.length} chars) - will sync to other devices")
            
            // Force process the clipboard immediately to ensure it's processed even if
            // onPrimaryClipChanged doesn't fire (Android 10+ background restrictions)
            // Pass the text directly in the intent to avoid timing issues with clipboard access
            val serviceIntent = Intent(this, com.hypo.clipboard.service.ClipboardSyncService::class.java).apply {
                action = com.hypo.clipboard.service.ClipboardSyncService.ACTION_FORCE_PROCESS_CLIPBOARD
                putExtra("text", selectedText.toString())
            }
            try {
                startForegroundService(serviceIntent)
                Log.d(TAG, "🔄 Triggered force process clipboard")
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Failed to trigger force process (service may not be running): ${e.message}")
                // Continue anyway - polling will catch it within 2 seconds
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to copy selected text to clipboard: ${e.message}", e)
        } finally {
            // Finish immediately for seamless UX
            finish()
        }
    }
    
    companion object {
        private const val TAG = "ProcessTextActivity"
    }
}

