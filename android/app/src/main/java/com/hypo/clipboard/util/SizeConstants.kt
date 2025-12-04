package com.hypo.clipboard.util

/**
 * Single source of truth for size limits across the Hypo app.
 * All size-related constants should be defined here to avoid duplication.
 */
object SizeConstants {
    /**
     * Maximum size for attachments (images/files) that can be synced between devices.
     * This is the raw content size before base64 encoding and JSON overhead.
     * 
     * After base64 encoding (×4/3) and JSON structure, a 10MB image becomes ~18MB in transport.
     */
    const val MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024 // 10MB
    
    /**
     * Maximum size for copying items to clipboard.
     * This is separate from the sync limit - items can be synced but not copied if too large.
     * Prevents excessive disk space usage from temporary files.
     */
    const val MAX_COPY_SIZE_BYTES = 50 * 1024 * 1024 // 50MB
    
    /**
     * Transport frame payload limit (JSON bytes, excluding 4-byte length prefix).
     * 
     * Calculation for 10MB image:
     *   1. Base64 encode data: 10MB × 4/3 = ~13.3MB
     *   2. JSON ClipboardPayload: ~13.3MB + metadata ≈ 13.3MB
     *   3. Encrypt (AES-GCM): ~13.3MB ciphertext
     *   4. Base64 encode ciphertext: 13.3MB × 4/3 = ~17.8MB
     *   5. JSON SyncEnvelope: ~17.8MB + envelope fields ≈ 18MB
     * 
     * Set to 25MB to provide safety margin for metadata and JSON structure overhead.
     * 
     * Note: Previously was 40MB to account for both `data` (array) and `data_base64`,
     * but macOS now only encodes `data_base64` for efficiency (~50-70% reduction).
     */
    const val MAX_TRANSPORT_PAYLOAD_BYTES = 25 * 1024 * 1024 // 25MB
    
    /**
     * Target raw size for image compression (75% of MAX_ATTACHMENT_BYTES).
     * Images larger than this will be compressed to stay under 10MB after base64 + JSON overhead.
     */
    const val MAX_RAW_SIZE_FOR_COMPRESSION = (MAX_ATTACHMENT_BYTES * 0.75).toInt() // ~7.5MB
    
    /**
     * Maximum dimension (width or height) for images before scaling down.
     * Images with longest side > 2560px will be scaled down.
     */
    const val MAX_IMAGE_DIMENSION_PX = 2560
}

