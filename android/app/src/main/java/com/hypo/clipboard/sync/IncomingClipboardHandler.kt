package com.hypo.clipboard.sync

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.util.Log
import androidx.core.content.FileProvider
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.locks.ReentrantLock
import javax.inject.Inject
import javax.inject.Singleton

// Extension function for ReentrantLock to use withLock syntax
private inline fun <T> ReentrantLock.withLock(action: () -> T): T {
    lock()
    return try {
        action()
    } finally {
        unlock()
    }
}

/**
 * Handles incoming clipboard sync messages from remote devices (e.g., macOS).
 * Decodes the encrypted payload and forwards to SyncCoordinator with source device info preserved.
 * 
 * Messages are verified using UUID/key pairs:
 * - Key is fetched from local store using sender's device ID (UUID)
 * - If key not found or decryption fails, shows Android system notification
 */
@Singleton
class IncomingClipboardHandler @Inject constructor(
    private val syncEngine: SyncEngine,
    private val syncCoordinator: SyncCoordinator,
    private val identity: DeviceIdentity,
    private val accessibilityServiceChecker: com.hypo.clipboard.util.AccessibilityServiceChecker,
    @ApplicationContext private val context: Context
) {
    private val scope = CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)
    
    /**
     * Callback to show Android system notifications when key is missing or decryption fails.
     * Set by ClipboardSyncService to show system notifications.
     */
    var onDecryptionWarning: ((deviceId: String, deviceName: String, reason: String) -> Unit)? = null
    
    // Track processed message IDs to prevent duplicate processing
    // Same message may arrive on multiple WebSocket connections (LAN send/receive, cloud, etc.)
    // AES-GCM nonces must be unique - same encrypted message can only be decrypted once
    private val processedMessageIds = mutableSetOf<String>()
    private val processedMessageIdsLock = java.util.concurrent.locks.ReentrantLock()
    private val processedMessageIdsTtl = java.time.Duration.ofMinutes(5) // Keep IDs for 5 minutes
    private var lastCleanupTime = java.time.Instant.now()
    
    // Cache decrypted payloads for duplicate message IDs
    // When same message ID arrives again, reuse cached payload to move item to top (without re-decrypting)
    private data class CachedPayload(
        val clipboardPayload: ClipboardPayload,
        val senderDeviceId: String,
        val senderDeviceName: String?,
        val transportOrigin: com.hypo.clipboard.domain.model.TransportOrigin,
        val cachedAt: java.time.Instant
    )
    private val cachedPayloads = mutableMapOf<String, CachedPayload>()
    private val cachedPayloadsLock = java.util.concurrent.locks.ReentrantLock()
    private val cachedPayloadsTtl = java.time.Duration.ofMinutes(5) // Keep cached payloads for 5 minutes
    
    // Track processed nonces to prevent duplicate decryption attempts
    // macOS may send the same content multiple times with different message IDs but same nonce
    // Format: "deviceId:nonceHex" -> timestamp
    private val processedNonces = mutableMapOf<String, java.time.Instant>()
    private val processedNoncesLock = java.util.concurrent.locks.ReentrantLock()
    private val processedNoncesTtl = java.time.Duration.ofMinutes(5) // Keep nonces for 5 minutes
    
    fun handle(envelope: SyncEnvelope, transportOrigin: com.hypo.clipboard.domain.model.TransportOrigin = com.hypo.clipboard.domain.model.TransportOrigin.LAN) {
        // Check for duplicate message ID BEFORE launching coroutine
        // Same message may arrive on multiple WebSocket connections
        // This must be synchronous to prevent race conditions
        val messageId = envelope.id
        val shouldProcess = processedMessageIdsLock.withLock {
            // Periodic cleanup of old message IDs
            val now = java.time.Instant.now()
            if (java.time.Duration.between(lastCleanupTime, now) > java.time.Duration.ofMinutes(1)) {
                // Cleanup happens implicitly - we only keep recent IDs
                // For simplicity, we'll just clear if set gets too large (>1000)
                if (processedMessageIds.size > 1000) {
                    processedMessageIds.clear()
                    Log.d(TAG, "🧹 Cleared processed message IDs cache (size exceeded 1000)")
                }
                lastCleanupTime = now
            }
            
            // Check if we've already processed this message
            val isDuplicate = processedMessageIds.contains(messageId)
            if (isDuplicate) {
                // Duplicate detected - will check for cached payload below
                false // Don't mark as processed yet, we'll check cache
            } else {
                // Mark as processed before attempting decryption
                // This prevents multiple decryption attempts for the same message
                processedMessageIds.add(messageId)
                true
            }
        }
        
        // Check if we have a cached payload for this duplicate message ID
        // If yes, we'll use it to move the item to the top without re-decrypting
        val cachedPayload = if (!shouldProcess) {
            cachedPayloadsLock.withLock {
                val now = java.time.Instant.now()
                // Cleanup old cached payloads
                val cutoff = now.minus(cachedPayloadsTtl)
                cachedPayloads.entries.removeAll { it.value.cachedAt.isBefore(cutoff) }
                
                cachedPayloads[messageId]
            }
        } else {
            null
        }
        
        // If duplicate and no cached payload, skip (can't decrypt again due to nonce reuse)
        if (!shouldProcess && cachedPayload == null) {
            return
        }
        
        // Check for duplicate nonce BEFORE attempting decryption (synchronously, outside coroutine)
        // macOS may send same content with different message IDs but reuse nonces
        // Also handles race condition: same message arriving on multiple connections simultaneously
        val encryption = envelope.payload.encryption
        val senderDeviceId = envelope.payload.deviceId
        val isDuplicateNonce = if (encryption != null && !encryption.nonce.isEmpty() && senderDeviceId != null) {
            val nonceBytes = try {
                java.util.Base64.getDecoder().decode(encryption.nonce)
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Failed to decode nonce for duplicate check: ${e.message}")
                null
            }
            val nonceHex = nonceBytes?.joinToString("") { "%02x".format(it) } ?: ""
            val nonceKey = "${senderDeviceId.lowercase()}:$nonceHex"
            processedNoncesLock.withLock {
                val now = java.time.Instant.now()
                // Cleanup old nonces
                val cutoff = now.minus(processedNoncesTtl)
                processedNonces.entries.removeAll { it.value.isBefore(cutoff) }
                
                val existing = processedNonces[nonceKey]
                if (existing != null) {
                    Log.w(TAG, "⚠️ Duplicate nonce detected: deviceId=${senderDeviceId.take(20)}..., nonce=${nonceHex.take(16)}..., first seen at $existing, skipping decryption")
                    true
                } else {
                    processedNonces[nonceKey] = now
                    false
                }
            }
        } else {
            false
        }
        
        if (isDuplicateNonce) {
            Log.w(TAG, "⏭️ Skipping message with duplicate nonce: id=${messageId.take(8)}...")
            return
        }
        
        // Capture cached payload before launching coroutine
        val cachedPayloadForThisMessage = cachedPayload
        
        scope.launch {
            try {
                val senderDeviceId = envelope.payload.deviceId
                val senderDeviceName = envelope.payload.deviceName
                
                // Normalize device IDs to lowercase for comparison
                val normalizedSenderId = senderDeviceId?.lowercase()
                val normalizedLocalId = identity.deviceId.lowercase()
                
                // Log device IDs for debugging
                Log.d(TAG, "🔍 Checking device IDs - sender: $normalizedSenderId, local: $normalizedLocalId")
                
                // Filter out messages from our own device ID (prevent echo loops)
                if (normalizedSenderId != null && normalizedSenderId == normalizedLocalId) {
                    Log.d(TAG, "⏭️ Skipping clipboard from own device ID: $normalizedSenderId (preventing echo loop)")
                    return@launch
                }
                
                // Use cached payload if available (for duplicate message IDs), otherwise decrypt
                val clipboardPayload: ClipboardPayload
                val finalSenderDeviceId: String
                val finalSenderDeviceName: String?
                val finalTransportOrigin: com.hypo.clipboard.domain.model.TransportOrigin
                val isEncrypted: Boolean
                
                if (cachedPayloadForThisMessage != null) {
                    Log.d(TAG, "🔄 Using cached payload for duplicate message ID: id=${messageId.take(8)}... (to move item to top)")
                    clipboardPayload = cachedPayloadForThisMessage.clipboardPayload
                    finalSenderDeviceId = cachedPayloadForThisMessage.senderDeviceId
                    finalSenderDeviceName = cachedPayloadForThisMessage.senderDeviceName
                    finalTransportOrigin = cachedPayloadForThisMessage.transportOrigin
                    // Check if message was encrypted (non-empty nonce and tag)
                    val encryption = envelope.payload.encryption
                    isEncrypted = encryption != null && encryption.nonce.isNotEmpty() && encryption.tag.isNotEmpty()
                    Log.d(TAG, "📥 Using cached clipboard from deviceId=${finalSenderDeviceId.take(20)}, deviceName=$finalSenderDeviceName, origin=${finalTransportOrigin.name}, localDeviceId=${normalizedLocalId.take(20)}")
                } else {
                    // Also check if senderDeviceId is null - this shouldn't happen but handle it gracefully
                    if (senderDeviceId == null) {
                        Log.w(TAG, "⚠️ Received clipboard with null deviceId, skipping")
                        return@launch
                    }
                    
                    Log.d(TAG, "📥 Received clipboard from deviceId=${senderDeviceId.take(20)}, deviceName=$senderDeviceName, origin=${transportOrigin.name}, localDeviceId=${normalizedLocalId.take(20)}")
                    
                    // Check if message was encrypted (non-empty nonce and tag)
                    val encryption = envelope.payload.encryption
                    isEncrypted = encryption != null && encryption.nonce.isNotEmpty() && encryption.tag.isNotEmpty()
                    
                    // Decode the encrypted clipboard payload using key fetched by UUID (device ID)
                    // The syncEngine.decode() will fetch the key using envelope.payload.deviceId
                    val deviceIdPreview = senderDeviceId.take(20)
                    val payloadSize = envelope.payload.ciphertext?.length ?: 0
                    Log.d(TAG, "🔓 Starting decryption for deviceId=$deviceIdPreview, type=${envelope.type}, payloadSize=$payloadSize")
                    clipboardPayload = try {
                        syncEngine.decode(envelope)
                    } catch (e: Exception) {
                        Log.e(TAG, "❌ Decryption failed in syncEngine.decode(): ${e.javaClass.simpleName}: ${e.message}", e)
                        throw e // Re-throw to be caught by outer catch block
                    }
                    Log.d(TAG, "✅ Decryption successful: contentType=${clipboardPayload.contentType}, dataSize=${clipboardPayload.dataBase64.length}")
                    
                    // Cache the decrypted payload for future duplicate message IDs
                    cachedPayloadsLock.withLock {
                        val now = java.time.Instant.now()
                        // Cleanup old cached payloads
                        val cutoff = now.minus(cachedPayloadsTtl)
                        cachedPayloads.entries.removeAll { it.value.cachedAt.isBefore(cutoff) }
                        
                        cachedPayloads[messageId] = CachedPayload(
                            clipboardPayload = clipboardPayload,
                            senderDeviceId = senderDeviceId,
                            senderDeviceName = senderDeviceName,
                            transportOrigin = transportOrigin,
                            cachedAt = now
                        )
                        Log.d(TAG, "💾 Cached payload for message ID: id=${messageId.take(8)}..., cache size=${cachedPayloads.size}")
                    }
                    
                    finalSenderDeviceId = senderDeviceId
                    finalSenderDeviceName = senderDeviceName
                    finalTransportOrigin = transportOrigin
                }
                
                // For images and files, keep content as base64 string (binary data)
                // For text and links, decode base64 to get the actual text
                val content: String
                val preview: String
                var enhancedMetadata: MutableMap<String, String>? = null // For IMAGE/FILE types with hash and size
                when (clipboardPayload.contentType) {
                    com.hypo.clipboard.domain.model.ClipboardType.TEXT,
                    com.hypo.clipboard.domain.model.ClipboardType.LINK -> {
                        // Decode base64 to get text content
                        val decoded = java.util.Base64.getDecoder().decode(clipboardPayload.dataBase64)
                        content = String(decoded, Charsets.UTF_8)
                        preview = content.take(100)
                    }
                    com.hypo.clipboard.domain.model.ClipboardType.IMAGE,
                    com.hypo.clipboard.domain.model.ClipboardType.FILE -> {
                        // Content should already be base64-encoded binary data
                        // ClipboardParser extracts binary data from URIs when creating local clipboard events,
                        // so incoming messages should never contain URIs (which wouldn't be accessible anyway)
                        content = clipboardPayload.dataBase64
                        
                        // Calculate size from base64 content
                        // Base64 encoding: 4 chars represent 3 bytes, so original size ≈ base64_length * 3/4
                        // But we need to account for padding (base64 strings may have = padding)
                        val sizeFromMetadata = clipboardPayload.metadata?.get("size")?.toLongOrNull()
                        val sizeFromContent = if (content.isNotEmpty()) {
                            // Remove padding characters for accurate calculation
                            val base64WithoutPadding = content.trimEnd('=')
                            // Calculate: base64 chars represent 3 bytes per 4 chars
                            // For every 4 base64 chars, we get 3 bytes
                            val estimatedBytes = (base64WithoutPadding.length * 3L / 4L)
                            estimatedBytes
                        } else {
                            0L
                        }
                        val size = sizeFromMetadata ?: sizeFromContent
                        
                        // Calculate hash for duplication detection (macOS doesn't send hash)
                        val contentHash = if (content.isNotEmpty()) {
                            try {
                                // Content is now base64-encoded binary data (after URI extraction if needed)
                                val bytes = java.util.Base64.getDecoder().decode(content)
                                val digest = java.security.MessageDigest.getInstance("SHA-256")
                                val hashBytes = digest.digest(bytes)
                                hashBytes.joinToString("") { "%02x".format(it) }
                            } catch (e: Exception) {
                                Log.w(TAG, "⚠️ Failed to calculate hash for ${clipboardPayload.contentType}: ${e.message}")
                                null
                            }
                        } else {
                            null
                        }
                        
                        // Add hash and size to metadata if not present (for duplication detection and size display)
                        enhancedMetadata = clipboardPayload.metadata?.toMutableMap() ?: mutableMapOf()
                        if (contentHash != null && !enhancedMetadata.containsKey("hash")) {
                            enhancedMetadata["hash"] = contentHash
                        }
                        if (size > 0 && !enhancedMetadata.containsKey("size")) {
                            enhancedMetadata["size"] = size.toString()
                        }
                        
                        // Debug logging
                        Log.d(TAG, "📏 Size calculation: dataBase64.length=${clipboardPayload.dataBase64.length}, content.length=${content.length}, sizeFromContent=$sizeFromContent, sizeFromMetadata=$sizeFromMetadata, finalSize=$size, hash=${contentHash?.take(8)}")
                        
                        preview = when (clipboardPayload.contentType) {
                            com.hypo.clipboard.domain.model.ClipboardType.IMAGE -> {
                                val width = enhancedMetadata["width"] ?: "?"
                                val height = enhancedMetadata["height"] ?: "?"
                                val fileName = enhancedMetadata["file_name"]
                                if (fileName != null) {
                                    "$fileName · ${width}×${height} (${formatBytes(size)})"
                                } else {
                                    "Image ${width}×${height} (${formatBytes(size)})"
                                }
                            }
                            com.hypo.clipboard.domain.model.ClipboardType.FILE -> {
                                val filename = enhancedMetadata["file_name"] ?: "file"
                                "$filename (${formatBytes(size)})"
                            }
                            else -> "Binary data (${formatBytes(size)})"
                        }
                    }
                }
                
                // Convert to ClipboardEvent with device info (normalized to lowercase)
                // For IMAGE/FILE types, use enhanced metadata (with hash and size) that was created above
                val finalMetadata = when (clipboardPayload.contentType) {
                    com.hypo.clipboard.domain.model.ClipboardType.IMAGE,
                    com.hypo.clipboard.domain.model.ClipboardType.FILE -> {
                        // Use enhancedMetadata that was created in the when block above
                        enhancedMetadata ?: clipboardPayload.metadata?.toMutableMap() ?: mutableMapOf()
                    }
                    else -> clipboardPayload.metadata ?: emptyMap()
                }
                
                val event = ClipboardEvent(
                    id = java.util.UUID.randomUUID().toString(),
                    type = clipboardPayload.contentType,
                    content = content,
                    preview = preview,
                    metadata = finalMetadata,
                    createdAt = java.time.Instant.now(),
                    deviceId = finalSenderDeviceId.lowercase(), // ✅ Normalize to lowercase for consistent matching
                    deviceName = finalSenderDeviceName,
                    skipBroadcast = true, // ✅ Don't re-broadcast received clipboard
                    isEncrypted = isEncrypted,
                    transportOrigin = finalTransportOrigin
                )
                
                // Extract message content for logging
                val contentPreview = when (event.type) {
                    com.hypo.clipboard.domain.model.ClipboardType.TEXT -> event.content.take(100)
                    com.hypo.clipboard.domain.model.ClipboardType.LINK -> event.content.take(100)
                    com.hypo.clipboard.domain.model.ClipboardType.IMAGE -> "image(${event.content.length} bytes)"
                    com.hypo.clipboard.domain.model.ClipboardType.FILE -> "file(${event.content.length} bytes)"
                }
                Log.d(TAG, "✅ Decoded clipboard event: type=${event.type}, sourceDevice=$senderDeviceName, content: $contentPreview")
                
                // Always try to update system clipboard (same mechanism as macOS)
                // If Accessibility Service is enabled, it will succeed in background
                // If not enabled, it may fail in background (Android 10+ restriction) but will work in foreground
                val clipboardItem = com.hypo.clipboard.domain.model.ClipboardItem(
                    id = java.util.UUID.randomUUID().toString(),
                    type = clipboardPayload.contentType,
                    content = content,
                    preview = preview,
                    metadata = finalMetadata,
                    deviceId = finalSenderDeviceId.lowercase(),
                    deviceName = finalSenderDeviceName,
                    createdAt = java.time.Instant.now(),
                    isPinned = false
                )
                updateSystemClipboard(clipboardItem)
                
                // Forward to coordinator (will use source device info instead of local)
                syncCoordinator.onClipboardEvent(event)
                
            } catch (e: SyncEngineException.MissingKey) {
                // Key not found for sender's device ID (UUID)
                val deviceId = e.message?.substringAfter("No symmetric key registered for ")?.take(36) ?: envelope.payload.deviceId ?: "unknown"
                val deviceName = envelope.payload.deviceName ?: "Unknown Device"
                val reason = "Encryption key not found for device"
                
                Log.e(TAG, "❌ Missing key for device: $deviceId ($deviceName)")
                onDecryptionWarning?.invoke(deviceId, deviceName, reason)
                
            } catch (e: Exception) {
                // Decryption failed or other error
                val deviceId = envelope.payload.deviceId ?: "unknown"
                val deviceName = envelope.payload.deviceName ?: "Unknown Device"
                val exceptionType = e.javaClass.simpleName
                val exceptionMessage = e.message ?: "No error message"
                
                // Check for specific decryption errors
                val reason = when {
                    e is java.security.GeneralSecurityException -> "Decryption failed: ${e.message}"
                    e.message?.contains("decrypt", ignoreCase = true) == true -> "Decryption failed: ${e.message}"
                    e.message?.contains("key", ignoreCase = true) == true -> "Invalid encryption key: ${e.message}"
                    e.message?.contains("BAD_DECRYPT", ignoreCase = true) == true -> "Decryption authentication failed (BAD_DECRYPT)"
                    e.message?.contains("AEADBadTagException", ignoreCase = true) == true -> "Decryption tag verification failed"
                    e.message?.contains("Missing", ignoreCase = true) == true -> "Missing data: ${e.message}"
                    e.message?.contains("IllegalArgument", ignoreCase = true) == true -> "Invalid payload: ${e.message}"
                    else -> "Failed to decode: ${exceptionMessage.take(80)}"
                }
                
                // Log comprehensive error in main line for easier filtering
                Log.e(TAG, "❌ Failed to decode clipboard from $deviceName ($deviceId): $exceptionType - $reason")
                
                // Additional detailed logging for debugging
                Log.e(TAG, "   Exception type: $exceptionType")
                Log.e(TAG, "   Exception message: $exceptionMessage")
                Log.e(TAG, "   Envelope type: ${envelope.type}, payload size: ${envelope.payload.ciphertext?.length ?: 0}")
                if (e.stackTrace.isNotEmpty()) {
                    Log.e(TAG, "   Stack trace: ${e.stackTrace.take(3).joinToString(" -> ") { "${it.className}.${it.methodName}:${it.lineNumber}" }}")
                }
                
                onDecryptionWarning?.invoke(deviceId, deviceName, reason)
            }
        }
    }
    
    private fun formatBytes(size: Long): String {
        if (size < 1024) return "$size B"
        val kb = size / 1024.0
        if (kb < 1024) return String.format("%.1f KB", kb)
        val mb = kb / 1024.0
        if (mb < 1024) return String.format("%.1f MB", mb)
        val gb = mb / 1024.0
        return String.format("%.1f GB", gb)
    }
    
    /**
     * Update system clipboard with received item (same mechanism as macOS).
     * Always attempts to update clipboard:
     * - If Accessibility Service is enabled: uses Accessibility Service context (works in background)
     * - If not enabled: uses regular context (works in foreground, may fail in background on Android 10+)
     * 
     * Uses "Hypo Remote" label to prevent ClipboardListener from processing this update.
     */
    private fun updateSystemClipboard(item: com.hypo.clipboard.domain.model.ClipboardItem) {
        scope.launch(Dispatchers.IO) {
            try {
                // Try Accessibility Service first if enabled (works in background)
                if (accessibilityServiceChecker.isAccessibilityServiceEnabled()) {
                    val updated = com.hypo.clipboard.service.ClipboardAccessibilityService.updateClipboard(item)
                    if (updated) {
                        Log.d(TAG, "✅ Updated system clipboard via Accessibility Service")
                        return@launch
                    }
                }
                
                // Fallback to regular context update (works in foreground, may fail in background)
                val clipboardManager = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                    ?: return@launch
                
                val clip = when (item.type) {
                    com.hypo.clipboard.domain.model.ClipboardType.TEXT,
                    com.hypo.clipboard.domain.model.ClipboardType.LINK -> {
                        ClipData.newPlainText("Hypo Remote", item.content)
                    }
                    com.hypo.clipboard.domain.model.ClipboardType.IMAGE -> {
                        val imageBytes = android.util.Base64.decode(item.content, android.util.Base64.DEFAULT)
                        val format = item.metadata?.get("format") ?: "png"
                        val mimeType = when (format.lowercase()) {
                            "png" -> "image/png"
                            "jpeg", "jpg" -> "image/jpeg"
                            "webp" -> "image/webp"
                            "gif" -> "image/gif"
                            else -> "image/png"
                        }
                        val tempFile = java.io.File.createTempFile("hypo_image", ".$format", context.cacheDir)
                        java.io.FileOutputStream(tempFile).use { it.write(imageBytes) }
                        tempFile.setReadable(true, false)
                        val uri = FileProvider.getUriForFile(
                            context,
                            "${context.packageName}.fileprovider",
                            tempFile
                        )
                        ClipData.newUri(context.contentResolver, mimeType, uri)
                    }
                    com.hypo.clipboard.domain.model.ClipboardType.FILE -> {
                        val fileBytes = android.util.Base64.decode(item.content, android.util.Base64.DEFAULT)
                        val filename = item.metadata?.get("file_name") ?: "file"
                        val mimeType = item.metadata?.get("mime_type") ?: "application/octet-stream"
                        val extension = filename.substringAfterLast('.', "").lowercase()
                        val tempFile = java.io.File.createTempFile("hypo_file", if (extension.isNotEmpty()) ".$extension" else "", context.cacheDir)
                        java.io.FileOutputStream(tempFile).use { it.write(fileBytes) }
                        tempFile.setReadable(true, false)
                        val uri = FileProvider.getUriForFile(
                            context,
                            "${context.packageName}.fileprovider",
                            tempFile
                        )
                        ClipData.newUri(context.contentResolver, mimeType, uri)
                    }
                }
                
                withContext(Dispatchers.Main) {
                    try {
                        clipboardManager.setPrimaryClip(clip)
                        Log.d(TAG, "✅ Updated system clipboard: type=${item.type}, preview=${item.preview.take(50)}")
                    } catch (e: SecurityException) {
                        // Android 10+ may block clipboard access in background
                        Log.d(TAG, "🔒 Failed to update clipboard in background (Android 10+ restriction). Enable Accessibility Service in Settings to allow background updates: ${e.message}")
                    } catch (e: Exception) {
                        Log.w(TAG, "⚠️ Failed to update system clipboard: ${e.message}", e)
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "⚠️ Error updating system clipboard: ${e.message}", e)
            }
        }
    }
    
    companion object {
        private const val TAG = "IncomingClipboardHandler"
    }
}

