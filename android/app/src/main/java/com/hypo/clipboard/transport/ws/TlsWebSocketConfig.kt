package com.hypo.clipboard.transport.ws

data class TlsWebSocketConfig(
    val url: String?, // Nullable for LAN connections (URL comes from peer discovery)
    val fingerprintSha256: String?,
    val headers: Map<String, String> = emptyMap(),
    val idleTimeoutMillis: Long = 30_000L,
    val environment: String = "lan",
    val roundTripTimeoutMillis: Long = 60_000L
)
