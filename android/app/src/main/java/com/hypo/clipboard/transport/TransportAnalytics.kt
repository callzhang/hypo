package com.hypo.clipboard.transport

import java.time.Clock
import java.time.Instant
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow

sealed class TransportAnalyticsEvent {
    data class Fallback(
        val reason: FallbackReason,
        val metadata: Map<String, String> = emptyMap(),
        val occurredAt: Instant
    ) : TransportAnalyticsEvent()

    data class PinningFailure(
        val environment: String,
        val host: String,
        val message: String?,
        val occurredAt: Instant
    ) : TransportAnalyticsEvent()

    data class Metrics(
        val transport: ActiveTransport,
        val snapshot: TransportMetricsSnapshot
    ) : TransportAnalyticsEvent()
}

enum class FallbackReason(val code: String) {
    LanTimeout("lan_timeout"),
    LanRejected("lan_rejected"),
    LanNotSupported("lan_not_supported"),
    Unknown("unknown")
}

interface TransportAnalytics {
    val events: SharedFlow<TransportAnalyticsEvent>
    fun record(event: TransportAnalyticsEvent)
}

class InMemoryTransportAnalytics(
    private val clock: Clock = Clock.systemUTC()
) : TransportAnalytics {
    private val _events = MutableSharedFlow<TransportAnalyticsEvent>(extraBufferCapacity = 16)
    override val events: SharedFlow<TransportAnalyticsEvent> = _events

    override fun record(event: TransportAnalyticsEvent) {
        _events.tryEmit(event)
    }

    fun recordFallback(reason: FallbackReason, metadata: Map<String, String> = emptyMap()) {
        record(TransportAnalyticsEvent.Fallback(reason, metadata, clock.instant()))
    }

    fun recordPinningFailure(environment: String, host: String, message: String?) {
        record(TransportAnalyticsEvent.PinningFailure(environment, host, message, clock.instant()))
    }
}

object NoopTransportAnalytics : TransportAnalytics {
    override val events: SharedFlow<TransportAnalyticsEvent> = MutableSharedFlow()
    override fun record(event: TransportAnalyticsEvent) = Unit
}
