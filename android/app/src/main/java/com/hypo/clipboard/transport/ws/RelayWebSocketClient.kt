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
}
