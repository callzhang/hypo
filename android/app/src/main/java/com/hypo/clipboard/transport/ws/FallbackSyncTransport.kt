package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.sync.SyncEnvelope
import com.hypo.clipboard.sync.SyncTransport
import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import kotlinx.coroutines.withTimeoutOrNull
import java.time.Duration
import kotlin.coroutines.cancellation.CancellationException

/**
 * A SyncTransport that implements LAN-first, cloud-fallback strategy.
 * Tries LAN connection first, falls back to cloud if LAN is unavailable.
 */
class FallbackSyncTransport(
    private val lanTransport: LanWebSocketClient,
    private val cloudTransport: RelayWebSocketClient,
    private val transportManager: TransportManager
) : SyncTransport {

    override suspend fun send(envelope: SyncEnvelope) {
        val targetDeviceId = envelope.payload.target
        if (targetDeviceId == null) {
            // No target specified, try LAN first
            tryLanThenCloud(envelope, null)
            return
        }

        // Check if device is discovered on LAN
        val peers = transportManager.currentPeers()
        val peer = peers.find {
            val peerDeviceId = it.attributes["device_id"] ?: it.serviceName
            peerDeviceId == targetDeviceId || peerDeviceId.equals(targetDeviceId, ignoreCase = true)
        }

        if (peer != null && peer.host != "unknown" && peer.host != "127.0.0.1") {
            // Device is on LAN, try LAN first
            android.util.Log.d("FallbackSyncTransport", "📡 Device $targetDeviceId found on LAN, trying LAN first...")
            tryLanThenCloud(envelope, peer)
        } else {
            // Device not on LAN, try cloud directly
            android.util.Log.d("FallbackSyncTransport", "☁️ Device $targetDeviceId not on LAN, using cloud transport...")
            try {
                cloudTransport.send(envelope)
                android.util.Log.d("FallbackSyncTransport", "✅ Cloud transport succeeded")
                transportManager.markDeviceConnected(targetDeviceId, com.hypo.clipboard.transport.ActiveTransport.CLOUD)
            } catch (e: Exception) {
                android.util.Log.e("FallbackSyncTransport", "❌ Cloud transport failed: ${e.message}", e)
                throw e
            }
        }
    }

    private suspend fun tryLanThenCloud(envelope: SyncEnvelope, @Suppress("UNUSED_PARAMETER") peer: DiscoveredPeer?) {
        val targetDeviceId = envelope.payload.target
        
        // Try LAN with timeout (3 seconds)
        val lanSuccess = withTimeoutOrNull(Duration.ofSeconds(3).toMillis()) {
            try {
                lanTransport.send(envelope)
                android.util.Log.d("FallbackSyncTransport", "✅ LAN transport succeeded")
                if (targetDeviceId != null) {
                    transportManager.markDeviceConnected(targetDeviceId, com.hypo.clipboard.transport.ActiveTransport.LAN)
                }
                true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                android.util.Log.w("FallbackSyncTransport", "⚠️ LAN transport failed: ${e.message}")
                false
            }
        } ?: false

        if (lanSuccess) {
            return
        }

        // LAN failed or timed out, try cloud
        android.util.Log.d("FallbackSyncTransport", "🔄 LAN failed, falling back to cloud...")
        try {
            cloudTransport.send(envelope)
            android.util.Log.d("FallbackSyncTransport", "✅ Cloud fallback succeeded")
            if (targetDeviceId != null) {
                transportManager.markDeviceConnected(targetDeviceId, com.hypo.clipboard.transport.ActiveTransport.CLOUD)
            }
        } catch (e: Exception) {
            android.util.Log.e("FallbackSyncTransport", "❌ Cloud fallback also failed: ${e.message}", e)
            throw e
        }
    }
}

