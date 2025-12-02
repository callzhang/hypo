package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.sync.SyncEnvelope
import com.hypo.clipboard.sync.SyncTransport
import com.hypo.clipboard.transport.NoopTransportAnalytics
import com.hypo.clipboard.transport.NoopTransportMetricsRecorder
import com.hypo.clipboard.transport.TransportAnalytics
import com.hypo.clipboard.transport.TransportMetricsRecorder
import java.time.Clock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import javax.inject.Inject

class RelayWebSocketClient @Inject constructor(
    private val config: TlsWebSocketConfig,
    connector: WebSocketConnector,
    frameCodec: TransportFrameCodec = TransportFrameCodec(),
    metricsRecorder: TransportMetricsRecorder = NoopTransportMetricsRecorder,
    analytics: TransportAnalytics = NoopTransportAnalytics,
    transportManager: com.hypo.clipboard.transport.TransportManager,
    scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    clock: Clock = Clock.systemUTC()
) : SyncTransport {

    private val delegate = WebSocketTransportClient(
        config = config,
        connector = connector,
        frameCodec = frameCodec,
        scope = scope,
        clock = clock,
        metricsRecorder = metricsRecorder,
        analytics = analytics,
        transportManager = transportManager  // Pass TransportManager so cloud connection state can be updated
    )

    override suspend fun send(envelope: SyncEnvelope) {
        delegate.send(envelope)
    }

    suspend fun close() {
        delegate.close()
    }
    
    /**
     * Check if the WebSocket is currently connected.
     * This is used to determine connection status in the UI.
     */
    fun isConnected(): Boolean {
        return delegate.isConnected()
    }
    
    /**
     * Set handler for incoming clipboard messages from cloud relay.
     * Wraps the handler to mark messages as coming from cloud transport.
     */
    fun setIncomingClipboardHandler(handler: (com.hypo.clipboard.sync.SyncEnvelope, com.hypo.clipboard.domain.model.TransportOrigin) -> Unit) {
        delegate.setIncomingClipboardHandler { envelope ->
            handler(envelope, com.hypo.clipboard.domain.model.TransportOrigin.CLOUD)
        }
    }
    
    /**
     * Start maintaining a persistent connection to receive incoming messages from cloud relay.
     * This should be called when the app starts to ensure cloud messages can be received.
     */
    fun startReceiving() {
        android.util.Log.d(
            "RelayWebSocketClient",
            "👂 startReceiving() called @${System.currentTimeMillis()} – connecting to cloud relay"
        )
        android.util.Log.d("RelayWebSocketClient", "   Config URL: ${config.url}")
        android.util.Log.d("RelayWebSocketClient", "   Config environment: ${config.environment}")
        delegate.startReceiving()
    }
    
    /**
     * Force an immediate connection attempt (for debugging/testing).
     * Useful for verifying connectivity from ADB or UI.
     */
    fun probeNow() {
        android.util.Log.d("RelayWebSocketClient", "🔍 probeNow(): forcing ensureConnection at ${System.currentTimeMillis()}")
        delegate.forceConnectOnce()
    }
    
    /**
     * Force reconnection by closing existing connection and starting a new one.
     * Used when network changes to ensure connection uses new IP address.
     * Only reconnects if connection is already established (not in progress).
     */
    suspend fun reconnect() {
        android.util.Log.d("RelayWebSocketClient", "🔄 Reconnecting cloud WebSocket due to network change")
        
        // Check if connection is already established (not just in progress)
        val isConnected = delegate.isConnected()
        if (isConnected) {
            android.util.Log.d("RelayWebSocketClient", "   Connection is established, closing and reconnecting")
            // Close the connection - this will cancel the connection job and close the socket
            // close() now checks if handshake is in progress and handles it safely
            delegate.close()
            // Wait for connection job to fully complete cleanup (close() uses cancelAndJoin())
            // Additional delay to ensure socket is fully closed at OS level
            kotlinx.coroutines.delay(1500)
            // Start receiving will trigger ensureConnection which will start a new connection
            delegate.startReceiving()
        } else {
            android.util.Log.d("RelayWebSocketClient", "   Connection not yet established or in progress")
            // Connection is in progress or not started
            // Don't call close() here as it might interrupt an in-progress connection attempt
            // The close() method now checks for handshake in progress, but we still avoid calling it
            // during connection attempts to prevent "Socket closed" errors
            // Instead, cancel the connection job and let it clean up naturally, then reconnect
            android.util.Log.d("RelayWebSocketClient", "   Cancelling in-progress connection and will reconnect")
            delegate.cancelConnectionJob()
            kotlinx.coroutines.delay(500) // Brief delay to let cancellation complete
            // Start receiving will trigger ensureConnection which will start a new connection
            delegate.startReceiving()
        }
    }
}
