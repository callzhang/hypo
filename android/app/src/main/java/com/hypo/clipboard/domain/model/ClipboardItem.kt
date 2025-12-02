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
     * Unified content matching: content length, then SHA-256 hash of full content
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
        
        // 4. Hash full content (SHA-256) for comparison to minimize collisions
        val hash1 = sha256(content.toByteArray(Charsets.UTF_8))
        val hash2 = sha256(other.content.toByteArray(Charsets.UTF_8))
        
        return hash1.contentEquals(hash2)
    }
    
    /**
     * Cryptographic hash (SHA-256) of the full content for content matching
     */
    private fun sha256(data: ByteArray): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        return digest.digest(data)
    }
}
