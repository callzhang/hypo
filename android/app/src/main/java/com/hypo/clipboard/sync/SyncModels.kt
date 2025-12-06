package com.hypo.clipboard.sync

import com.hypo.clipboard.domain.model.ClipboardType
import java.time.Instant
import java.util.UUID
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class SyncEnvelope(
    val id: String = UUID.randomUUID().toString(),
    val timestamp: String = Instant.now().toString(),
    val version: String = "1.0",
    @SerialName("type") val type: MessageType,
    val payload: Payload
)

@Serializable
enum class MessageType {
    @SerialName("clipboard")
    CLIPBOARD,

    @SerialName("control")
    CONTROL,

    @SerialName("error")
    ERROR
}

@Serializable
data class Payload(
    @SerialName("content_type") val contentType: ClipboardType? = null,
    val ciphertext: String? = null,
    @SerialName("device_id") val deviceId: String? = null,  // UUID string (pure UUID, no prefix)
    @SerialName("device_platform") val devicePlatform: String? = null,  // Platform: "macos", "android", etc.
    @SerialName("device_name") val deviceName: String? = null,
    val target: String? = null,
    val encryption: EncryptionMetadata? = null,
    // Error payload fields (when type is ERROR) - these are only present for error messages
    val code: String? = null,
    val message: String? = null,
    @SerialName("original_message_id") val originalMessageId: String? = null,
    @SerialName("target_device_id") val targetDeviceId: String? = null,
    // Control message fields (when type is CONTROL)
    val action: String? = null  // Control action (e.g., "query_connected_peers")
)

@Serializable
data class EncryptionMetadata(
    val algorithm: String = "AES-256-GCM",
    val nonce: String,
    val tag: String
)

@Serializable
data class ClipboardPayload(
    @SerialName("content_type") val contentType: ClipboardType,
    @SerialName("data_base64") val dataBase64: String,
    val metadata: Map<String, String> = emptyMap(),
    val compressed: Boolean = false  // Indicates if the JSON payload was compressed
)
