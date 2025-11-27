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
    private val syncCoordinator: SyncCoordinator
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
                
                Log.i(TAG, "📥 Received clipboard from deviceId=${senderDeviceId.take(20)}, deviceName=$senderDeviceName, origin=${transportOrigin.name}")
                
                // Check if message was encrypted (non-empty nonce and tag)
                val isEncrypted = envelope.payload.encryption.nonce.isNotEmpty() && envelope.payload.encryption.tag.isNotEmpty()
                
                // Decode the encrypted clipboard payload using key fetched by UUID (device ID)
                // The syncEngine.decode() will fetch the key using envelope.payload.deviceId
                val clipboardPayload = syncEngine.decode(envelope)
                
                // Convert to ClipboardEvent with source device info
                val event = ClipboardEvent(
                    id = java.util.UUID.randomUUID().toString(),
                    type = clipboardPayload.contentType,
                    content = String(java.util.Base64.getDecoder().decode(clipboardPayload.dataBase64)),
                    preview = String(java.util.Base64.getDecoder().decode(clipboardPayload.dataBase64)).take(100),
                    metadata = clipboardPayload.metadata,
                    createdAt = java.time.Instant.now(),
                    sourceDeviceId = senderDeviceId, // ✅ Preserve source device ID
                    sourceDeviceName = senderDeviceName, // ✅ Preserve source device name
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
                    else -> "<unknown>"
                }
                Log.i(TAG, "✅ Decoded clipboard event: type=${event.type}, sourceDevice=$senderDeviceName, content: $contentPreview")
                
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
    
    companion object {
        private const val TAG = "IncomingClipboardHandler"
    }
}

