package com.hypo.clipboard.sync

import com.hypo.clipboard.crypto.CryptoService
import com.hypo.clipboard.domain.model.ClipboardItem
import com.hypo.clipboard.domain.model.ClipboardType
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import java.time.Instant
import java.util.Base64
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SyncEngineTest {
    private val deviceKeyStore = mockk<DeviceKeyStore>()
    private val transport = mockk<SyncTransport>(relaxed = true)
    private val identity = mockk<DeviceIdentity> {
        every { deviceId } returns "android-device-123"
    }

    @Test
    fun encryptsClipboardPayloadsBeforeSending() = runTest {
        val nonce = ByteArray(12) { 0xAA.toByte() }
        val cryptoService = CryptoService { nonce }
        val key = ByteArray(32) { index -> index.toByte() }

        coEvery { deviceKeyStore.loadKey("mac-device") } returns key
        coEvery { transport.send(any()) } returns Unit

        val engine = SyncEngine(cryptoService, deviceKeyStore, transport, identity)
        val item = ClipboardItem(
            id = "clip-1",
            type = ClipboardType.TEXT,
            content = "Hello, Hypo!",
            preview = "Hello, Hypo!",
            metadata = mapOf("length" to "12"),
            deviceId = identity.deviceId,
            createdAt = Instant.parse("2024-03-21T12:30:45Z"),
            isPinned = false
        )

        val envelope = engine.sendClipboard(item, "mac-device")

        coVerify(exactly = 1) { transport.send(envelope) }
        assertEquals(MessageType.CLIPBOARD, envelope.type)
        assertEquals("mac-device", envelope.payload.target)
        assertEquals(identity.deviceId, envelope.payload.deviceId)

        val ciphertext = Base64.getDecoder().decode(envelope.payload.ciphertext)
        val nonceValue = Base64.getDecoder().decode(envelope.payload.encryption.nonce)
        assertContentEquals(nonce, nonceValue)
        // Ciphertext should not equal plaintext bytes
        val plaintext = "Hello, Hypo!".encodeToByteArray()
        assertNotEquals(plaintext.toList(), ciphertext.toList())
    }

    @Test
    fun decodeRestoresOriginalPayload() = runTest {
        val cryptoService = mockk<CryptoService>()
        val ciphertext = Base64.getEncoder().encodeToString("cipher".encodeToByteArray())
        val nonce = Base64.getEncoder().encodeToString(ByteArray(12) { 1 })
        val tag = Base64.getEncoder().encodeToString(ByteArray(16) { 2 })
        val payloadJson = "{\"content_type\":\"text\",\"data_base64\":\"${Base64.getEncoder().encodeToString("Hello".encodeToByteArray())}\",\"metadata\":{}}"
        val key = ByteArray(32) { 9 }

        coEvery { deviceKeyStore.loadKey("mac-device") } returns key
        coEvery {
            cryptoService.decrypt(
                encrypted = any(),
                key = key,
                aad = "mac-device".encodeToByteArray()
            )
        } returns payloadJson.encodeToByteArray()

        val envelope = SyncEnvelope(
            type = MessageType.CLIPBOARD,
            payload = Payload(
                contentType = ClipboardType.TEXT,
                ciphertext = ciphertext,
                deviceId = "mac-device",
                target = identity.deviceId,
                encryption = EncryptionMetadata(
                    nonce = nonce,
                    tag = tag
                )
            )
        )

        val engine = SyncEngine(cryptoService, deviceKeyStore, transport, identity)
        val payload = engine.decode(envelope)

        assertEquals(ClipboardType.TEXT, payload.contentType)
        val decodedData = Base64.getDecoder().decode(payload.dataBase64)
        assertContentEquals("Hello".encodeToByteArray(), decodedData)
    }

    @Test
    fun throwsWhenKeyMissing() = runTest {
        val cryptoService = mockk<CryptoService>(relaxed = true)
        coEvery { deviceKeyStore.loadKey(any()) } returns null
        val engine = SyncEngine(cryptoService, deviceKeyStore, transport, identity)

        val item = ClipboardItem(
            id = "clip",
            type = ClipboardType.TEXT,
            content = "Hello",
            preview = "Hello",
            metadata = null,
            deviceId = identity.deviceId,
            createdAt = Instant.now(),
            isPinned = false
        )

        assertFailsWith<SyncEngineException.MissingKey> {
            engine.sendClipboard(item, "mac-device")
        }

        val envelope = SyncEnvelope(
            type = MessageType.CLIPBOARD,
            payload = Payload(
                contentType = ClipboardType.TEXT,
                ciphertext = Base64.getEncoder().encodeToString("cipher".encodeToByteArray()),
                deviceId = "mac-device",
                encryption = EncryptionMetadata(
                    nonce = Base64.getEncoder().encodeToString(ByteArray(12)),
                    tag = Base64.getEncoder().encodeToString(ByteArray(16))
                )
            )
        )

        assertFailsWith<SyncEngineException.MissingKey> {
            engine.decode(envelope)
        }
    }
}
