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
 * A SyncTransport that sends to both LAN (all peers) and cloud simultaneously for maximum reliability.
 * Maintains separate connections for each peer, mirroring macOS architecture.
 * At least one transport must succeed, but all are attempted in parallel.
 */
class FallbackSyncTransport(
    private val lanPeerConnectionManager: LanPeerConnectionManager,
    private val cloudTransport: RelayWebSocketClient,
    private val transportManager: TransportManager
) : SyncTransport {

    override suspend fun send(envelope: SyncEnvelope) {
        val targetDeviceId = envelope.payload.target
        sendToAll(envelope, targetDeviceId)
    }

    /**
     * Send to all LAN peers and cloud simultaneously.
     * For targeted messages (targetDeviceId != null), sends to that specific peer + cloud.
     * For broadcast messages (targetDeviceId == null), sends to all peers + cloud.
     * At least one must succeed, but all are attempted in parallel.
     */
    private suspend fun sendToAll(envelope: SyncEnvelope, targetDeviceId: String?) = coroutineScope {
        var lanSuccess = false
        var cloudSuccess = false
        var lanError: Exception? = null
        var cloudError: Exception? = null
        
        // Launch LAN send(s) and cloud send in parallel
        val lanJob = async {
            try {
                withTimeoutOrNull(Duration.ofSeconds(3).toMillis()) {
                    if (targetDeviceId != null) {
                        // Send to specific peer
                        val success = lanPeerConnectionManager.sendToPeer(targetDeviceId, envelope)
                        if (success) {
                            transportManager.markDeviceConnected(targetDeviceId, com.hypo.clipboard.transport.ActiveTransport.LAN)
                        }
                        success
                    } else {
                        // Send to all peers
                        val successCount = lanPeerConnectionManager.sendToAllPeers(envelope)
                        successCount > 0
                    }
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

