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
    config: TlsWebSocketConfig,
    connector: WebSocketConnector,
    frameCodec: TransportFrameCodec = TransportFrameCodec(),
    metricsRecorder: TransportMetricsRecorder = NoopTransportMetricsRecorder,
    analytics: TransportAnalytics = NoopTransportAnalytics,
    scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    clock: Clock = Clock.systemUTC()
) : SyncTransport {

    private val delegate = LanWebSocketClient(
        config = config,
        connector = connector,
        frameCodec = frameCodec,
        scope = scope,
        clock = clock,
        metricsRecorder = metricsRecorder,
        analytics = analytics
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
}
