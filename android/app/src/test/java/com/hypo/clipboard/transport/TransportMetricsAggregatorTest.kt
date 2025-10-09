package com.hypo.clipboard.transport

import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneOffset
import kotlin.math.roundToLong
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class TransportMetricsAggregatorTest {
    private val clock: Clock = Clock.fixed(Instant.parse("2025-10-07T00:00:00Z"), ZoneOffset.UTC)

    @Test
    fun `flush publishes metrics snapshot`() {
        val analytics = RecordingAnalytics()
        val aggregator = TransportMetricsAggregator(environment = "loopback", clock = clock)

        recordHandshakeSamples(aggregator)
        recordRoundTripSamples(aggregator)

        val snapshot = aggregator.flush(ActiveTransport.LAN, analytics)
        assertNotNull(snapshot)
        assertEquals("loopback", snapshot.environment)
        assertEquals(5, snapshot.handshake?.samples?.size)
        assertEquals(44.2, snapshot.handshake?.p95 ?: error("missing p95"), 0.05)
        assertEquals(16.2, snapshot.roundTrip?.p95 ?: error("missing p95"), 0.05)

        val event = analytics.recorded.single() as TransportAnalyticsEvent.Metrics
        assertEquals(ActiveTransport.LAN, event.transport)
        assertEquals(snapshot, event.snapshot)

        val cleared = aggregator.snapshot()
        assertNull(cleared)
    }

    @Test
    fun `snapshot returns null when no samples`() {
        val analytics = RecordingAnalytics()
        val aggregator = TransportMetricsAggregator(environment = "loopback", clock = clock)
        assertNull(aggregator.snapshot())
        assertNull(aggregator.flush(ActiveTransport.CLOUD, analytics))
        assertTrue(analytics.recorded.isEmpty())
    }

    private fun recordHandshakeSamples(aggregator: TransportMetricsAggregator) {
        listOf(42.0, 41.5, 44.2, 39.8, 42.7).forEach {
            aggregator.recordHandshake(ms(it), clock.instant())
        }
    }

    private fun recordRoundTripSamples(aggregator: TransportMetricsAggregator) {
        listOf(15.0, 14.5, 16.2, 13.8, 15.3).forEachIndexed { index, value ->
            aggregator.recordRoundTrip("envelope-$index", ms(value))
        }
    }

    private fun ms(value: Double): Duration {
        val nanos = (value * 1_000_000.0).roundToLong()
        return Duration.ofNanos(nanos)
    }

    private class RecordingAnalytics : TransportAnalytics {
        private val _recorded = mutableListOf<TransportAnalyticsEvent>()
        val recorded: List<TransportAnalyticsEvent>
            get() = _recorded

        override val events = kotlinx.coroutines.flow.MutableSharedFlow<TransportAnalyticsEvent>()

        override fun record(event: TransportAnalyticsEvent) {
            _recorded += event
        }
    }
}
