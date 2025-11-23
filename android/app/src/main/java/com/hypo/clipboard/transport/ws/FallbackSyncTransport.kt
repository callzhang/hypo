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
    private val lanTransport: LanWebSocketClient,
    private val cloudTransport: RelayWebSocketClient,
    private val transportManager: TransportManager
) : SyncTransport {

    override suspend fun send(envelope: SyncEnvelope) {
        val targetDeviceId = envelope.payload.target
        
        // Always send to both LAN and cloud simultaneously (best-effort practice)
        // This ensures maximum reliability regardless of discovery status
        android.util.Log.d("FallbackSyncTransport", "📡 Always dual-sending to $targetDeviceId (best-effort practice)")
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
                // Try LAN with timeout (3 seconds)
                withTimeoutOrNull(Duration.ofSeconds(3).toMillis()) {
                    lanTransport.send(envelope)
                    android.util.Log.d("FallbackSyncTransport", "✅ LAN transport succeeded")
                    if (targetDeviceId != null) {
                        transportManager.markDeviceConnected(targetDeviceId, com.hypo.clipboard.transport.ActiveTransport.LAN)
                    }
                    true
                } ?: false
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                android.util.Log.w("FallbackSyncTransport", "⚠️ LAN transport failed: ${e.message}")
                lanError = e
                false
            }
        }
        
        val cloudJob = async {
            try {
                cloudTransport.send(envelope)
                android.util.Log.d("FallbackSyncTransport", "✅ Cloud transport succeeded")
                if (targetDeviceId != null) {
                    transportManager.markDeviceConnected(targetDeviceId, com.hypo.clipboard.transport.ActiveTransport.CLOUD)
                }
                true
            } catch (e: Exception) {
                android.util.Log.w("FallbackSyncTransport", "⚠️ Cloud transport failed: ${e.message}")
                cloudError = e
                false
            }
        }
        
        // Wait for both to complete
        val results = awaitAll(lanJob, cloudJob)
        lanSuccess = results[0]
        cloudSuccess = results[1]
        
        // At least one must succeed
        when {
            lanSuccess && cloudSuccess -> {
                android.util.Log.d("FallbackSyncTransport", "✅ Both LAN and cloud transports succeeded")
            }
            lanSuccess -> {
                android.util.Log.d("FallbackSyncTransport", "✅ LAN transport succeeded (cloud failed)")
            }
            cloudSuccess -> {
                android.util.Log.d("FallbackSyncTransport", "✅ Cloud transport succeeded (LAN failed)")
            }
            else -> {
                // Both failed - throw the most informative error
                val error = cloudError ?: lanError ?: Exception("Both LAN and cloud transports failed")
                android.util.Log.e("FallbackSyncTransport", "❌ Both LAN and cloud transports failed", error)
                throw error
            }
        }
    }
}

