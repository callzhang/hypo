package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.sync.MessageType
import com.hypo.clipboard.sync.Payload
import com.hypo.clipboard.sync.SyncEnvelope
import java.nio.file.Files
import java.nio.file.Paths
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.text.Charsets
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

class TransportFrameCodecTest {
    private val codec = TransportFrameCodec()

    @Test
    fun `round trip matches envelope`() {
        val envelope = SyncEnvelope(
            type = MessageType.CLIPBOARD,
            payload = Payload(
                contentType = com.hypo.clipboard.domain.model.ClipboardType.TEXT,
                ciphertext = "3q2+7w==",
                deviceId = "mac-device",
                target = "android-device",
                encryption = com.hypo.clipboard.sync.EncryptionMetadata(
                    nonce = "qrvM",
                    tag = "EBES"
                )
            )
        )
        val encoded = codec.encode(envelope)
        val decoded = codec.decode(encoded)
        assertEquals(envelope.payload.deviceId, decoded.payload.deviceId)
        assertEquals(envelope.payload.encryption.nonce, decoded.payload.encryption.nonce)
    }

    @Test
    fun `decode known vector`() {
        val vectorsPath = Paths.get("..", "..", "tests", "transport", "frame_vectors.json").normalize()
        val content = String(Files.readAllBytes(vectorsPath), Charsets.UTF_8)
        val vectors = Json.decodeFromString(
            ListSerializer(FrameVector.serializer()),
            content
        )
        val vector = vectors.first()
        val frame = java.util.Base64.getDecoder().decode(vector.base64)
        val decoded = codec.decode(frame)
        assertEquals(vector.envelope.payload.device_id, decoded.payload.deviceId)
        val reEncoded = codec.encode(decoded)
        val originalPayload = frame.copyOfRange(4, frame.size)
        val reEncodedPayload = reEncoded.copyOfRange(4, reEncoded.size)
        val originalJson = Json.parseToJsonElement(String(originalPayload, Charsets.UTF_8))
        val reEncodedJson = Json.parseToJsonElement(String(reEncodedPayload, Charsets.UTF_8))
        assertEquals(originalJson, reEncodedJson)
    }

    @Test
    fun `encode fails on oversize`() {
        val largePayload = "a".repeat(300_000)
        val envelope = SyncEnvelope(
            type = MessageType.CLIPBOARD,
            payload = Payload(
                contentType = com.hypo.clipboard.domain.model.ClipboardType.TEXT,
                ciphertext = largePayload,
                deviceId = "device",
                target = null,
                encryption = com.hypo.clipboard.sync.EncryptionMetadata(
                    nonce = "", tag = ""
                )
            )
        )
        assertFailsWith<TransportFrameException> { codec.encode(envelope) }
    }

    @kotlinx.serialization.Serializable
    private data class FrameVector(
        val description: String,
        val base64: String,
        val envelope: EnvelopePayload
    ) {
        @kotlinx.serialization.Serializable
        data class EnvelopePayload(
            val id: String,
            val timestamp: String,
            val version: String,
            val type: String,
            val payload: PayloadFields
        )

        @kotlinx.serialization.Serializable
        data class PayloadFields(
            val content_type: String,
            val ciphertext: String,
            val device_id: String,
            val target: String,
            val encryption: EncryptionFields
        )

        @kotlinx.serialization.Serializable
        data class EncryptionFields(
            val algorithm: String,
            val nonce: String,
            val tag: String
        )
    }
}
