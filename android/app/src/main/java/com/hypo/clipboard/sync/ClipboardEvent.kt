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

    val transportOrigin: com.hypo.clipboard.domain.model.TransportOrigin? = null,
    val localPath: String? = null
)

fun ClipboardEvent.signature(): String {
    // For IMAGE/FILE types, prioritize hash from metadata for stable signatures
    // This ensures duplicate detection works even when content is stored on disk
    // and prevents issues with thumbnail_base64 or other variable metadata fields
    val contentForSignature = when {
        type == ClipboardType.IMAGE || type == ClipboardType.FILE -> {
            // Use hash from metadata as primary identifier (most stable)
            // Fall back to content if hash not available, then localPath
            metadata["hash"] ?: if (content.isNotEmpty()) content else (localPath ?: "")
        }
        else -> content
    }
    
    // For IMAGE/FILE, exclude variable fields like thumbnail_base64 from signature
    // to ensure stable signatures for the same image
    val metadataForSignature = if (type == ClipboardType.IMAGE || type == ClipboardType.FILE) {
        metadata.filterKeys { it != "thumbnail_base64" }
    } else {
        metadata
    }
    
    val metadataSignature = metadataForSignature.entries
        .sortedBy { it.key }
        .joinToString(separator = "|") { (key, value) -> "$key=$value" }
    return listOf(type.name, contentForSignature, metadataSignature).joinToString(separator = "||")
}
