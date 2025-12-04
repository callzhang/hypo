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
                val clipboardPayload = syncEngine.decode(envelope)
                
                // For images and files, keep content as base64 string (binary data)
                // For text and links, decode base64 to get the actual text
                val content: String
                val preview: String
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
                        // Keep as base64 string for binary data
                        content = clipboardPayload.dataBase64
                        // Generate preview from metadata
                        val size = clipboardPayload.metadata["size"]?.toLongOrNull() ?: 0L
                        preview = when (clipboardPayload.contentType) {
                            com.hypo.clipboard.domain.model.ClipboardType.IMAGE -> {
                                val width = clipboardPayload.metadata["width"] ?: "?"
                                val height = clipboardPayload.metadata["height"] ?: "?"
                                val format = clipboardPayload.metadata["format"] ?: "image"
                                "Image ${width}×${height} (${formatBytes(size)})"
                            }
                            com.hypo.clipboard.domain.model.ClipboardType.FILE -> {
                                val filename = clipboardPayload.metadata["file_name"] ?: "file"
                                "$filename (${formatBytes(size)})"
                            }
                            else -> "Binary data (${formatBytes(size)})"
                        }
                    }
                }
                
                // Convert to ClipboardEvent with device info (normalized to lowercase)
                val event = ClipboardEvent(
                    id = java.util.UUID.randomUUID().toString(),
                    type = clipboardPayload.contentType,
                    content = content,
                    preview = preview,
                    metadata = clipboardPayload.metadata,
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
                val reason = when {
                    e.message?.contains("decrypt", ignoreCase = true) == true -> "Decryption failed"
                    e.message?.contains("key", ignoreCase = true) == true -> "Invalid encryption key"
                    else -> "Failed to decode message: ${e.message?.take(50) ?: "Unknown error"}"
                }
                
                Log.e(TAG, "❌ Failed to decode clipboard from $deviceName ($deviceId): ${e.message}", e)
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

