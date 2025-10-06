package com.hypo.clipboard.transport.ws

import com.hypo.clipboard.sync.SyncEnvelope
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.nio.ByteBuffer

class TransportFrameCodec(
    private val json: Json = Json { encodeDefaults = true; ignoreUnknownKeys = false },
    private val maxPayloadBytes: Int = 256 * 1024
) {
    fun encode(envelope: SyncEnvelope): ByteArray {
        val payload = json.encodeToString(envelope).encodeToByteArray()
        if (payload.size > maxPayloadBytes) {
            throw TransportFrameException("payload exceeds $maxPayloadBytes bytes")
        }
        val buffer = ByteBuffer.allocate(4 + payload.size)
        buffer.putInt(payload.size)
        buffer.put(payload)
        return buffer.array()
    }

    fun decode(frame: ByteArray): SyncEnvelope {
        require(frame.size >= 4) { "frame truncated" }
        val buffer = ByteBuffer.wrap(frame)
        val length = buffer.int
        if (length < 0 || length > frame.size - 4) {
            throw TransportFrameException("frame truncated")
        }
        val payload = ByteArray(length)
        buffer.get(payload)
        return json.decodeFromString(SyncEnvelope.serializer(), payload.decodeToString())
    }
}

class TransportFrameException(message: String) : Exception(message)
