package com.hypo.clipboard.transport

import java.time.Duration
import java.time.Instant

interface TransportMetricsRecorder {
    fun recordHandshake(duration: Duration, timestamp: Instant)
    fun recordRoundTrip(envelopeId: String, duration: Duration)
}

object NoopTransportMetricsRecorder : TransportMetricsRecorder {
    override fun recordHandshake(duration: Duration, timestamp: Instant) {}

    override fun recordRoundTrip(envelopeId: String, duration: Duration) {}
}
