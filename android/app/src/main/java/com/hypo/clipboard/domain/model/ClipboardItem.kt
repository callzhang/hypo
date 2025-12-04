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
     * 
     * For IMAGE and FILE types, uses metadata hash if available (more reliable than base64 comparison
     * since images may be re-encoded with different compression when copied from history).
     * If hash comparison fails (e.g., due to re-encoding), falls back to comparing decoded bytes.
     */
    fun matchesContent(other: ClipboardItem): Boolean {
        // 1. Check content type
        if (type != other.type) {
            return false
        }
        
        // 2. For IMAGE and FILE types, try metadata hash first (most reliable)
        // This handles cases where images are re-encoded with different compression
        if (type == ClipboardType.IMAGE || type == ClipboardType.FILE) {
            val hash1 = metadata?.get("hash")
            val hash2 = other.metadata?.get("hash")
            if (hash1 != null && hash2 != null && hash1 == hash2) {
                return true
            }
            
            // If hash comparison failed (e.g., image was re-encoded), compare decoded bytes
            // This handles the case where an image is copied from history and re-encoded
            try {
                val bytes1 = java.util.Base64.getDecoder().decode(content)
                val bytes2 = java.util.Base64.getDecoder().decode(other.content)
                if (bytes1.contentEquals(bytes2)) {
                    return true
                }
            } catch (e: Exception) {
                // If decoding fails, fall through to base64 string comparison
            }
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
