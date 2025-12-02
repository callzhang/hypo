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
    CONTROL
}

@Serializable
data class Payload(
    @SerialName("content_type") val contentType: ClipboardType,
    val ciphertext: String,
    @SerialName("device_id") val deviceId: String,  // UUID string (pure UUID, no prefix)
    @SerialName("device_platform") val devicePlatform: String? = null,  // Platform: "macos", "android", etc.
    @SerialName("device_name") val deviceName: String? = null,
    val target: String? = null,
    val encryption: EncryptionMetadata
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
    val metadata: Map<String, String> = emptyMap()
)
