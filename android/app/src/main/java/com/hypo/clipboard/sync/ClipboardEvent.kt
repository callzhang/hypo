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
    val sourceDeviceId: String? = null,
    val sourceDeviceName: String? = null,
    val skipBroadcast: Boolean = false
)

internal fun ClipboardEvent.signature(): String {
    val metadataSignature = metadata.entries
        .sortedBy { it.key }
        .joinToString(separator = "|") { (key, value) -> "$key=$value" }
    return listOf(type.name, content, metadataSignature).joinToString(separator = "||")
}
