package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.transport.TransportManager
import com.hypo.clipboard.transport.lan.DiscoveredPeer
import com.hypo.clipboard.transport.TransportAnalytics
import com.hypo.clipboard.transport.TransportMetricsRecorder
import com.hypo.clipboard.transport.NoopTransportAnalytics
import com.hypo.clipboard.transport.NoopTransportMetricsRecorder
import com.hypo.clipboard.transport.ws.TransportFrameCodec
import com.hypo.clipboard.transport.ws.OkHttpWebSocketConnector
import java.time.Clock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.ConcurrentHashMap

/**
 * Manages persistent WebSocket connections to all discovered LAN peers.
 * Maintains one connection per peer (deviceId), mirroring macOS architecture.
 * 
 * Connections are created when peers are discovered and removed when peers are no longer available.
 * Each connection is maintained independently with automatic reconnection.
 */
class LanPeerConnectionManager(
    private val transportManager: TransportManager,
    private val frameCodec: TransportFrameCodec,
    private val analytics: TransportAnalytics = NoopTransportAnalytics,
    private val metricsRecorder: TransportMetricsRecorder = NoopTransportMetricsRecorder,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val clock: Clock = java.time.Clock.systemUTC()
) {
    // Map of deviceId -> WebSocketTransportClient (one connection per peer)
    private val peerConnections = ConcurrentHashMap<String, WebSocketTransportClient>()
    // Map of deviceId -> connection maintenance job
    private val connectionJobs = ConcurrentHashMap<String, Job>()
    private val mutex = Mutex()
    // Handler for incoming clipboard messages from peer connections
    private var onIncomingClipboard: ((com.hypo.clipboard.sync.SyncEnvelope, com.hypo.clipboard.domain.model.TransportOrigin) -> Unit)? = null
    
    /**
     * Get set of device IDs that have active LAN WebSocket connections.
     */
    fun getActiveLanConnections(): Set<String> {
        return peerConnections.entries
            .filter { (_, client) -> client.isConnected() }
            .map { (deviceId, _) -> deviceId }
            .toSet()
    }
    
    /**
     * Sync peer connections: create connections for newly discovered peers,
     * remove connections for peers that are no longer discovered.
     * Called when peers are discovered/removed (event-driven).
     */
    suspend fun syncPeerConnections() {
        mutex.withLock {
            val discoveredPeers = transportManager.currentPeers()
            val discoveredDeviceIds = discoveredPeers.mapNotNull { peer ->
                peer.attributes["device_id"] ?: peer.serviceName
            }.toSet()
            
            // Remove connections for peers that are no longer discovered
            val currentDeviceIds = peerConnections.keys.toSet()
            val removedDeviceIds = currentDeviceIds - discoveredDeviceIds
            for (deviceId in removedDeviceIds) {
                val deviceDesc = transportManager.getDeviceName(deviceId) ?: "${deviceId.take(8)}..."
                android.util.Log.d("LanPeerConnectionManager", "🔌 Removing connection for peer $deviceDesc (no longer discovered)")
                
                // Explicitly disconnect the client to ensure socket is closed and listeners are notified
                peerConnections[deviceId]?.disconnect()
                
                connectionJobs[deviceId]?.cancel()
                connectionJobs.remove(deviceId)
                peerConnections.remove(deviceId)
            }
            
            // Create/maintain connections for discovered peers
            for (peer in discoveredPeers) {
                val deviceId = peer.attributes["device_id"] ?: peer.serviceName
                val peerUrl = when {
                    peer.host != "unknown" && peer.host != "127.0.0.1" -> {
                        "ws://${peer.host}:${peer.port}"
                    }
                    peer.host == "127.0.0.1" -> {
                        // Emulator case: replace localhost with host IP
                        val emulatorHost = "10.0.2.2"
                        "ws://$emulatorHost:${peer.port}"
                    }
                    else -> null
                }
                
                if (peerUrl == null) {
                    android.util.Log.w("LanPeerConnectionManager", "⚠️ Invalid URL for peer ${peer.serviceName}")
                    continue
                }
                
                // Create connection if it doesn't exist
                if (!peerConnections.containsKey(deviceId)) {
                    val deviceDesc = transportManager.getDeviceName(deviceId) ?: "${deviceId.take(8)}..."
                    android.util.Log.d("LanPeerConnectionManager", "🔌 Creating persistent connection for peer $deviceDesc (deviceId=$deviceId) at $peerUrl")
                    
                    val peerConfig = TlsWebSocketConfig(
                        url = peerUrl,
                        fingerprintSha256 = null, // No pinning for ws://
                        headers = mapOf(
                            "X-Device-Platform" to "android"
                        ),
                        environment = "lan",
                        idleTimeoutMillis = 3600_000L, // 1 hour
                        roundTripTimeoutMillis = 60_000L
                    )
                    
                    // Create connector for this peer
                    val peerConnector = OkHttpWebSocketConnector(peerConfig)
                    
                    val client = WebSocketTransportClient(
                        config = peerConfig,
                        connector = peerConnector,
                        frameCodec = frameCodec,
                        scope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
                        clock = clock,
                        metricsRecorder = metricsRecorder,
                        analytics = analytics,
                        transportManager = transportManager
                    )
                    
                    // Set incoming clipboard handler if available
                    onIncomingClipboard?.let { handler ->
                        client.setIncomingClipboardHandler(handler)
                        val deviceDesc = transportManager.getDeviceName(deviceId) ?: "${deviceId.take(8)}..."
                        android.util.Log.d("LanPeerConnectionManager", "✅ Set incoming clipboard handler for peer $deviceDesc")
                    }
                    
                    // CRITICAL: Set connection event listener BEFORE starting connection
                    // This ensures the listener is set before any connect/disconnect events fire
                    android.util.Log.d("LanPeerConnectionManager", "📝 Setting listener on client instance ${client.hashCode()} for device $deviceDesc (deviceId=$deviceId)")
                    client.setConnectionEventListener { isConnected ->
                        val deviceDesc = transportManager.getDeviceName(deviceId) ?: "${deviceId.take(8)}..."
                        android.util.Log.d("LanPeerConnectionManager", "🔌 Connection event: $deviceDesc -> $isConnected (instance=${client.hashCode()}, deviceId=$deviceId)")
                        transportManager.setLanConnection(deviceId, isConnected)
                    }
                    
                    peerConnections[deviceId] = client
                    android.util.Log.d("LanPeerConnectionManager", "✅ Added client instance ${client.hashCode()} to peerConnections for $deviceDesc (deviceId=$deviceId)")
                    
                    // Start connection maintenance task
                    connectionJobs[deviceId] = scope.launch {
                        maintainPeerConnection(deviceId, client, peer.serviceName, peerUrl)
                    }
                } else {
                    // Check if peer IP changed (reconnect if needed)
                    // Note: We can't easily check the URL from WebSocketTransportClient
                    // For now, we'll rely on the connection failing and reconnecting naturally
                    // TODO: Track peer URLs separately to detect IP changes
                }
            }
        }
    }
    
    /**
     * Maintain persistent connection to a peer with automatic reconnection.
     * Reuses unified event-driven reconnection logic from WebSocketTransportClient.
     * Simply calls startReceiving() once - all reconnection is handled by onClosed() callbacks
     * with the same exponential backoff as cloud connections.
     */
    private suspend fun maintainPeerConnection(
        deviceId: String,
        client: WebSocketTransportClient,
        peerName: String,
        peerUrl: String
    ) {
        val deviceDesc = transportManager.getDeviceName(deviceId) ?: "${deviceId.take(8)}..."
        android.util.Log.d("LanPeerConnectionManager", "🔌 Starting connection maintenance for peer $deviceDesc at $peerUrl")
        
        // Start receiving - this will establish connection and maintain it
        // WebSocketTransportClient handles all reconnection via onClosed() callbacks
        // with unified exponential backoff (same as cloud connections)
        // Connection event listener is already set during client creation
        client.startReceiving()
        
        // Keep this coroutine alive while peer is still in our map
        // The connection is maintained by WebSocketTransportClient's event-driven reconnection
        while (scope.isActive && peerConnections.containsKey(deviceId)) {
            delay(10_000) // Just keep alive - reconnection is handled by WebSocketTransportClient
        }
        
        android.util.Log.d("LanPeerConnectionManager", "🔌 Connection maintenance ended for peer $deviceDesc")
    }
    
    /**
     * Get connection for a specific peer (deviceId).
     * Returns null if peer is not connected.
     */
    fun getConnection(deviceId: String): WebSocketTransportClient? {
        return peerConnections[deviceId]
    }
    
    /**
     * Get all active peer connections.
     */
    fun getAllConnections(): Map<String, WebSocketTransportClient> {
        return peerConnections.toMap()
    }
    
    /**
     * Send message to a specific peer.
     * Returns true if sent successfully, false otherwise.
     */
    suspend fun sendToPeer(deviceId: String, envelope: com.hypo.clipboard.sync.SyncEnvelope): Boolean {
        val client = peerConnections[deviceId] ?: return false
        return try {
            client.send(envelope)
            true
        } catch (e: Exception) {
            val deviceDesc = transportManager.getDeviceName(deviceId) ?: "${deviceId.take(8)}..."
            android.util.Log.w("LanPeerConnectionManager", "⚠️ Failed to send to peer $deviceDesc: ${e.message}")
            false
        }
    }
    
    /**
     * Send message to all connected peers.
     * Returns number of successful sends.
     */
    suspend fun sendToAllPeers(envelope: com.hypo.clipboard.sync.SyncEnvelope): Int {
        var successCount = 0
        for ((deviceId, client) in peerConnections) {
            try {
                if (client.isConnected()) {
                    client.send(envelope)
                    successCount++
                }
            } catch (e: Exception) {
                val deviceDesc = transportManager.getDeviceName(deviceId) ?: "${deviceId.take(8)}..."
                android.util.Log.d("LanPeerConnectionManager", "⚠️ Failed to send to peer $deviceDesc: ${e.message}")
            }
        }
        return successCount
    }
    
    /**
     * Close all LAN connections (for screen-off optimization).
     * Connections will be re-established when reconnectAll() is called.
     */
    suspend fun closeAllConnections() {
        mutex.withLock {
            android.util.Log.d("LanPeerConnectionManager", "🔌 Closing all LAN connections (screen-off optimization)")
            for ((deviceId, client) in peerConnections) {
                try {
                    // Use disconnect() instead of close() - closes socket but keeps client ready for reconnection
                    client.disconnect()
                    val deviceDesc = transportManager.getDeviceName(deviceId) ?: "${deviceId.take(8)}..."
                    android.util.Log.d("LanPeerConnectionManager", "   Disconnected peer $deviceDesc")
                } catch (e: Exception) {
                    val deviceDesc = transportManager.getDeviceName(deviceId) ?: "${deviceId.take(8)}..."
                    android.util.Log.w("LanPeerConnectionManager", "⚠️ Error disconnecting peer $deviceDesc: ${e.message}")
                }
            }
            // Cancel connection maintenance jobs
            for ((_, job) in connectionJobs) {
                job.cancel()
            }
            connectionJobs.clear()
            // Keep peerConnections map intact - we'll reconnect to the same peers
        }
    }
    
    /**
     * Reconnect all LAN connections (for screen-on optimization).
     * Re-establishes connections to all discovered peers.
     */
    suspend fun reconnectAllConnections() {
        mutex.withLock {
            android.util.Log.d("LanPeerConnectionManager", "🔄 Reconnecting all LAN connections (screen-on optimization)")
            // Re-sync peer connections to re-establish connections
            syncPeerConnections()
        }
    }
    
    /**
     * Set handler for incoming clipboard messages from peer connections.
     * This handler will be set on all existing and future peer connections.
     */
    fun setIncomingClipboardHandler(handler: (com.hypo.clipboard.sync.SyncEnvelope, com.hypo.clipboard.domain.model.TransportOrigin) -> Unit) {
        onIncomingClipboard = handler
        // Set handler on all existing connections
        for ((deviceId, client) in peerConnections) {
            client.setIncomingClipboardHandler(handler)
            val deviceDesc = transportManager.getDeviceName(deviceId) ?: "${deviceId.take(8)}..."
            android.util.Log.d("LanPeerConnectionManager", "✅ Set incoming clipboard handler for existing peer $deviceDesc")
        }
    }
    
    /**
     * Shutdown all peer connections.
     */
    fun shutdown() {
        android.util.Log.d("LanPeerConnectionManager", "🛑 Shutting down all peer connections")
        for ((_, job) in connectionJobs) {
            job.cancel()
        }
        connectionJobs.clear()
        peerConnections.clear()
    }
}

