package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.sync.SyncEnvelope
import com.hypo.clipboard.util.SizeConstants
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import java.nio.ByteBuffer

@OptIn(ExperimentalSerializationApi::class)
class TransportFrameCodec(
    private val json: Json = Json {
        encodeDefaults = true
        ignoreUnknownKeys = false
        namingStrategy = JsonNamingStrategy.SnakeCase
    },
    private val maxPayloadBytes: Int = SizeConstants.MAX_TRANSPORT_PAYLOAD_BYTES
) {
    fun encode(envelope: SyncEnvelope): ByteArray {
        val payload = json.encodeToString(envelope).encodeToByteArray()
        if (payload.size > maxPayloadBytes) {
            throw TransportFrameException("payload exceeds $maxPayloadBytes bytes")
        }
        // Explicitly use BIG_ENDIAN byte order to match backend and macOS expectations
        val buffer = ByteBuffer.allocate(4 + payload.size).order(java.nio.ByteOrder.BIG_ENDIAN)
        buffer.putInt(payload.size)
        buffer.put(payload)
        return buffer.array()
    }

    fun decode(frame: ByteArray): SyncEnvelope {
        require(frame.size >= 4) { "frame truncated" }
        // Explicitly use BIG_ENDIAN byte order to match backend and macOS expectations
        val buffer = ByteBuffer.wrap(frame).order(java.nio.ByteOrder.BIG_ENDIAN)
        val length = buffer.int
        if (length < 0 || length > frame.size - 4) {
            throw TransportFrameException("frame truncated")
        }
        if (length > maxPayloadBytes) {
            throw TransportFrameException("payload exceeds $maxPayloadBytes bytes")
        }
        val payload = ByteArray(length)
        buffer.get(payload)
        return json.decodeFromString(SyncEnvelope.serializer(), payload.decodeToString())
    }
}

class TransportFrameException(message: String) : Exception(message)
