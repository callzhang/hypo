package com.hypo.clipboard.transport.lan

import java.time.Instant

internal const val SERVICE_TYPE = "_hypo._tcp."

data class DiscoveredPeer(
    val serviceName: String,
    val host: String,
    val port: Int,
    val fingerprint: String?,
    val attributes: Map<String, String>,
    val lastSeen: Instant
)

sealed interface LanDiscoveryEvent {
    data class Added(val peer: DiscoveredPeer) : LanDiscoveryEvent
    data class Removed(val serviceName: String) : LanDiscoveryEvent
}
