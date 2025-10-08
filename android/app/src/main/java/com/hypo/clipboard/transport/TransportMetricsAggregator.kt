package com.hypo.clipboard.transport

import java.time.Clock
import java.time.Duration
import java.time.Instant
import kotlin.math.ceil

/** Collects transport handshake and round-trip timings so they can be published to dashboards. */
class TransportMetricsAggregator(
    private val environment: String,
    private val clock: Clock = Clock.systemUTC()
) : TransportMetricsRecorder {
    private val lock = Any()
    private val handshakeDurationsMs = mutableListOf<Double>()
    private val roundTripDurationsMs = mutableListOf<Double>()

    override fun recordHandshake(duration: Duration, timestamp: Instant) {
        val millis = duration.toNanos().toDouble() / 1_000_000.0
        synchronized(lock) {
            handshakeDurationsMs += millis
        }
    }

    override fun recordRoundTrip(envelopeId: String, duration: Duration) {
        val millis = duration.toNanos().toDouble() / 1_000_000.0
        synchronized(lock) {
            roundTripDurationsMs += millis
        }
    }

    fun snapshot(clear: Boolean = false): TransportMetricsSnapshot? {
        val handshakes: List<Double>
        val roundTrips: List<Double>
        synchronized(lock) {
            if (handshakeDurationsMs.isEmpty() && roundTripDurationsMs.isEmpty()) {
                if (clear) {
                    handshakeDurationsMs.clear()
                    roundTripDurationsMs.clear()
                }
                return null
            }
            handshakes = handshakeDurationsMs.toList()
            roundTrips = roundTripDurationsMs.toList()
            if (clear) {
                handshakeDurationsMs.clear()
                roundTripDurationsMs.clear()
            }
        }
        return TransportMetricsSnapshot(
            generatedAt = clock.instant(),
            environment = environment,
            handshake = distribution(handshakes),
            roundTrip = distribution(roundTrips)
        )
    }

    fun flush(transport: ActiveTransport, analytics: TransportAnalytics): TransportMetricsSnapshot? {
        val snapshot = snapshot(clear = true) ?: return null
        analytics.record(
            TransportAnalyticsEvent.Metrics(
                transport = transport,
                snapshot = snapshot
            )
        )
        return snapshot
    }

    private fun distribution(samples: List<Double>): TransportMetricDistribution? {
        if (samples.isEmpty()) return null
        val sorted = samples.sorted()
        return TransportMetricDistribution(
            samples = sorted,
            p50 = percentile(sorted, 0.50),
            p90 = percentile(sorted, 0.90),
            p95 = percentile(sorted, 0.95)
        )
    }

    private fun percentile(sorted: List<Double>, percentile: Double): Double {
        if (sorted.isEmpty()) return Double.NaN
        if (sorted.size == 1) return sorted.first()
        val rank = ceil(percentile * sorted.size).toInt().coerceAtLeast(1)
        val index = (rank - 1).coerceIn(0, sorted.size - 1)
        return sorted[index]
    }
}

data class TransportMetricsSnapshot(
    val generatedAt: Instant,
    val environment: String,
    val handshake: TransportMetricDistribution?,
    val roundTrip: TransportMetricDistribution?
)

data class TransportMetricDistribution(
    val samples: List<Double>,
    val p50: Double,
    val p90: Double,
    val p95: Double
)
