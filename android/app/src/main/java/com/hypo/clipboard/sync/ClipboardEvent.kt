package com.hypo.clipboard.sync

import com.hypo.clipboard.domain.model.ClipboardType
import java.time.Instant

data class ClipboardEvent(
    val id: String,
    val type: ClipboardType,
    val content: String,
    val preview: String,
    val metadata: Map<String, String>,
    val createdAt: Instant,
    val deviceId: String? = null,  // Normalized to lowercase for consistent matching
    val deviceName: String? = null,
    val skipBroadcast: Boolean = false,
    val isEncrypted: Boolean = false,
    val transportOrigin: com.hypo.clipboard.domain.model.TransportOrigin? = null
)

fun ClipboardEvent.signature(): String {
    val metadataSignature = metadata.entries
        .sortedBy { it.key }
        .joinToString(separator = "|") { (key, value) -> "$key=$value" }
    return listOf(type.name, content, metadataSignature).joinToString(separator = "||")
}
