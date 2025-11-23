package com.hypo.clipboard.domain.model

import java.security.MessageDigest
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
) {
    /**
     * Unified content matching: content length, then first 1KB hash
     * Returns true if entries match based on the unified matching criteria
     * Note: Metadata (device UUID, timestamp) is not used for matching - we match by content only
     */
    fun matchesContent(other: ClipboardItem): Boolean {
        // 1. Check content type
        if (type != other.type) {
            return false
        }
        
        // 3. Check content length first
        if (content.length != other.content.length) {
            return false
        }
        
        // 4. Hash first 1KB for comparison
        val hash1 = hashFirst1KB(content.toByteArray(Charsets.UTF_8))
        val hash2 = hashFirst1KB(other.content.toByteArray(Charsets.UTF_8))
        
        return hash1 == hash2
    }
    
    /**
     * Hash first 1KB of data for content matching
     */
    private fun hashFirst1KB(data: ByteArray): Int {
        val sampleSize = minOf(1024, data.size)
        var hash = 0
        for (i in 0 until sampleSize) {
            hash = hash * 31 + (data[i].toInt() and 0xFF)
        }
        return hash
    }
}
