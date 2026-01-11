package com.hypo.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.FileProvider
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

/**
 * Activity that handles ACTION_SEND intent for images.
 * 
 * This allows Hypo to appear as a share target when users share images
 * from other apps (e.g., long-press image → Share → Hypo).
 * 
 * When users share an image to Hypo, this activity receives the image URI,
 * copies it to the clipboard, which triggers the clipboard sync mechanism.
 * 
 * The activity finishes immediately after copying to provide a seamless UX.
 */
class ShareImageActivity : AppCompatActivity() {
    
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Handle the shared content
        when (intent.action) {
            Intent.ACTION_SEND -> {
                handleSendImage(intent)
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                Log.w(TAG, "⚠️ Multiple images not supported, processing first image only")
                handleSendMultipleImages(intent)
            }
            else -> {
                Log.w(TAG, "⚠️ Unknown action: ${intent.action}")
                finish()
            }
        }
    }
    
    private fun handleSendImage(intent: Intent) {
        val imageUri: Uri? = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
        
        if (imageUri == null) {
            Log.w(TAG, "⚠️ No image URI provided in ACTION_SEND intent")
            finish()
            return
        }
        
        Log.d(TAG, "📷 Received image via ACTION_SEND: $imageUri")
        
        // Process image in background coroutine
        scope.launch {
            try {
                val imageBytes = readImageUri(imageUri)
                if (imageBytes == null) {
                    Log.e(TAG, "❌ Failed to read image from URI: $imageUri")
                    finish()
                    return@launch
                }
                
                // Determine image format from URI or content type
                val mimeType = contentResolver.getType(imageUri) ?: "image/png"
                val format = mimeType.substringAfterLast("/", "png")
                
                // Copy image to clipboard
                withContext(Dispatchers.Main) {
                    try {
                        val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        
                        // Save image to temp file and create URI
                        val tempFile = File.createTempFile("hypo_image", ".$format", cacheDir)
                        FileOutputStream(tempFile).use { it.write(imageBytes) }
                        tempFile.setReadable(true, false)
                        
                        val fileProviderUri = FileProvider.getUriForFile(
                            this@ShareImageActivity,
                            "${packageName}.fileprovider",
                            tempFile
                        )
                        
                        val clip = ClipData.newUri(contentResolver, mimeType, fileProviderUri)
                        clipboardManager.setPrimaryClip(clip)
                        Log.i(TAG, "✅ Image copied to clipboard (${imageBytes.size} bytes, format: $format) - will sync to other devices")
                        
                        // Force process the clipboard immediately
                        val serviceIntent = Intent(this@ShareImageActivity, com.hypo.clipboard.service.ClipboardSyncService::class.java).apply {
                            action = com.hypo.clipboard.service.ClipboardSyncService.ACTION_FORCE_PROCESS_CLIPBOARD
                            // For images, we can't pass the content directly, so rely on clipboard
                        }
                        try {
                            startForegroundService(serviceIntent)
                            Log.d(TAG, "🔄 Triggered force process clipboard")
                        } catch (e: Exception) {
                            Log.w(TAG, "⚠️ Failed to trigger force process (service may not be running): ${e.message}")
                            // Continue anyway - polling will catch it within 2 seconds
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Failed to copy image to clipboard: ${e.message}", e)
                    } finally {
                        finish()
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ Error processing image: ${e.message}", e)
                finish()
            }
        }
    }
    
    private fun handleSendMultipleImages(intent: Intent) {
        val imageUris: ArrayList<Uri>? = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }
        
        if (imageUris.isNullOrEmpty()) {
            Log.w(TAG, "⚠️ No image URIs provided in ACTION_SEND_MULTIPLE intent")
            finish()
            return
        }
        
        // Process first image only
        handleSendImage(Intent(Intent.ACTION_SEND).apply {
            putExtra(Intent.EXTRA_STREAM, imageUris[0])
        })
    }
    
    private suspend fun readImageUri(uri: Uri): ByteArray? = withContext(Dispatchers.IO) {
        try {
            contentResolver.openInputStream(uri)?.use { inputStream: InputStream ->
                inputStream.readBytes()
            }
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to read image from URI: ${e.message}", e)
            null
        }
    }
    
    companion object {
        private const val TAG = "ShareImageActivity"
    }
}

