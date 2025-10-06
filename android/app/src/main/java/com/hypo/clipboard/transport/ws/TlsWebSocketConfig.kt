package com.hypo.clipboard.transport.ws

data class TlsWebSocketConfig(
    val url: String,
    val fingerprintSha256: String?,
    val headers: Map<String, String> = emptyMap(),
    val idleTimeoutMillis: Long = 30_000L
)
