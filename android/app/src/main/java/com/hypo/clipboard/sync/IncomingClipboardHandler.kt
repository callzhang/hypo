package com.hypo.clipboard.sync

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

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
    private val identity: DeviceIdentity
) {
    private val scope = CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)
    
    /**
     * Callback to show Android system notifications when key is missing or decryption fails.
     * Set by ClipboardSyncService to show system notifications.
     */
    var onDecryptionWarning: ((deviceId: String, deviceName: String, reason: String) -> Unit)? = null
    
    fun handle(envelope: SyncEnvelope, transportOrigin: com.hypo.clipboard.domain.model.TransportOrigin = com.hypo.clipboard.domain.model.TransportOrigin.LAN) {
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
                
                // Also check if senderDeviceId is null - this shouldn't happen but handle it gracefully
                if (senderDeviceId == null) {
                    Log.w(TAG, "⚠️ Received clipboard with null deviceId, skipping")
                    return@launch
                }
                
                Log.d(TAG, "📥 Received clipboard from deviceId=${senderDeviceId.take(20)}, deviceName=$senderDeviceName, origin=${transportOrigin.name}, localDeviceId=${normalizedLocalId.take(20)}")
                
                // Check if message was encrypted (non-empty nonce and tag)
                val encryption = envelope.payload.encryption
                val isEncrypted = encryption != null && encryption.nonce.isNotEmpty() && encryption.tag.isNotEmpty()
                
                // Decode the encrypted clipboard payload using key fetched by UUID (device ID)
                // The syncEngine.decode() will fetch the key using envelope.payload.deviceId
                Log.d(TAG, "🔓 Starting decryption for deviceId=${senderDeviceId?.take(20)}, type=${envelope.type}, payloadSize=${envelope.payload.ciphertext?.length ?: 0}")
                val clipboardPayload = try {
                    syncEngine.decode(envelope)
                } catch (e: Exception) {
                    Log.e(TAG, "❌ Decryption failed in syncEngine.decode(): ${e.javaClass.simpleName}: ${e.message}", e)
                    throw e // Re-throw to be caught by outer catch block
                }
                Log.d(TAG, "✅ Decryption successful: contentType=${clipboardPayload.contentType}, dataSize=${clipboardPayload.dataBase64.length}")
                
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
                        if (contentHash != null && !enhancedMetadata!!.containsKey("hash")) {
                            enhancedMetadata!!["hash"] = contentHash
                        }
                        if (size > 0 && !enhancedMetadata!!.containsKey("size")) {
                            enhancedMetadata!!["size"] = size.toString()
                        }
                        
                        // Debug logging
                        Log.d(TAG, "📏 Size calculation: dataBase64.length=${clipboardPayload.dataBase64.length}, content.length=${content.length}, sizeFromContent=$sizeFromContent, sizeFromMetadata=$sizeFromMetadata, finalSize=$size, hash=${contentHash?.take(8)}")
                        
                        preview = when (clipboardPayload.contentType) {
                            com.hypo.clipboard.domain.model.ClipboardType.IMAGE -> {
                                val width = enhancedMetadata!!["width"] ?: "?"
                                val height = enhancedMetadata!!["height"] ?: "?"
                                val format = enhancedMetadata!!["format"] ?: "image"
                                val fileName = enhancedMetadata!!["file_name"]
                                if (fileName != null) {
                                    "$fileName · ${width}×${height} (${formatBytes(size)})"
                                } else {
                                    "Image ${width}×${height} (${formatBytes(size)})"
                                }
                            }
                            com.hypo.clipboard.domain.model.ClipboardType.FILE -> {
                                val filename = enhancedMetadata!!["file_name"] ?: "file"
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
                    else -> clipboardPayload.metadata
                }
                
                val event = ClipboardEvent(
                    id = java.util.UUID.randomUUID().toString(),
                    type = clipboardPayload.contentType,
                    content = content,
                    preview = preview,
                    metadata = finalMetadata,
                    createdAt = java.time.Instant.now(),
                    deviceId = senderDeviceId.lowercase(), // ✅ Normalize to lowercase for consistent matching
                    deviceName = senderDeviceName,
                    skipBroadcast = true, // ✅ Don't re-broadcast received clipboard
                    isEncrypted = isEncrypted,
                    transportOrigin = transportOrigin
                )
                
                // Extract message content for logging
                val contentPreview = when (event.type) {
                    com.hypo.clipboard.domain.model.ClipboardType.TEXT -> event.content.take(100)
                    com.hypo.clipboard.domain.model.ClipboardType.LINK -> event.content.take(100)
                    com.hypo.clipboard.domain.model.ClipboardType.IMAGE -> "image(${event.content.length} bytes)"
                    com.hypo.clipboard.domain.model.ClipboardType.FILE -> "file(${event.content.length} bytes)"
                }
                Log.d(TAG, "✅ Decoded clipboard event: type=${event.type}, sourceDevice=$senderDeviceName, content: $contentPreview")
                
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
    
    companion object {
        private const val TAG = "IncomingClipboardHandler"
    }
}

