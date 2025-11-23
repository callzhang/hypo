package com.hypo.clipboard.sync

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Handles incoming clipboard sync messages from remote devices (e.g., macOS).
 * Decodes the encrypted payload and forwards to SyncCoordinator with source device info preserved.
 */
@Singleton
class IncomingClipboardHandler @Inject constructor(
    private val syncEngine: SyncEngine,
    private val syncCoordinator: SyncCoordinator
) {
    private val scope = CoroutineScope(kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO)
    fun handle(envelope: SyncEnvelope, transportOrigin: com.hypo.clipboard.domain.model.TransportOrigin = com.hypo.clipboard.domain.model.TransportOrigin.LAN) {
        scope.launch {
            try {
                Log.i(TAG, "📥 Received clipboard from deviceId=${envelope.payload.deviceId.take(20)}, deviceName=${envelope.payload.deviceName}, origin=${transportOrigin.name}")
                
                // Check if message was encrypted (non-empty nonce and tag)
                val isEncrypted = envelope.payload.encryption.nonce.isNotEmpty() && envelope.payload.encryption.tag.isNotEmpty()
                
                // Decode the encrypted clipboard payload
                val clipboardPayload = syncEngine.decode(envelope)
                
                // Convert to ClipboardEvent with source device info
                val event = ClipboardEvent(
                    id = java.util.UUID.randomUUID().toString(),
                    type = clipboardPayload.contentType,
                    content = String(java.util.Base64.getDecoder().decode(clipboardPayload.dataBase64)),
                    preview = String(java.util.Base64.getDecoder().decode(clipboardPayload.dataBase64)).take(100),
                    metadata = clipboardPayload.metadata,
                    createdAt = java.time.Instant.now(),
                    sourceDeviceId = envelope.payload.deviceId, // ✅ Preserve source device ID
                    sourceDeviceName = envelope.payload.deviceName, // ✅ Preserve source device name
                    skipBroadcast = true, // ✅ Don't re-broadcast received clipboard
                    isEncrypted = isEncrypted,
                    transportOrigin = transportOrigin
                )
                
                Log.i(TAG, "✅ Decoded clipboard event: type=${event.type}, sourceDevice=${event.sourceDeviceName}")
                
                // Forward to coordinator (will use source device info instead of local)
                syncCoordinator.onClipboardEvent(event)
                
            } catch (e: Exception) {
                Log.e(TAG, "❌ Failed to handle incoming clipboard: ${e.message}", e)
            }
        }
    }
    
    companion object {
        private const val TAG = "IncomingClipboardHandler"
    }
}

