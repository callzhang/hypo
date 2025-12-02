package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.sync.SyncEnvelope
import com.hypo.clipboard.sync.SyncTransport
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull
import java.time.Duration
import kotlin.coroutines.cancellation.CancellationException

/**
 * A SyncTransport that sends to both LAN and cloud simultaneously for maximum reliability.
 * At least one transport must succeed, but both are attempted in parallel.
 */
class FallbackSyncTransport(
    private val lanTransport: WebSocketTransportClient,
    private val cloudTransport: RelayWebSocketClient,
    private val transportManager: TransportManager
) : SyncTransport {

    override suspend fun send(envelope: SyncEnvelope) {
        val targetDeviceId = envelope.payload.target
        sendToBoth(envelope, targetDeviceId)
    }

    /**
     * Send to both LAN and cloud simultaneously.
     * At least one must succeed, but we try both in parallel for maximum reliability.
     */
    private suspend fun sendToBoth(envelope: SyncEnvelope, targetDeviceId: String?) = coroutineScope {
        var lanSuccess = false
        var cloudSuccess = false
        var lanError: Exception? = null
        var cloudError: Exception? = null
        
        // Launch both sends in parallel
        val lanJob = async {
            try {
                withTimeoutOrNull(Duration.ofSeconds(3).toMillis()) {
                    lanTransport.send(envelope)
                    if (targetDeviceId != null) {
                        transportManager.markDeviceConnected(targetDeviceId, com.hypo.clipboard.transport.ActiveTransport.LAN)
                    }
                    true
                } ?: false
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                lanError = e
                false
            }
        }

        val cloudJob = async {
            try {
                cloudTransport.send(envelope)
                if (targetDeviceId != null) {
                    transportManager.markDeviceConnected(targetDeviceId, com.hypo.clipboard.transport.ActiveTransport.CLOUD)
                }
                true
            } catch (e: Exception) {
                cloudError = e
                false
            }
        }
        
        // Wait for both to complete
        val results = awaitAll(lanJob, cloudJob)
        lanSuccess = results[0]
        cloudSuccess = results[1]
        
        // Log combined result
        val result = when {
            lanSuccess && cloudSuccess -> "✅ LAN+Cloud"
            lanSuccess -> "✅ LAN (cloud failed: ${cloudError?.message?.take(30)})"
            cloudSuccess -> "✅ Cloud (LAN failed: ${lanError?.message?.take(30)})"
            else -> "❌ Both failed"
        }
        android.util.Log.d("FallbackSyncTransport", "📡 Dual-send to $targetDeviceId → $result")
        
        // At least one must succeed
        if (!lanSuccess && !cloudSuccess) {
            val error = cloudError ?: lanError ?: Exception("Both LAN and cloud transports failed")
            android.util.Log.e("FallbackSyncTransport", "❌ Dual-send failed: ${error.message}", error)
            throw error
        }
    }
}

