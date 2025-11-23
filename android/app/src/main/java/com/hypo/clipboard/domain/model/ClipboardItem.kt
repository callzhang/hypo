package com.hypo.clipboard.domain.model

import java.time.Instant

enum class TransportOrigin {
    LAN,
    CLOUD
}

data class ClipboardItem(
    val id: String,
    val type: ClipboardType,
    val content: String,
    val preview: String,
    val metadata: Map<String, String>?,
    val deviceId: String,
    val deviceName: String? = null,
    val createdAt: Instant,
    val isPinned: Boolean,
    val isEncrypted: Boolean = false,
    val transportOrigin: TransportOrigin? = null
)
